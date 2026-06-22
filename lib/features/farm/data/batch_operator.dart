/// 批量操作引擎 (T6.1, T6.2)
///
/// Fan-Out 模式对多台打印机并发执行操作:
///   - 常规操作: 20 并发 (暂停/恢复/取消/GCode/温度)
///   - 急停: 40 并发, 5s 超时
///
/// 命令路由:
///   - MQTT 打印机 → MQTT 发布 + 等待 response
///   - HTTP 打印机 → HTTP POST + probeSingle 即时确认

import 'dart:async';

import 'farm_printer_state.dart';
import 'farm_store.dart';

/// 批量操作类型
enum BatchOperation {
  pause,
  resume,
  cancel,
  emergencyStop,
  gcode,
  setNozzleTemp,
  setBedTemp,
}

/// 批量操作器
class BatchOperator {
  final FarmStore _store;

  /// 命令发送回调（由 FarmMqttRouter 或 HttpPoller 提供）
  final Future<Map<String, dynamic>?> Function(
    String sn,
    String method,
    Map<String, dynamic>? params,
  )? onSendCommand;

  /// HTTP 即时确认回调（HTTP 降级模式专用）
  final Future<void> Function(String sn)? onProbeSingle;

  static const int maxConcurrency = 20;
  static const int highPriorityConcurrency = 40;
  static const Duration defaultTimeout = Duration(seconds: 30);
  static const Duration emergencyStopTimeout = Duration(seconds: 5);

  BatchOperator({
    required FarmStore store,
    this.onSendCommand,
    this.onProbeSingle,
  })  : _store = store;

  // ═══════════════════════════════════════════════════════════
  // 公共 API
  // ═══════════════════════════════════════════════════════════

  /// 批量暂停
  Future<List<BatchResult>> batchPause(List<String> printerSns) =>
      _fanOut(
        printerSns: printerSns,
        operation: BatchOperation.pause,
        method: 'printer.print.pause',
      );

  /// 批量恢复
  Future<List<BatchResult>> batchResume(List<String> printerSns) =>
      _fanOut(
        printerSns: printerSns,
        operation: BatchOperation.resume,
        method: 'printer.print.resume',
      );

  /// 批量取消
  Future<List<BatchResult>> batchCancel(List<String> printerSns) =>
      _fanOut(
        printerSns: printerSns,
        operation: BatchOperation.cancel,
        method: 'printer.print.cancel',
      );

  /// 批量急停 — 高优先级
  Future<List<BatchResult>> batchEmergencyStop() {
    final allSns = _store.allPrinters.map((p) => p.sn).toList();
    return _fanOut(
      printerSns: allSns,
      operation: BatchOperation.emergencyStop,
      method: 'printer.gcode.script',
      params: {'script': 'M112\n'},
      timeout: emergencyStopTimeout,
      maxConcurrency: highPriorityConcurrency,
    );
  }

  /// 批量发送 GCode
  Future<List<BatchResult>> batchGcode({
    required List<String> printerSns,
    required String gcode,
  }) =>
      _fanOut(
        printerSns: printerSns,
        operation: BatchOperation.gcode,
        method: 'printer.gcode.script',
        params: {'script': '$gcode\n'},
      );

  /// 批量设置喷嘴温度
  Future<List<BatchResult>> batchSetNozzleTemp({
    required List<String> printerSns,
    required double temp,
  }) =>
      _fanOut(
        printerSns: printerSns,
        operation: BatchOperation.setNozzleTemp,
        method: 'printer.gcode.script',
        params: {'script': 'M104 S${temp.toInt()}\n'},
      );

  /// 批量设置热床温度
  Future<List<BatchResult>> batchSetBedTemp({
    required List<String> printerSns,
    required double temp,
  }) =>
      _fanOut(
        printerSns: printerSns,
        operation: BatchOperation.setBedTemp,
        method: 'printer.gcode.script',
        params: {'script': 'M140 S${temp.toInt()}\n'},
      );

  // ═══════════════════════════════════════════════════════════
  // Fan-Out 核心
  // ═══════════════════════════════════════════════════════════

  /// Fan-Out 并发执行
  ///
  /// [printerSns] 目标打印机 SN 列表
  /// [operation] 操作类型
  /// [method] JSON-RPC 方法名
  /// [params] RPC 参数
  /// [timeout] 单台超时
  /// [maxConcurrency] 最大并发数
  Future<List<BatchResult>> _fanOut({
    required List<String> printerSns,
    required BatchOperation operation,
    required String method,
    Map<String, dynamic>? params,
    Duration timeout = defaultTimeout,
    int maxConcurrency = maxConcurrency,
  }) async {
    if (printerSns.isEmpty) return [];

    final results = <BatchResult>[];
    final semaphore = _Semaphore(maxConcurrency);

    final futures = printerSns.map((sn) async {
      await semaphore.acquire();
      final startTime = DateTime.now();

      try {
        // 获取打印机信息，确定通信方式
        final printer = _store.getPrinter(sn);
        if (printer == null) {
          final result = BatchResult(
            printerSn: sn,
            success: false,
            operation: operation.name,
            duration: DateTime.now().difference(startTime),
            error: '打印机未注册',
          );
          _store.onBatchResult(sn, result);
          results.add(result);
          return;
        }

        if (printer.isMqtt && onSendCommand != null) {
          // MQTT 通道
          try {
            final response = await onSendCommand!(sn, method, params)
                .timeout(timeout);
            final result = BatchResult(
              printerSn: sn,
              success: response != null,
              operation: operation.name,
              duration: DateTime.now().difference(startTime),
            );
            _store.onBatchResult(sn, result);
            results.add(result);
          } on TimeoutException {
            final result = BatchResult(
              printerSn: sn,
              success: false,
              operation: operation.name,
              duration: DateTime.now().difference(startTime),
              error: '命令超时 (${timeout.inSeconds}s)',
            );
            _store.onBatchResult(sn, result);
            results.add(result);
          }
        } else {
          // HTTP 降级通道
          try {
            await onSendCommand?.call(sn, method, params)
                .timeout(timeout);
            // HTTP 命令完成后立即探测状态
            await onProbeSingle?.call(sn);
            final result = BatchResult(
              printerSn: sn,
              success: true,
              operation: operation.name,
              duration: DateTime.now().difference(startTime),
            );
            _store.onBatchResult(sn, result);
            results.add(result);
          } catch (e) {
            final result = BatchResult(
              printerSn: sn,
              success: false,
              operation: operation.name,
              duration: DateTime.now().difference(startTime),
              error: e.toString(),
            );
            _store.onBatchResult(sn, result);
            results.add(result);
          }
        }
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return results;
  }
}

/// 内部信号量（不引入外部依赖）
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
