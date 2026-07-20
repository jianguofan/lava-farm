/// BatchPrintCoordinator — 群控打印协调器（应用层编排服务）
///
/// 负责多台打印机的"上传 + 启动打印"两阶段 pipeline：
///   1. HTTP 上传 3MF/GCode 文件到每台打印机（复用 FileUploader）
///   2. 上传成功后立即通过 MQTT 发送 server.files.start_local_print 命令
///
/// 每台打印机的 pipeline 独立运行，互不影响。
/// 上传阶段最多 5 台并发（保守带宽），打印启动阶段无额外限制。
/// 通过 Stream 向 UI 上报每台打印机的状态变化和总体进度。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../data/farm_command_gateway.dart';
import '../../data/file_uploader.dart' show FileUploader, UploadCancelToken;

/// 群控打印中单台打印机的状态
enum BatchPrintPrinterState {
  queued,
  uploading,
  uploadDone,
  startingPrint,
  success,
  uploadFailed,
  printFailed,
}

/// 单台打印机状态更新事件
class BatchPrintPrinterUpdate {
  final String sn;
  final BatchPrintPrinterState state;
  final String? error;
  final Duration? elapsed;

  /// 上传进度 0.0 ~ 1.0（仅 uploading 状态有效）
  final double? uploadProgress;

  const BatchPrintPrinterUpdate({
    required this.sn,
    required this.state,
    this.error,
    this.elapsed,
    this.uploadProgress,
  });
}

/// 群控打印总体进度
class BatchPrintProgress {
  final int totalPrinters;
  final int queuedCount;
  final int uploadingCount;
  final int uploadDoneCount;
  final int startingPrintCount;
  final int successCount;
  final int failedCount;

  const BatchPrintProgress({
    required this.totalPrinters,
    this.queuedCount = 0,
    this.uploadingCount = 0,
    this.uploadDoneCount = 0,
    this.startingPrintCount = 0,
    this.successCount = 0,
    this.failedCount = 0,
  });

  int get completedCount => successCount + failedCount;
  double get progress => totalPrinters > 0 ? completedCount / totalPrinters : 0;
  bool get isDone => completedCount >= totalPrinters;
  bool get hasFailures => failedCount > 0;
}

/// 群控打印协调器
class BatchPrintCoordinator {
  final FileUploader _uploader;

  final Map<String, BatchPrintPrinterState> _printerStates = {};
  final Map<String, String> _errors = {};
  final Map<String, Duration> _elapsed = {};
  int _queuedCount = 0;
  int _uploadingCount = 0;
  int _uploadDoneCount = 0;
  int _startingPrintCount = 0;

  final List<String> _failedSns = [];

  /// 每台打印机的上传取消令牌
  final Map<String, UploadCancelToken> _cancelTokens = {};

  Map<String, (String ip, int port, String apiKey)>? _lastConnectionInfo;
  String? _lastFileName;
  Uint8List? _lastFileBytes;
  String? _lastPrePrintGcode;

  /// 多盘同打缓存：每台打印机各自打印的盘号 / 耗材映射 G-code（key = sn）。
  /// 协调器为单例 Provider，缓存跨页面留存，供 retryFailed 复用。
  Map<String, int>? _lastPlateBySn;
  Map<String, String?>? _lastGcodeBySn;

  final StreamController<BatchPrintPrinterUpdate> _updateController =
      StreamController<BatchPrintPrinterUpdate>.broadcast();
  final StreamController<BatchPrintProgress> _progressController =
      StreamController<BatchPrintProgress>.broadcast();

  BatchPrintCoordinator({
    FileUploader? uploader,
  }) : _uploader = uploader ?? FileUploader();

  Stream<BatchPrintPrinterUpdate> get printerUpdateStream =>
      _updateController.stream;

  Stream<BatchPrintProgress> get progressStream => _progressController.stream;

  List<String> get failedSns => List.unmodifiable(_failedSns);

  Map<String, BatchPrintPrinterState> get printerStates =>
      Map.unmodifiable(_printerStates);

  /// 执行群控打印
  Future<void> execute({
    required List<String> printerSns,
    required Map<String, (String ip, int port, String apiKey)> connectionInfo,
    required String localFilePath,
    required String remoteFileName,
    required FarmCommandGateway gateway,
    int printPlate = 1,
    String? prePrintGcode,
    Map<String, int>? plateBySn,
    Map<String, String?>? gcodeBySn,
  }) async {
    _reset();

    if (printerSns.isEmpty) return;

    final file = File(localFilePath);
    if (!await file.exists()) {
      for (final sn in printerSns) {
        _fail(sn, '文件不存在: $localFilePath');
      }
      _emitProgress();
      return;
    }

    final fileBytes = await file.readAsBytes();
    final fileType = _fileType(remoteFileName);

    _lastConnectionInfo = connectionInfo;
    _lastFileName = remoteFileName;
    _lastFileBytes = Uint8List.fromList(fileBytes);
    _lastPrePrintGcode = prePrintGcode;
    // 多盘同打：缓存按打印机的盘号 / 耗材映射（单盘时为 null，retry 走兜底值）。
    _lastPlateBySn = plateBySn;
    _lastGcodeBySn = gcodeBySn;

    _queuedCount = printerSns.length;
    for (final sn in printerSns) {
      _printerStates[sn] = BatchPrintPrinterState.queued;
      // 通知 UI：每台打印机初始排队状态
      _updateUI(BatchPrintPrinterUpdate(
          sn: sn, state: BatchPrintPrinterState.queued));
    }
    _emitProgress();

    final fileSizeKB = (fileBytes.length / 1024).toStringAsFixed(0);
    debugPrint(
        '[BatchPrint] 🚀 开始群控打印: ${printerSns.length}台, 文件=${remoteFileName} (${fileSizeKB}KB)');

    final execStart = DateTime.now();
    final semaphore = _Semaphore(FileUploader.maxConcurrent);
    final futures = <Future<void>>[];

    for (final sn in printerSns) {
      // 多盘同打：按打印机解析其打印盘号与耗材映射；缺省回退全局值。
      final plate = plateBySn?[sn] ?? printPlate;
      final gcode = gcodeBySn?[sn] ?? prePrintGcode;
      futures.add(_runPrinterPipeline(
        sn: sn,
        connectionInfo: connectionInfo,
        fileName: remoteFileName,
        fileType: fileType,
        printPlate: plate,
        fileBytes: fileBytes,
        semaphore: semaphore,
        gateway: gateway,
        prePrintGcode: gcode,
      ));
    }

    await Future.wait(futures);

    final execElapsed = DateTime.now().difference(execStart);
    final successes = _printerStates.values
        .where((s) => s == BatchPrintPrinterState.success)
        .length;
    final failures = _printerStates.values
        .where((s) =>
            s == BatchPrintPrinterState.uploadFailed ||
            s == BatchPrintPrinterState.printFailed)
        .length;
    debugPrint(
        '[BatchPrint] 🏁 群控打印完成: total=${printerSns.length} ✅=$successes ❌=$failures elapsed=${execElapsed.inSeconds}s');
  }

  /// 重试失败的打印机
  Future<void> retryFailed({
    required FarmCommandGateway gateway,
    int printPlate = 1,
    Map<String, int>? plateBySn,
    Map<String, String?>? gcodeBySn,
  }) async {
    if (_failedSns.isEmpty) return;
    if (_lastConnectionInfo == null ||
        _lastFileName == null ||
        _lastFileBytes == null) return;

    final failedCopy = List<String>.from(_failedSns);
    _failedSns.clear();

    final fileType = _fileType(_lastFileName!);

    _queuedCount += failedCopy.length;
    for (final sn in failedCopy) {
      _printerStates[sn] = BatchPrintPrinterState.queued;
      _errors.remove(sn);
      _elapsed.remove(sn);
      _updateUI(BatchPrintPrinterUpdate(
          sn: sn, state: BatchPrintPrinterState.queued));
    }
    _emitProgress();

    debugPrint('[BatchPrint] 🔄 重试失败项: ${failedCopy.length}台');
    final retryStart = DateTime.now();
    final semaphore = _Semaphore(FileUploader.maxConcurrent);
    final futures = <Future<void>>[];

    for (final sn in failedCopy) {
      // 多盘重试：优先用传入映射，其次用 execute 缓存，最后回退单盘兜底值。
      final plate = plateBySn?[sn] ?? _lastPlateBySn?[sn] ?? printPlate;
      final gcode = gcodeBySn?[sn] ?? _lastGcodeBySn?[sn] ?? _lastPrePrintGcode;
      futures.add(_runPrinterPipeline(
        sn: sn,
        connectionInfo: _lastConnectionInfo!,
        fileName: _lastFileName!,
        fileType: fileType,
        printPlate: plate,
        fileBytes: _lastFileBytes!,
        semaphore: semaphore,
        gateway: gateway,
        prePrintGcode: gcode,
      ));
    }

    await Future.wait(futures);

    final retryElapsed = DateTime.now().difference(retryStart);
    final retrySuc = _printerStates.values
        .where((s) => s == BatchPrintPrinterState.success)
        .length;
    debugPrint(
        '[BatchPrint] 🏁 重试完成: ${retrySuc}/${failedCopy.length} 成功 elapsed=${retryElapsed.inSeconds}s');
  }

  /// 取消指定打印机的上传
  void cancelUpload(String sn) {
    _cancelTokens[sn]?.cancel();
  }

  /// 取消所有进行中的上传
  void cancelAllUploads() {
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
  }

  void cancel() {
    cancelAllUploads();
    _updateController.close();
    _progressController.close();
    _reset();
  }

  void dispose() {
    cancel();
  }

  Future<void> _runPrinterPipeline({
    required String sn,
    required Map<String, (String ip, int port, String apiKey)> connectionInfo,
    required String fileName,
    required String fileType,
    required int printPlate,
    required List<int> fileBytes,
    required _Semaphore semaphore,
    required FarmCommandGateway gateway,
    String? prePrintGcode,
  }) async {
    final pipelineStart = DateTime.now();
    await semaphore.acquire();
    try {
      final info = connectionInfo[sn];
      if (info == null) {
        _fail(sn, '缺少连接信息');
        return;
      }

      final startTime = DateTime.now();

      _transition(sn, BatchPrintPrinterState.uploading);
      debugPrint(
          '[BatchPrint] $sn: 📤 开始上传 $fileName (${(fileBytes.length / 1024).toStringAsFixed(0)}KB)');

      final cancelToken = UploadCancelToken();
      _cancelTokens[sn] = cancelToken;

      final uploadResult = await _uploader.uploadBytesToPrinter(
        sn: sn,
        ip: info.$1,
        port: info.$2,
        apiKey: info.$3,
        fileName: fileName,
        fileBytes: fileBytes,
        cancelToken: cancelToken,
        onProgress: (sent, total) {
          _updateUI(BatchPrintPrinterUpdate(
            sn: sn,
            state: BatchPrintPrinterState.uploading,
            uploadProgress: total > 0 ? sent / total : 0,
          ));
        },
      );

      _cancelTokens.remove(sn);

      if (uploadResult.isCancelled) {
        _fail(sn, '上传已取消');
        return;
      }

      final uploadElapsed = DateTime.now().difference(startTime);
      debugPrint('[BatchPrint] $sn: ${uploadResult.success ? "✅" : "❌"} 上传完成 '
          'elapsed=${uploadElapsed.inMilliseconds}ms '
          'speed=${(fileBytes.length / 1024 / uploadElapsed.inMilliseconds * 1000).toStringAsFixed(0)}KB/s');

      if (!uploadResult.success) {
        final err = uploadResult.error ?? '上传失败';
        _fail(sn, err);
        return;
      }

      _transition(sn, BatchPrintPrinterState.uploadDone);

      // 打印前下发耗材→打印头映射 G-code（多色映射）。失败仅记录，不阻断打印。
      if (prePrintGcode != null && prePrintGcode.isNotEmpty) {
        debugPrint('[BatchPrint] $sn: 🎨 下发耗材映射 G-code');
        final mapResult = await gateway.sendToOne(
          sn: sn,
          method: 'printer.gcode.script',
          params: {'script': prePrintGcode},
        );
        if (!mapResult.success) {
          debugPrint('[BatchPrint] $sn: ⚠️ 耗材映射下发失败（继续打印）: ${mapResult.error}');
        }
      }

      _transition(sn, BatchPrintPrinterState.startingPrint);
      final printStart = DateTime.now();

      final printParams = {
        'type': fileType,
        'path': fileName,
        'print_plate': printPlate,
      };
      debugPrint(
          '[BatchPrint] $sn: 🖨️ 发送打印命令 method=server.files.start_local_print');
      debugPrint('[BatchPrint] $sn:    params=$printParams');

      final printResult = await gateway.sendToOne(
        sn: sn,
        method: 'server.files.start_local_print',
        params: printParams,
      );

      final printElapsed = DateTime.now().difference(printStart);
      debugPrint('[BatchPrint] $sn: ${printResult.success ? "✅" : "❌"} 打印命令结果 '
          'success=${printResult.success} error=${printResult.error} '
          'elapsed=${printElapsed.inMilliseconds}ms');

      if (printResult.success) {
        final totalElapsed = DateTime.now().difference(pipelineStart);
        debugPrint(
            '[BatchPrint] $sn: 🎉 全部完成! upload=${uploadElapsed.inMilliseconds}ms '
            'print=${printElapsed.inMilliseconds}ms total=${totalElapsed.inMilliseconds}ms');
        _transition(sn, BatchPrintPrinterState.success,
            elapsed: DateTime.now().difference(startTime));
      } else {
        _fail(sn, printResult.error ?? 'unknown');
      }
    } catch (e) {
      debugPrint('[BatchPrint] $sn: 💥 异常: $e');
      _fail(sn, e.toString());
    } finally {
      semaphore.release();
    }
  }

  void _transition(String sn, BatchPrintPrinterState state,
      {Duration? elapsed}) {
    _printerStates[sn] = state;
    if (elapsed != null) _elapsed[sn] = elapsed;

    switch (state) {
      case BatchPrintPrinterState.uploading:
        _queuedCount--;
        _uploadingCount++;
        break;
      case BatchPrintPrinterState.uploadDone:
        _uploadingCount--;
        _uploadDoneCount++;
        break;
      case BatchPrintPrinterState.startingPrint:
        _uploadDoneCount--;
        _startingPrintCount++;
        break;
      case BatchPrintPrinterState.success:
        _startingPrintCount--;
        break;
      default:
        break;
    }

    _updateUI(BatchPrintPrinterUpdate(sn: sn, state: state, elapsed: elapsed));
    _emitProgress();
  }

  void _fail(String sn, String error) {
    final prev = _printerStates[sn];
    if (prev == BatchPrintPrinterState.queued) _queuedCount--;
    if (prev == BatchPrintPrinterState.uploading) _uploadingCount--;
    if (prev == BatchPrintPrinterState.uploadDone) _uploadDoneCount--;
    if (prev == BatchPrintPrinterState.startingPrint) _startingPrintCount--;

    final failState = prev == BatchPrintPrinterState.uploading ||
            prev == BatchPrintPrinterState.queued ||
            prev == null
        ? BatchPrintPrinterState.uploadFailed
        : BatchPrintPrinterState.printFailed;

    _printerStates[sn] = failState;
    _errors[sn] = error;
    _failedSns.add(sn);

    _updateUI(BatchPrintPrinterUpdate(sn: sn, state: failState, error: error));
    _emitProgress();
  }

  void _updateUI(BatchPrintPrinterUpdate update) {
    if (!_updateController.isClosed) _updateController.add(update);
  }

  void _emitProgress() {
    if (_progressController.isClosed) return;

    final total = _printerStates.length;
    if (total == 0) return;

    int successCount = 0;
    int failedCount = 0;

    for (final state in _printerStates.values) {
      if (state == BatchPrintPrinterState.success) successCount++;
      if (state == BatchPrintPrinterState.uploadFailed ||
          state == BatchPrintPrinterState.printFailed) failedCount++;
    }

    _progressController.add(BatchPrintProgress(
      totalPrinters: total,
      queuedCount: _queuedCount,
      uploadingCount: _uploadingCount,
      uploadDoneCount: _uploadDoneCount,
      startingPrintCount: _startingPrintCount,
      successCount: successCount,
      failedCount: failedCount,
    ));
  }

  void _reset() {
    _printerStates.clear();
    _errors.clear();
    _elapsed.clear();
    _queuedCount = 0;
    _uploadingCount = 0;
    _uploadDoneCount = 0;
    _startingPrintCount = 0;
    _failedSns.clear();
    _cancelTokens.clear();
  }

  static String _fileType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.3mf')) return '3mf';
    if (lower.endsWith('.zip')) return 'zip';
    return 'gcode';
  }
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
