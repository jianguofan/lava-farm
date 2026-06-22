/// HTTP 轮询降级通道 (T7.1, T7.2, T7.3, T7.4)
///
/// 用于无法推送 MQTT 配置的打印机，降级为 HTTP 轮询。
///
/// 关键特性:
/// - 请求队列 (20 并发)
/// - 自适应轮询间隔（基于 HTTP 打印机状态而非全局）
/// - probeSingle 即时确认（命令发送后立即触发一次轮询）
/// - 后台升级重试（每 5 分钟尝试推送 MQTT 配置）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'farm_store.dart';

/// HTTP 轮询目标（打印机）
class _HttpTarget {
  final String sn;
  final String ip;
  final int port;
  final String? apiKey;

  /// 连续失败计数
  int consecutiveFailures = 0;

  /// 是否成功推送过 MQTT 配置（用于判定是否需要升级重试）
  bool mqttConfigPushed = false;

  _HttpTarget({
    required this.sn,
    required this.ip,
    this.port = 7125,
    this.apiKey,
  });
}

/// HTTP 轮询器
class HttpPoller {
  final FarmStore _store;
  final List<_HttpTarget> _targets = [];
  Timer? _pollTimer;
  Timer? _upgradeTimer;

  static const int maxConcurrency = 20;
  static const Duration requestTimeout = Duration(seconds: 10);

  /// 外部注入的后台升级回调（重新推送 MQTT 配置）
  final Future<bool> Function(String sn)? onUpgradeRetry;

  HttpPoller({
    required FarmStore store,
    this.onUpgradeRetry,
  }) : _store = store;

  /// 添加打印机到轮询列表
  void addPrinter(String sn, String ip, {int port = 7125, String? apiKey}) {
    // 去重
    if (_targets.any((t) => t.sn == sn)) return;

    _targets.add(_HttpTarget(
      sn: sn,
      ip: ip,
      port: port,
      apiKey: apiKey,
    ));

    // 如果是第一台，启动轮询
    if (_targets.length == 1) {
      _scheduleNext(adaptiveInterval);
    }
  }

  /// 移除打印机
  void removePrinter(String sn) {
    _targets.removeWhere((t) => t.sn == sn);
    if (_targets.isEmpty) {
      _pollTimer?.cancel();
    }
  }

  /// 启动轮询
  void start() {
    if (_targets.isNotEmpty) {
      _scheduleNext(adaptiveInterval);
    }
    _startUpgradeRetries();
  }

  /// 停止轮询
  void stop() {
    _pollTimer?.cancel();
    _upgradeTimer?.cancel();
  }

  // ═══════════════════════════════════════════════════════════
  // 即时确认 (T7.2)
  // ═══════════════════════════════════════════════════════════

  /// 即时探测单台打印机状态
  ///
  /// HTTP 降级模式下，命令发送后调用此方法立即确认。
  /// 将命令确认延迟从 3s（等下一轮轮询）降到 ~200ms。
  Future<void> probeSingle(String sn) async {
    final target = _targets.firstWhere(
      (t) => t.sn == sn,
      orElse: () => _HttpTarget(sn: sn, ip: '', port: 7125),
    );
    if (target.ip.isEmpty) return;

    final result = await _pollOne(target, DateTime.now());
    if (result.isSuccess) {
      _store.onHttpPollResult(sn, result.data, pollTime: result.pollTime);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 自适应间隔
  // ═══════════════════════════════════════════════════════════

  /// 自适应轮询间隔（仅看 HTTP 打印机的状态）
  Duration get adaptiveInterval {
    // 只看 HTTP 降级打印机的状态，不与 MQTT 打印机混合计算
    final httpPrinters = _store.httpFallbackPrinters;
    final httpPrintingCount = httpPrinters.where((p) => p.isPrinting).length;
    final httpOnlineCount = httpPrinters.where((p) => p.isOnline).length;

    if (httpPrintingCount > 0) return const Duration(seconds: 3);
    if (httpOnlineCount > 0) return const Duration(seconds: 15);
    return const Duration(seconds: 30);
  }

  // ═══════════════════════════════════════════════════════════
  // 轮询调度
  // ═══════════════════════════════════════════════════════════

  void _scheduleNext(Duration delay) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, () async {
      await _pollAll();
      _scheduleNext(adaptiveInterval);
    });
  }

  /// 并发轮询所有目标
  Future<void> _pollAll() async {
    final now = DateTime.now();
    final semaphore = _Semaphore(maxConcurrency);

    final futures = _targets.map((target) async {
      await semaphore.acquire();
      try {
        final result = await _pollOne(target, now);
        if (result.isSuccess) {
          target.consecutiveFailures = 0;
          _store.onHttpPollResult(target.sn, result.data, pollTime: now);
        } else {
          target.consecutiveFailures++;
          _store.onHttpPollFailed(target.sn);
        }
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
  }

  /// 单次轮询
  Future<_PollResult> _pollOne(_HttpTarget target, DateTime pollTime) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = requestTimeout;
      final request = await client.getUrl(
        Uri.parse('http://${target.ip}:${target.port}/printer/objects/query'),
      );
      if (target.apiKey != null) {
        request.headers.set('X-Api-Key', target.apiKey!);
      }
      final response = await request.close().timeout(requestTimeout);

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final status = json['result']?['status'] as Map<String, dynamic>?;
        if (status != null) {
          return _PollResult(
            sn: target.sn,
            isSuccess: true,
            data: status,
            pollTime: pollTime,
          );
        }
      }
      client.close();
      return _PollResult(sn: target.sn, isSuccess: false, pollTime: pollTime);
    } catch (_) {
      return _PollResult(sn: target.sn, isSuccess: false, pollTime: pollTime);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 后台升级重试 (T7.3)
  // ═══════════════════════════════════════════════════════════

  /// 启动后台升级重试（每 5 分钟）
  void _startUpgradeRetries() {
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      if (onUpgradeRetry == null) return;

      final toRemove = <String>[];
      for (final target in List.from(_targets)) {
        try {
          final success = await onUpgradeRetry!(target.sn);
          if (success) {
            // 升级成功 → 从 HTTP 轮询移除
            toRemove.add(target.sn);
          }
        } catch (_) {
          // 单台失败继续
        }
      }

      for (final sn in toRemove) {
        removePrinter(sn);
      }
    });
  }

  void dispose() {
    stop();
  }
}

/// 轮询结果
class _PollResult {
  final String sn;
  final bool isSuccess;
  final Map<String, dynamic> data;
  final DateTime pollTime;

  _PollResult({
    required this.sn,
    required this.isSuccess,
    this.data = const {},
    required this.pollTime,
  });
}

/// 内部信号量
class _Semaphore {
  int _permits;
  final List<Completer<void>> _waiters = [];

  _Semaphore(int maxPermits) : _permits = maxPermits;

  Future<void> acquire() async {
    if (_permits > 0) {
      _permits--;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
    _permits--;
  }

  void release() {
    _permits++;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}
