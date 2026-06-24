/// UnifiedRequestTracker — 统一 JSON-RPC 请求-响应追踪器
///
/// 合并 FarmMqttRouter 内联版与 request_tracker.dart 独立版，
/// 新增 batchId 批次索引，同时支撑单控与群控场景。
///
/// 三层索引:
///   requestId   → _TrackedRequest      (主索引 — O(1) 响应匹配)
///   SN          → Set<requestId>       (SN 反向索引 — 离线时批量取消)
///   batchId     → _BatchContext         (批次索引 — 群控进度追踪)
///
/// 使用模式:
///   // 单控
///   final id = tracker.generateRequestId();
///   final future = tracker.track(sn, id, method);
///   mqtt.publish('$sn/request', request);
///   final response = await future;
///
///   // 群控
///   final batchId = 'batch_${DateTime.now().millisecondsSinceEpoch}';
///   for (final sn in printerSns) {
///     final id = tracker.generateRequestId();
///     tracker.track(sn, id, method, batchId: batchId);
///     mqtt.publish('$sn/request', request);
///   }
///   // 监听进度
///   StreamSubscription<BatchProgress> sub;
///   sub = tracker.batchProgressStream(batchId).listen((p) {
///     print('${p.completed}/${p.total}');
///     if (p.isDone) sub.cancel();
///   });

import 'dart:async';
import 'dart:math';

/// 默认超时时间
const defaultRequestTimeout = Duration(seconds: 30);

/// 急停超时
const emergencyStopTimeout = Duration(seconds: 5);

// ═══════════════════════════════════════════════════════════════
// 内部数据结构
// ═══════════════════════════════════════════════════════════════

/// 单条请求追踪条目
class _TrackedRequest {
  final String sn;
  final int requestId;
  final String method;
  final String? batchId;
  final Completer<Map<String, dynamic>?> completer;
  final Timer timer;

  _TrackedRequest({
    required this.sn,
    required this.requestId,
    required this.method,
    this.batchId,
    required this.completer,
    required this.timer,
  });
}

/// 批次上下文
class _BatchContext {
  final String batchId;
  final String method;
  final int total;
  final Set<int> requestIds;

  int completed = 0;
  int failed = 0;

  /// 进度流控制器
  final StreamController<BatchProgress> _progressController =
      StreamController<BatchProgress>.broadcast();

  _BatchContext({
    required this.batchId,
    required this.method,
    required this.total,
    required this.requestIds,
  });

  Stream<BatchProgress> get progressStream => _progressController.stream;

  void notifyProgress() {
    if (_progressController.hasListener) {
      _progressController.add(BatchProgress(
        batchId: batchId,
        completed: completed,
        failed: failed,
        total: total,
        inFlight: total - completed - failed,
      ));
    }
  }

  void dispose() {
    _progressController.close();
  }
}

// ═══════════════════════════════════════════════════════════════
// 公开类型
// ═══════════════════════════════════════════════════════════════

/// 批次进度快照
class BatchProgress {
  final String batchId;
  final int completed;
  final int failed;
  final int total;
  final int inFlight;

  const BatchProgress({
    required this.batchId,
    required this.completed,
    required this.failed,
    required this.total,
    required this.inFlight,
  });

  bool get isDone => completed + failed >= total;
  double get ratio => total > 0 ? (completed + failed) / total : 1.0;
  bool get allSuccess => completed == total && failed == 0;

  @override
  String toString() =>
      'BatchProgress($batchId: $completed/$total done, $failed failed, $inFlight in-flight)';
}

// ═══════════════════════════════════════════════════════════════
// UnifiedRequestTracker
// ═══════════════════════════════════════════════════════════════

class UnifiedRequestTracker {
  /// 主索引: requestId → TrackedRequest
  final Map<int, _TrackedRequest> _byId = {};

  /// SN 反向索引: SN → 该打印机的所有待处理 requestId
  final Map<String, Set<int>> _bySn = {};

  /// 批次索引: batchId → BatchContext
  final Map<String, _BatchContext> _byBatch = {};

  final Random _random = Random();

  // ── 查询 ──

  /// 当前所有待处理请求数
  int get totalPending => _byId.length;

  /// 指定打印机的待处理请求数
  int pendingForPrinter(String sn) => _bySn[sn]?.length ?? 0;

  /// 是否有待处理请求（全局或按 SN）
  bool hasPending({String? sn}) {
    if (sn != null) return pendingForPrinter(sn) > 0;
    return _byId.isNotEmpty;
  }

  // ── ID 生成 ──

  /// 生成全局唯一的请求 ID
  ///
  /// 使用随机数 + 碰撞检测，保证在 pending 集合中唯一。
  int generateRequestId() {
    int id;
    do {
      id = _random.nextInt(0x7FFFFFFF);
    } while (_byId.containsKey(id));
    return id;
  }

  /// 生成批次 ID
  String generateBatchId() =>
      'batch_${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(9999)}';

  // ── 请求追踪 ──

  /// 追踪一个新请求
  ///
  /// [sn]         目标打印机 SN
  /// [requestId]  请求 ID（由 [generateRequestId] 生成）
  /// [method]     JSON-RPC 方法名
  /// [batchId]    可选批次 ID — 单控不传，群控传入以关联批次进度
  /// [timeout]    超时时间，默认 30s
  ///
  /// 返回 Future<Map<String, dynamic>?>:
  ///   - 收到响应 → 完整的 JSON-RPC response body
  ///   - 超时     → null
  ///   - 被取消   → 抛出 TimeoutException（如果离线取消）或返回 null
  Future<Map<String, dynamic>?> track(
    String sn,
    int requestId,
    String method, {
    String? batchId,
    Duration timeout = defaultRequestTimeout,
  }) {
    final completer = Completer<Map<String, dynamic>?>();

    final timer = Timer(timeout, () {
      _onTimeout(requestId);
    });

    final tracked = _TrackedRequest(
      sn: sn,
      requestId: requestId,
      method: method,
      batchId: batchId,
      completer: completer,
      timer: timer,
    );

    // 主索引
    _byId[requestId] = tracked;

    // SN 反向索引
    _bySn.putIfAbsent(sn, () => {});
    _bySn[sn]!.add(requestId);

    // 批次索引（仅群控）
    if (batchId != null) {
      final ctx = _byBatch[batchId];
      if (ctx != null) {
        ctx.requestIds.add(requestId);
      }
      // 如果 ctx 不存在，说明调用方忘记先 registerBatch — 不报错，仅不追踪进度
    }

    return completer.future;
  }

  /// 完成一个请求（收到 MQTT response 时调用）
  ///
  /// [sn]       打印机 SN（来自 MQTT topic）
  /// [response] JSON-RPC 响应体，必须包含 "id" 字段
  void complete(String sn, Map<String, dynamic> response) {
    final id = response['id'] as int?;
    if (id == null) return;

    final tracked = _byId[id];
    if (tracked == null) return;

    // 安全校验：SN 必须匹配（防止 topic 错乱）
    if (tracked.sn != sn) return;

    _resolve(id, success: true, response: response);
  }

  /// 请求失败（网络错误、打印机返回 error 等）
  ///
  /// 与超时不同 — 超时由内部 Timer 处理，此方法用于主动标记失败。
  void fail(int requestId, {String? error}) {
    final tracked = _byId[requestId];
    if (tracked == null) return;

    _resolve(requestId, success: false, error: error);
  }

  // ── 批次管理 ──

  /// 注册一个批次（在群控发送前调用）
  ///
  /// 返回 batchId，后续 track() 需传入相同的 batchId。
  String registerBatch({
    required String method,
    required int totalCount,
  }) {
    final batchId = generateBatchId();
    _byBatch[batchId] = _BatchContext(
      batchId: batchId,
      method: method,
      total: totalCount,
      requestIds: {},
    );
    return batchId;
  }

  /// 获取批次进度流
  ///
  /// 先发射当前快照，再转发后续进度更新。
  /// 调用方可实时监听群控完成进度。
  Stream<BatchProgress> batchProgressStream(String batchId) {
    final ctx = _byBatch[batchId];
    if (ctx == null) {
      return Stream.error('Batch not found: $batchId');
    }

    final controller = StreamController<BatchProgress>();

    // 先发射当前快照
    controller.add(BatchProgress(
      batchId: batchId,
      completed: ctx.completed,
      failed: ctx.failed,
      total: ctx.total,
      inFlight: ctx.total - ctx.completed - ctx.failed,
    ));

    // 转发后续进度更新
    final subscription = ctx.progressStream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = () => subscription.cancel();

    return controller.stream;
  }

  /// 获取批次当前进度快照（无流，一次查询）
  BatchProgress? batchProgress(String batchId) {
    final ctx = _byBatch[batchId];
    if (ctx == null) return null;
    return BatchProgress(
      batchId: batchId,
      completed: ctx.completed,
      failed: ctx.failed,
      total: ctx.total,
      inFlight: ctx.total - ctx.completed - ctx.failed,
    );
  }

  // ── 取消操作 ──

  /// 取消单个请求
  void cancelRequest(int requestId) {
    final tracked = _byId[requestId];
    if (tracked == null) return;

    tracked.timer.cancel();
    if (!tracked.completer.isCompleted) {
      tracked.completer.complete(null);
    }
    _cleanup(requestId);
  }

  /// 按 SN 取消该打印机的所有待处理请求（打印机离线时调用）
  void cancelAllForPrinter(String sn) {
    final ids = _bySn[sn];
    if (ids == null) return;

    // 复制一份避免迭代时修改
    for (final id in Set<int>.from(ids)) {
      final tracked = _byId[id];
      if (tracked != null) {
        tracked.timer.cancel();
        if (!tracked.completer.isCompleted) {
          tracked.completer.complete(null);
        }
      }
      _cleanup(id);
    }
    _bySn.remove(sn);
  }

  /// 按批次取消所有待处理请求
  void cancelBatch(String batchId) {
    final ctx = _byBatch[batchId];
    if (ctx == null) return;

    for (final id in Set<int>.from(ctx.requestIds)) {
      cancelRequest(id);
    }

    ctx.notifyProgress(); // 最终进度更新
    ctx.dispose();
    _byBatch.remove(batchId);
  }

  /// 取消所有待处理请求
  void cancelAll() {
    for (final id in Set<int>.from(_byId.keys)) {
      cancelRequest(id);
    }
    for (final ctx in _byBatch.values) {
      ctx.dispose();
    }
    _byBatch.clear();
  }

  // ── 内部方法 ──

  /// 超时处理
  void _onTimeout(int requestId) {
    final tracked = _byId[requestId];
    if (tracked == null) return;

    if (!tracked.completer.isCompleted) {
      tracked.completer.complete(null); // 超时返回 null
    }
    _cleanup(requestId, isFailed: true);
  }

  /// 完成或失败请求
  void _resolve(int requestId, {required bool success, Map<String, dynamic>? response, String? error}) {
    final tracked = _byId[requestId];
    if (tracked == null) return;

    tracked.timer.cancel();
    if (!tracked.completer.isCompleted) {
      tracked.completer.complete(response);
    }

    _cleanup(requestId, isFailed: !success);
  }

  /// 清理请求：从所有索引中移除，更新批次进度
  void _cleanup(int requestId, {bool isFailed = false}) {
    final tracked = _byId.remove(requestId);
    if (tracked == null) return;

    // 清理 SN 反向索引
    final snSet = _bySn[tracked.sn];
    snSet?.remove(requestId);
    if (snSet?.isEmpty ?? false) {
      _bySn.remove(tracked.sn);
    }

    // 更新批次进度
    if (tracked.batchId != null) {
      final ctx = _byBatch[tracked.batchId];
      if (ctx != null) {
        if (isFailed) {
          ctx.failed++;
        } else {
          ctx.completed++;
        }
        ctx.notifyProgress();

        // 批次全部完成 → 清理上下文
        if (ctx.completed + ctx.failed >= ctx.total) {
          // 延迟清理，给 listener 时间处理最终事件
          Future.microtask(() {
            final current = _byBatch[tracked.batchId!];
            if (current != null && current.completed + current.failed >= current.total) {
              current.dispose();
              _byBatch.remove(tracked.batchId);
            }
          });
        }
      }
    }
  }

  /// 释放所有资源
  void dispose() {
    cancelAll();
  }
}
