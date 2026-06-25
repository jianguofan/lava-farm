/// MqttMessageProcessor — 持久 Isolate 后台处理 MQTT 消息
///
/// 将 CPU 密集型工作（UTF-8 解码、JSON 解析、嵌套 Map 展平）
/// 从主 isolate 卸载到后台 isolate。
///
/// ⚠️ 跨 isolate 通信必须使用纯 Map/List/SendPort
/// ⚠️ List<int> 跨 isolate 后会变成 List<dynamic>，需 cast

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

/// 经过 isolate 处理完毕的消息
class ProcessedMessage {
  final String sn;
  final String topic;
  final Map<String, dynamic> rawJson;
  final Map<String, dynamic>? expandedStatus;
  final DateTime? eventTime;

  const ProcessedMessage({
    required this.sn,
    required this.topic,
    required this.rawJson,
    this.expandedStatus,
    this.eventTime,
  });
}

class MqttMessageProcessor {
  static const int _batchWindowMs = 50;

  final void Function(List<ProcessedMessage> batch) _onBatchProcessed;

  Isolate? _isolate;
  SendPort? _isolateSendPort;
  ReceivePort? _responsePort;
  bool _isolateReady = false;

  final List<Map<String, dynamic>> _accumulator = [];
  Timer? _batchTimer;
  int _batchId = 0;
  bool _isDisposed = false;

  MqttMessageProcessor({
    required void Function(List<ProcessedMessage> batch) onBatchProcessed,
  }) : _onBatchProcessed = onBatchProcessed {
    _spawn();
  }

  void enqueue(String topic, List<int> payload) {
    if (_isDisposed) return;
    _accumulator.add({'t': topic, 'p': payload});
    if (_accumulator.length >= 100) {
      _doSend();
    } else {
      _batchTimer ??= Timer(Duration(milliseconds: _batchWindowMs), _doSend);
    }
  }

  void flush() {
    if (_accumulator.isEmpty) return;
    _batchTimer?.cancel();
    _batchTimer = null;
    _doSend();
  }

  void dispose() {
    _isDisposed = true;
    _batchTimer?.cancel();
    _accumulator.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _responsePort?.close();
  }

  // ═══════════════════════════════════════════════════════════

  void _spawn() {
    _responsePort = ReceivePort();
    final initPort = ReceivePort();

    Isolate.spawn(_isolateEntry, initPort.sendPort).then((isolate) {
      if (_isDisposed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    });

    initPort.first.then((dynamic port) {
      if (_isDisposed) return;
      _isolateSendPort = port as SendPort;
      _isolateReady = true;
      initPort.close(); // 收到 isolate SendPort 后关闭

      _responsePort!.listen((dynamic data) {
        if (_isDisposed) return;
        if (data is! Map) return;
        final msgs = data['msgs'] as List?;
        if (msgs == null || msgs.isEmpty) return;
        final results = <ProcessedMessage>[];
        for (final m in msgs) {
          if (m is! Map) continue;
          try {
            DateTime? eventTime;
            final ms = m['eventMs'];
            if (ms is int) {
              eventTime = DateTime.fromMillisecondsSinceEpoch(ms);
            }
            results.add(ProcessedMessage(
              sn: m['sn'] as String,
              topic: m['topic'] as String,
              rawJson: Map<String, dynamic>.from(m['json'] as Map),
              expandedStatus: m['expanded'] == null
                  ? null
                  : Map<String, dynamic>.from(m['expanded'] as Map),
              eventTime: eventTime,
            ));
          } catch (e) {
            print('[Processor] 主端解析结果失败: $e');
          }
        }
        if (results.isNotEmpty) {
          _onBatchProcessed(results);
        }
      });

      // 发积压消息
      _doSend();
    }).catchError((e) {
      print('[Processor] ❌ Isolate 启动失败: $e');
    });
    // ⚠️ 不在这里 close initPort — isolate 还没回传 SendPort
  }

  void _doSend() {
    _batchTimer?.cancel();
    _batchTimer = null;

    if (_accumulator.isEmpty) return;
    if (!_isolateReady) {
      _batchTimer = Timer(Duration(milliseconds: _batchWindowMs), _doSend);
      return;
    }

    final batch = List<Map<String, dynamic>>.from(_accumulator);
    _accumulator.clear();

    try {
      _isolateSendPort!.send({
        'batchId': ++_batchId,
        'msgs': batch,
        'replyPort': _responsePort!.sendPort,
      });
    } catch (e) {
      print('[Processor] ❌ 发送到 isolate 失败: $e');
      // 消息丢失，但避免崩溃
    }
  }
}

// ═══════════════════════════════════════════════════════════
// Isolate 入口（顶层函数）
// ═══════════════════════════════════════════════════════════

void _isolateEntry(SendPort initPort) {
  final receivePort = ReceivePort();
  initPort.send(receivePort.sendPort);

  receivePort.listen((dynamic request) {
    try {
      if (request is! Map) return;
      final msgs = request['msgs'] as List?;
      final replyPort = request['replyPort'] as SendPort?;
      if (msgs == null || replyPort == null) return;

      final results = <Map<String, dynamic>>[];

      for (final raw in msgs) {
        if (raw is! Map) continue;
        try {
          final topic = raw['t'] as String;
          // ⚠️ List<int> 跨 isolate 变成 List<dynamic> → 需要 List<int>.from
          final payload = List<int>.from(raw['p'] as List);
          final sn = topic.split('/').first;
          final decoded = utf8.decode(payload);
          final json = jsonDecode(decoded) as Map<String, dynamic>;

          Map<String, dynamic>? expandedStatus;
          DateTime? eventTime;

          if (topic.endsWith('/status')) {
            Map<String, dynamic>? status;
            final params = json['params'];
            if (params is List && params.isNotEmpty) {
              status = params[0] as Map<String, dynamic>?;
            }
            if (params is List && params.length >= 2) {
              final rawTime = params[1];
              if (rawTime is num) {
                eventTime = DateTime.fromMillisecondsSinceEpoch(
                  (rawTime * 1000).toInt(),
                );
              }
            }
            if (status != null) {
              expandedStatus = <String, dynamic>{};
              _flatten(status, '', expandedStatus);
            }
          }

          results.add({
            'sn': sn,
            'topic': topic,
            'json': json,
            if (expandedStatus != null) 'expanded': expandedStatus,
            if (eventTime != null) 'eventMs': eventTime!.millisecondsSinceEpoch,
          });
        } catch (e) {
          print('[Iso] 消息处理异常: $e');
        }
      }

      replyPort.send({'batchId': request['batchId'], 'msgs': results});
    } catch (e) {
      print('[Iso] ❌ 致命异常: $e');
    }
  });
}

/// 展开嵌套 Map（isolate 内静态版本）
void _flatten(
    Map<String, dynamic> source, String prefix, Map<String, dynamic> target) {
  for (final entry in source.entries) {
    final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final val = entry.value;
    if (val is Map<String, dynamic>) {
      _flatten(val, key, target);
    } else {
      target[key] = val;
    }
  }
}
