/// FarmMqttRouter — MQTT 消息路由器
///
/// 职责:
/// - 连接到 Broker 后订阅通配符 topic (+/status, +/notification)
/// - 解析收到的消息并路由到 FarmStore
/// - 管理单设备 {SN}/response 的动态订阅（用于 JSON-RPC 请求-响应匹配）
///
/// 数据流:
///   MQTT +/status        → _handleStatus(sn, payload)    → FarmStore.onMqttStatus
///   MQTT +/notification  → _handleNotification(sn, data) → FarmStore.onMqttNotification
///   MQTT {SN}/response   → RequestTracker.complete(...)

import 'dart:async';
import 'dart:convert';

import 'broker_connection_manager.dart';
import 'farm_printer_state.dart';
import 'farm_store.dart';
import 'printer_info.dart';

/// MQTT 消息路由器
class FarmMqttRouter {
  final FarmStore _store;
  final MqttTransportAdapter _transport;
  final RequestTracker _tracker = RequestTracker();

  /// 已订阅的设备响应 topic: Map<SN, Subscription>
  final Set<String> _responseSubscribed = {};

  FarmMqttRouter({
    required FarmStore store,
    required MqttTransportAdapter transport,
  })  : _store = store,
        _transport = transport;

  // ═══════════════════════════════════════════════════════════
  // 启动 / 停止
  // ═══════════════════════════════════════════════════════════

  /// 订阅通配符 topic，开始接收所有设备消息
  Future<void> start() async {
    // 监听所有消息
    _transport.messageStream.listen(_onMessage);

    // 通配符订阅 — 一条订阅覆盖全部设备
    await _transport.subscribe('+/status', qos: 1);
    await _transport.subscribe('+/notification', qos: 1);
  }

  /// 停止路由
  Future<void> stop() async {
    _tracker.clear();
    _responseSubscribed.clear();
  }

  // ═══════════════════════════════════════════════════════════
  // 发送命令
  // ═══════════════════════════════════════════════════════════

  /// 向指定打印机发送 JSON-RPC 命令（MQTT 通道）
  ///
  /// 返回命令执行结果，超时返回 null。
  Future<Map<String, dynamic>?> sendCommand(
    String sn,
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final requestId = DateTime.now().microsecondsSinceEpoch;
    final request = {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
      'id': requestId,
    };

    final future = _tracker.track(sn, requestId);

    // 动态订阅 {sn}/response（如果尚未订阅）
    if (!_responseSubscribed.contains(sn)) {
      await _transport.subscribe('$sn/response', qos: 1);
      _responseSubscribed.add(sn);
      // 短暂延迟确保订阅在 Broker 端生效
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final payload = utf8.encode(jsonEncode(request));
    await _transport.publish('$sn/request', payload, qos: 1);

    return future;
  }

  // ═══════════════════════════════════════════════════════════
  // 消息处理
  // ═══════════════════════════════════════════════════════════

  void _onMessage(MqttMessage msg) {
    final topic = msg.topic;
    final sn = _extractSn(topic);

    try {
      final json = jsonDecode(utf8.decode(msg.payload)) as Map<String, dynamic>;

      if (topic.endsWith('/status')) {
        _handleStatus(sn, json);
      } else if (topic.endsWith('/notification')) {
        _handleNotification(sn, json);
      } else if (topic.endsWith('/response')) {
        _tracker.complete(sn, json);
      }
    } catch (e) {
      // 解析失败，跳过该消息
    }
  }

  /// 处理状态推送
  ///
  /// Moonraker notify_status_update 格式:
  ///   {"jsonrpc":"2.0", "method":"notify_status_update",
  ///    "params":[{"extruder":{"temperature":210.5},...}, 1718700000.0]}
  void _handleStatus(String sn, Map<String, dynamic> json) {
    // 提取状态数据
    Map<String, dynamic>? status;
    DateTime? eventTime;

    if (json['params'] is List && (json['params'] as List).isNotEmpty) {
      status = (json['params'] as List)[0] as Map<String, dynamic>?;
    }

    // 提取 eventtime（UNIX 时间戳，秒）
    if (json['params'] is List && (json['params'] as List).length >= 2) {
      final rawTime = (json['params'] as List)[1];
      if (rawTime is num) {
        eventTime = DateTime.fromMillisecondsSinceEpoch(
          (rawTime * 1000).toInt(),
        );
      }
    }

    if (status == null) return;

    // 展开嵌套字段: {"extruder": {"temperature": 210.5}}
    // 变为: {"extruder.temperature": 210.5}
    final expanded = <String, dynamic>{};
    _expandMap(status, '', expanded);

    _store.onMqttStatus(sn, expanded, eventTime: eventTime);
  }

  /// 处理通知（Last Will 遗嘱消息）
  ///
  /// 格式: {"server":"online"} 或 {"server":"offline"}
  void _handleNotification(String sn, Map<String, dynamic> json) {
    _store.onMqttNotification(sn, json);
  }

  // ═══════════════════════════════════════════════════════════
  // 工具方法
  // ═══════════════════════════════════════════════════════════

  /// 从 topic 提取 SN（topic 格式: "SN/type" 或 "+/type"）
  String _extractSn(String topic) {
    final parts = topic.split('/');
    return parts.first == '+' ? parts.first : parts.first;
  }

  /// 展开嵌套 Map: {"a":{"b":1}} → {"a.b":1}
  void _expandMap(Map<String, dynamic> source, String prefix,
      Map<String, dynamic> target) {
    for (final entry in source.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        _expandMap(entry.value as Map<String, dynamic>, key, target);
      } else {
        target[key] = entry.value;
      }
    }
  }
}

/// JSON-RPC 请求-响应追踪器
class RequestTracker {
  final Map<String, Map<int, Completer<Map<String, dynamic>?>>> _pending = {};
  final Map<int, String> _idToSn = {};
  Timer? _cleanupTimer;

  RequestTracker() {
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _cleanExpired(),
    );
  }

  /// 注册一个待完成的请求，返回 Future
  Future<Map<String, dynamic>?> track(String sn, int requestId,
      {Duration timeout = const Duration(seconds: 30)}) {
    final completer = Completer<Map<String, dynamic>?>();

    _pending.putIfAbsent(sn, () => {});
    _pending[sn]![requestId] = completer;
    _idToSn[requestId] = sn;

    // 超时处理
    Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null); // 超时返回 null
        _removeTracking(sn, requestId);
      }
    });

    return completer.future;
  }

  /// 完成一个请求
  void complete(String sn, Map<String, dynamic> response) {
    final id = response['id'] as int?;
    if (id == null) return;

    final completer = _pending[sn]?[id];
    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
      _removeTracking(sn, id);
    }
  }

  void _removeTracking(String sn, int requestId) {
    _pending[sn]?.remove(requestId);
    if (_pending[sn]?.isEmpty ?? false) {
      _pending.remove(sn);
    }
    _idToSn.remove(requestId);
  }

  /// 清理过期超时的 Completer
  void _cleanExpired() {
    // Completer 的超时已经在 track() 中用 Timer 处理
    // 这里只清理已被移除的引用
  }

  void clear() {
    for (final completers in _pending.values) {
      for (final completer in completers.values) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }
    }
    _pending.clear();
    _idToSn.clear();
  }
}
