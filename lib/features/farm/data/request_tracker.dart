/// JSON-RPC 请求追踪器 (T5.2)
///
/// 负责:
/// - 生成唯一 JSON-RPC 请求 ID
/// - 管理等待中的请求 (Map<id, Completer>)
/// - 超时处理 (默认 30s)
///
/// 配合 FarmMqttRouter 使用:
///   发送命令 → tracker.track(sn, requestId) → 发布到 {sn}/request
///   收到响应 → tracker.complete(sn, requestId, response) → 完成对应的 Future

import 'dart:async';
import 'dart:math';

/// 请求追踪条目
class _TrackedRequest {
  final String sn;
  final int requestId;
  final String method;
  final Completer<Map<String, dynamic>?> completer;
  final Timer timer;

  _TrackedRequest({
    required this.sn,
    required this.requestId,
    required this.method,
    required this.completer,
    required this.timer,
  });
}

/// JSON-RPC 请求追踪器
class RequestTracker {
  /// 等待中的请求: Map<requestId, TrackedRequest>
  final Map<int, _TrackedRequest> _pending = {};

  /// 按 SN 索引: Map<sn, List<requestId>>
  final Map<String, List<int>> _bySn = {};

  final Random _random = Random();

  static const Duration defaultTimeout = Duration(seconds: 30);

  /// 待处理的请求数
  int get pendingCount => _pending.length;

  /// 生成新的请求 ID (int)
  int generateRequestId() {
    // JSON-RPC 2.0 通常使用递增整数，但为了去重使用随机数
    int id;
    do {
      id = _random.nextInt(0x7FFFFFFF);
    } while (_pending.containsKey(id));
    return id;
  }

  /// 追踪一个新请求
  ///
  /// [sn] 目标打印机 SN
  /// [requestId] JSON-RPC 请求 ID
  /// [method] RPC 方法名（用于日志）
  /// [timeout] 超时时间
  ///
  /// 返回一个 Future，当收到响应或超时时完成。
  Future<Map<String, dynamic>?> track(
    String sn,
    int requestId,
    String method, {
    Duration timeout = defaultTimeout,
  }) {
    final completer = Completer<Map<String, dynamic>?>();

    final timer = Timer(timeout, () {
      _cleanup(requestId, sn);
      if (!completer.isCompleted) {
        completer.complete(null); // 超时返回 null
      }
    });

    final tracked = _TrackedRequest(
      sn: sn,
      requestId: requestId,
      method: method,
      completer: completer,
      timer: timer,
    );

    _pending[requestId] = tracked;
    _bySn.putIfAbsent(sn, () => []).add(requestId);

    return completer.future;
  }

  /// 完成一个请求（收到响应时调用）
  ///
  /// [sn] 打印机 SN
  /// [requestId] 匹配的请求 ID
  /// [response] JSON-RPC 响应体
  void complete(String sn, int requestId, Map<String, dynamic>? response) {
    final tracked = _pending[requestId];
    if (tracked == null || tracked.sn != sn) return;

    _cleanup(requestId, sn);
    if (!tracked.completer.isCompleted) {
      tracked.completer.complete(response);
    }
  }

  /// 取消指定打印机的所有待处理请求
  void cancelAllForPrinter(String sn) {
    final ids = _bySn[sn];
    if (ids == null) return;

    for (final id in List.from(ids)) {
      final tracked = _pending[id];
      if (tracked != null) {
        tracked.timer.cancel();
        if (!tracked.completer.isCompleted) {
          tracked.completer.completeError(
            TimeoutException('打印机 $sn 已离线，请求被取消'),
          );
        }
      }
      _pending.remove(id);
    }
    _bySn.remove(sn);
  }

  /// 取消所有待处理请求
  void cancelAll() {
    for (final tracked in _pending.values) {
      tracked.timer.cancel();
      if (!tracked.completer.isCompleted) {
        tracked.completer.completeError(
          Exception('所有请求已取消'),
        );
      }
    }
    _pending.clear();
    _bySn.clear();
  }

  /// 获取指定打印机的待处理请求数
  int pendingCountForPrinter(String sn) => _bySn[sn]?.length ?? 0;

  void _cleanup(int requestId, String sn) {
    final tracked = _pending.remove(requestId);
    tracked?.timer.cancel();

    final ids = _bySn[sn];
    if (ids != null) {
      ids.remove(requestId);
      if (ids.isEmpty) _bySn.remove(sn);
    }
  }

  void dispose() {
    cancelAll();
  }
}
