/// FarmCommandGateway — 统一指令网关
///
/// 提供单控 / 群控两个入口，封装请求 ID 生成、MqttTransportAdapter 交互、
/// Response Topic 动态订阅、并发控制等所有发送侧逻辑。
///
/// 接收侧（response 匹配）由 FarmMqttRouter._onMessage() 调用
/// UnifiedRequestTracker.complete() 完成，Gateway 不处理接收。
///
/// 架构位置:
///   FarmMqttRouter
///     ├── UnifiedRequestTracker (共享 — 发收双方的桥梁)
///     ├── FarmCommandGateway   (发送侧 — sendToOne / sendToMany)
///     └── _onMessage()         (接收侧 — 调 tracker.complete)
///
/// 使用示例:
///   // 单控
///   final result = await gateway.sendToOne(
///     sn: 'ABC123',
///     method: 'printer.print.pause',
///   );
///
///   // 群控
///   final handle = gateway.sendToMany(
///     sns: ['ABC', 'DEF', 'GHI'],
///     method: 'printer.print.pause',
///   );
///   handle.progressStream.listen((p) => print('${p.completed}/${p.total}'));
///   final results = await handle.results;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'broker_connection_manager.dart';
import 'farm_logger.dart';
import 'unified_request_tracker.dart';

/// 单条命令执行结果
class CommandResult {
  final String sn;
  final String method;
  final bool success;
  final Map<String, dynamic>? data; // response['result']
  final String? error;
  final Duration duration;

  const CommandResult({
    required this.sn,
    required this.method,
    required this.success,
    this.data,
    this.error,
    required this.duration,
  });

  factory CommandResult.fromResponse(
    String sn,
    String method,
    Duration duration,
    Map<String, dynamic>? response,
  ) {
    if (response == null) {
      debugPrint('[CMD] $sn/$method → timeout (${duration.inMilliseconds}ms)');
      return CommandResult(
        sn: sn,
        method: method,
        success: false,
        error: 'timeout',
        duration: duration,
      );
    }

    final rpcError = response['error'] as Map<String, dynamic>?;
    if (rpcError != null) {
      final errMsg = rpcError['message']?.toString() ?? 'unknown_rpc_error';
      final errCode = rpcError['code'];
      debugPrint('[CMD] $sn/$method → RPC error: code=$errCode msg="$errMsg" raw=${response['result']}');
      return CommandResult(
        sn: sn,
        method: method,
        success: false,
        error: errMsg,
        data: _extractData(response['result']),
        duration: duration,
      );
    }

    final resultData = _extractData(response['result']);
    final resultStr = response['result']?.toString();
    debugPrint('[CMD] $sn/$method → success (${duration.inMilliseconds}ms), result type=${response['result']?.runtimeType}, data=$resultData, raw=${resultStr != null && resultStr.length > 200 ? resultStr.substring(0, 200) : resultStr}');
    return CommandResult(
      sn: sn,
      method: method,
      success: true,
      data: resultData,
      duration: duration,
    );
  }

  /// 安全提取 result，处理 result 为字符串（如 "OK"）或其他非 Map 类型
  static Map<String, dynamic>? _extractData(dynamic result) {
    if (result == null) return null;
    if (result is Map<String, dynamic>) return result;
    // result 是字符串 "OK" 等非 Map 类型 → 不报错，返回 null
    return null;
  }

  @override
  String toString() =>
      'CommandResult($sn $method ${success ? "ok" : "FAIL"}${error != null ? " $error" : ""})';
}

/// 批次句柄 — 群控操作的返回类型
///
/// 两种消费方式:
/// 1. 流式: handle.progressStream.listen(...)  实时进度
/// 2. 等待: await handle.results                全部完成后拿结果列表
class BatchHandle {
  final String batchId;
  final List<String> targetSns;
  final String method;

  final UnifiedRequestTracker _tracker;
  final List<CommandResult> _results = [];
  Completer<List<CommandResult>>? _resultsCompleter;

  BatchHandle._({
    required this.batchId,
    required this.targetSns,
    required this.method,
    required UnifiedRequestTracker tracker,
  }) : _tracker = tracker {
    _resultsCompleter = Completer<List<CommandResult>>();
  }

  /// 实时进度流
  Stream<BatchProgress> get progressStream =>
      _tracker.batchProgressStream(batchId);

  /// 等待全部完成
  Future<List<CommandResult>> get results async {
    if (_resultsCompleter == null) return _results;
    return _resultsCompleter!.future;
  }

  /// 取消尚未执行的命令
  void cancel() {
    _tracker.cancelBatch(batchId);
  }

  /// 内部：记录单条结果
  void _addResult(CommandResult result) {
    _results.add(result);
  }

  /// 内部：标记批次全部发出后调用，启动结果等待
  void _allDispatched(int expectedCount) {
    // 监听进度流，全部完成时 resolve
    if (expectedCount == 0) {
      _resultsCompleter?.complete([]);
      _resultsCompleter = null;
      return;
    }

    // 已有结果 == expectedCount → 立即 resolve
    if (_results.length >= expectedCount) {
      _resultsCompleter?.complete(List.from(_results));
      _resultsCompleter = null;
      return;
    }

    _tracker.batchProgressStream(batchId).listen((progress) {
      if (progress.isDone) {
        _resultsCompleter?.complete(List.from(_results));
        _resultsCompleter = null;
      }
    });
  }
}

// ═══════════════════════════════════════════════════════════════
// FarmCommandGateway
// ═══════════════════════════════════════════════════════════════

class FarmCommandGateway {
  final UnifiedRequestTracker _tracker;
  final MqttTransportAdapter _transport;

  /// 已订阅 response topic 的设备
  final Set<String> _responseSubscribed = {};

  /// 默认并发数
  static const int defaultMaxConcurrency = 20;

  /// 急停并发数
  static const int highPriorityConcurrency = 40;

  FarmCommandGateway({
    required UnifiedRequestTracker tracker,
    required MqttTransportAdapter transport,
  })  : _tracker = tracker,
        _transport = transport;

  /// 暴露 tracker 供外部（FarmMqttRouter）在收到 response 时 complete
  UnifiedRequestTracker get tracker => _tracker;

  // ═══════════════════════════════════════════════════════════
  // 单控
  // ═══════════════════════════════════════════════════════════

  /// 向一台打印机发送 JSON-RPC 命令
  ///
  /// 返回 [CommandResult]，超时或失败时 success=false。
  Future<CommandResult> sendToOne({
    required String sn,
    required String method,
    Map<String, dynamic>? params,
    Duration timeout = defaultRequestTimeout,
  }) async {
    final startTime = DateTime.now();
    final requestId = _tracker.generateRequestId();

    final future = _tracker.track(sn, requestId, method, timeout: timeout);

    await _ensureResponseSubscribed(sn);
    await _publishRequest(sn, requestId, method, params);

    final response = await future;
    final duration = DateTime.now().difference(startTime);

    return CommandResult.fromResponse(sn, method, duration, response);
  }

  // ═══════════════════════════════════════════════════════════
  // 群控
  // ═══════════════════════════════════════════════════════════

  /// 向多台打印机发送同一条命令
  ///
  /// 返回 [BatchHandle]，支持:
  ///   - 实时进度流: handle.progressStream
  ///   - 等待全部结果: await handle.results
  ///
  /// [sns]                   目标打印机 SN 列表
  /// [method]                JSON-RPC 方法名
  /// [params]                方法参数
  /// [timeout]               单台超时
  /// [maxConcurrency]        最大并发数（常规 20，急停 40）
  BatchHandle sendToMany({
    required List<String> sns,
    required String method,
    Map<String, dynamic>? params,
    Duration timeout = defaultRequestTimeout,
    int maxConcurrency = defaultMaxConcurrency,
  }) {
    final batchId = _tracker.registerBatch(
      method: method,
      totalCount: sns.length,
    );

    final handle = BatchHandle._(
      batchId: batchId,
      targetSns: sns,
      method: method,
      tracker: _tracker,
    );

    // 异步执行 fan-out（不阻塞调用方）
    _fanOut(
      handle: handle,
      sns: sns,
      method: method,
      params: params,
      timeout: timeout,
      maxConcurrency: maxConcurrency,
    );

    return handle;
  }

  /// Fan-Out 核心：并发向多台打印机发送命令
  Future<void> _fanOut({
    required BatchHandle handle,
    required List<String> sns,
    required String method,
    Map<String, dynamic>? params,
    required Duration timeout,
    required int maxConcurrency,
  }) async {
    if (sns.isEmpty) {
      handle._allDispatched(0);
      return;
    }

    final semaphore = _Semaphore(maxConcurrency);
    final futures = <Future<void>>[];

    for (final sn in sns) {
      futures.add(_sendOneInBatch(
        handle: handle,
        sn: sn,
        method: method,
        params: params,
        timeout: timeout,
        semaphore: semaphore,
      ));
    }

    await Future.wait(futures);
    handle._allDispatched(sns.length);
  }

  /// 批次中的单台发送
  Future<void> _sendOneInBatch({
    required BatchHandle handle,
    required String sn,
    required String method,
    Map<String, dynamic>? params,
    required Duration timeout,
    required _Semaphore semaphore,
  }) async {
    await semaphore.acquire();
    final startTime = DateTime.now();

    try {
      final requestId = _tracker.generateRequestId();

      final future = _tracker.track(
        sn,
        requestId,
        method,
        batchId: handle.batchId,
        timeout: timeout,
      );

      await _ensureResponseSubscribed(sn);
      await _publishRequest(sn, requestId, method, params);

      final response = await future;
      final duration = DateTime.now().difference(startTime);
      handle._addResult(
        CommandResult.fromResponse(sn, method, duration, response),
      );
    } catch (e) {
      final duration = DateTime.now().difference(startTime);
      handle._addResult(CommandResult(
        sn: sn,
        method: method,
        success: false,
        error: e.toString(),
        duration: duration,
      ));
    } finally {
      semaphore.release();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 内部工具
  // ═══════════════════════════════════════════════════════════

  /// 确保已订阅 {sn}/response topic
  Future<void> _ensureResponseSubscribed(String sn) async {
    if (!_responseSubscribed.contains(sn)) {
      await _transport.subscribe('$sn/response', qos: 1);
      _responseSubscribed.add(sn);
      // 短暂延迟确保 Broker 端订阅生效
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 发布 JSON-RPC 请求到 {sn}/request
  Future<void> _publishRequest(
    String sn,
    int requestId,
    String method,
    Map<String, dynamic>? params,
  ) async {
    final request = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
      'id': requestId,
    };

    final payload = utf8.encode(jsonEncode(request));
    await _transport.publish('$sn/request', payload, qos: 1);

    FarmLogger.instance.logCommandSent(sn, method, params);
  }
}

// ═══════════════════════════════════════════════════════════════
// 内部信号量
// ═══════════════════════════════════════════════════════════════

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
