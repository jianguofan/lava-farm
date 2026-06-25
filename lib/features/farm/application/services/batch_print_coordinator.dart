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

import '../../data/farm_command_gateway.dart';
import '../../data/file_uploader.dart';

/// 群控打印中单台打印机的状态
enum BatchPrintPrinterState {
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

  const BatchPrintPrinterUpdate({
    required this.sn,
    required this.state,
    this.error,
    this.elapsed,
  });
}

/// 群控打印总体进度
class BatchPrintProgress {
  final int totalPrinters;
  final int uploadingCount;
  final int uploadDoneCount;
  final int startingPrintCount;
  final int successCount;
  final int failedCount;

  const BatchPrintProgress({
    required this.totalPrinters,
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
  final FarmCommandGateway? _gateway;

  final Map<String, BatchPrintPrinterState> _printerStates = {};
  final Map<String, String> _errors = {};
  final Map<String, Duration> _elapsed = {};
  int _uploadingCount = 0;
  int _uploadDoneCount = 0;
  int _startingPrintCount = 0;

  final List<String> _failedSns = [];

  Map<String, (String ip, int port, String apiKey)>? _lastConnectionInfo;
  String? _lastFileName;
  Uint8List? _lastFileBytes;

  final StreamController<BatchPrintPrinterUpdate> _updateController =
      StreamController<BatchPrintPrinterUpdate>.broadcast();
  final StreamController<BatchPrintProgress> _progressController =
      StreamController<BatchPrintProgress>.broadcast();

  BatchPrintCoordinator({
    FileUploader? uploader,
    FarmCommandGateway? gateway,
  })  : _uploader = uploader ?? FileUploader(),
        _gateway = gateway;

  Stream<BatchPrintPrinterUpdate> get printerUpdateStream =>
      _updateController.stream;

  Stream<BatchPrintProgress> get progressStream =>
      _progressController.stream;

  List<String> get failedSns => List.unmodifiable(_failedSns);

  Map<String, BatchPrintPrinterState> get printerStates =>
      Map.unmodifiable(_printerStates);

  /// 执行群控打印
  Future<void> execute({
    required List<String> printerSns,
    required Map<String, (String ip, int port, String apiKey)> connectionInfo,
    required String localFilePath,
    required String remoteFileName,
    int printPlate = 1,
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

    for (final sn in printerSns) {
      _printerStates[sn] = BatchPrintPrinterState.uploading;
    }
    _emitProgress();

    final semaphore = _Semaphore(FileUploader.maxConcurrent);
    final futures = <Future<void>>[];

    for (final sn in printerSns) {
      futures.add(_runPrinterPipeline(
        sn: sn,
        connectionInfo: connectionInfo,
        fileName: remoteFileName,
        fileType: fileType,
        printPlate: printPlate,
        fileBytes: fileBytes,
        semaphore: semaphore,
      ));
    }

    await Future.wait(futures);
  }

  /// 重试失败的打印机
  Future<void> retryFailed({int printPlate = 1}) async {
    if (_failedSns.isEmpty) return;
    if (_lastConnectionInfo == null || _lastFileName == null || _lastFileBytes == null) return;

    final failedCopy = List<String>.from(_failedSns);
    _failedSns.clear();

    final fileType = _fileType(_lastFileName!);

    for (final sn in failedCopy) {
      _printerStates[sn] = BatchPrintPrinterState.uploading;
      _errors.remove(sn);
      _elapsed.remove(sn);
      _updateUI(BatchPrintPrinterUpdate(sn: sn, state: BatchPrintPrinterState.uploading));
    }
    _emitProgress();

    final semaphore = _Semaphore(FileUploader.maxConcurrent);
    final futures = <Future<void>>[];

    for (final sn in failedCopy) {
      futures.add(_runPrinterPipeline(
        sn: sn,
        connectionInfo: _lastConnectionInfo!,
        fileName: _lastFileName!,
        fileType: fileType,
        printPlate: printPlate,
        fileBytes: _lastFileBytes!,
        semaphore: semaphore,
      ));
    }

    await Future.wait(futures);
  }

  void cancel() {
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
  }) async {
    await semaphore.acquire();
    try {
      final info = connectionInfo[sn];
      if (info == null) {
        _fail(sn, '缺少连接信息');
        return;
      }

      final startTime = DateTime.now();

      _transition(sn, BatchPrintPrinterState.uploading);

      final uploadResult = await _uploader.uploadBytesToPrinter(
        sn: sn,
        ip: info.$1,
        port: info.$2,
        apiKey: info.$3,
        fileName: fileName,
        fileBytes: fileBytes,
      );

      if (!uploadResult.success) {
        final err = uploadResult.error ?? '上传失败';
        _fail(sn, err);
        return;
      }

      _transition(sn, BatchPrintPrinterState.uploadDone);

      final gateway = _gateway;
      if (gateway == null) {
        _fail(sn, 'MQTT 未连接，无法启动打印');
        return;
      }

      _transition(sn, BatchPrintPrinterState.startingPrint);

      final printResult = await gateway.sendToOne(
        sn: sn,
        method: 'server.files.start_local_print',
        params: {
          'type': fileType,
          'path': fileName,
          'print_plate': printPlate,
        },
      );

      if (printResult.success) {
        _transition(sn, BatchPrintPrinterState.success,
            elapsed: DateTime.now().difference(startTime));
      } else {
        _fail(sn, printResult.error ?? 'unknown');
      }
    } catch (e) {
      _fail(sn, e.toString());
    } finally {
      semaphore.release();
    }
  }

  void _transition(String sn, BatchPrintPrinterState state, {Duration? elapsed}) {
    _printerStates[sn] = state;
    if (elapsed != null) _elapsed[sn] = elapsed;

    switch (state) {
      case BatchPrintPrinterState.uploading:   _uploadingCount++; break;
      case BatchPrintPrinterState.uploadDone:   _uploadingCount--; _uploadDoneCount++; break;
      case BatchPrintPrinterState.startingPrint: _uploadDoneCount--; _startingPrintCount++; break;
      case BatchPrintPrinterState.success:      _startingPrintCount--; break;
      default: break;
    }

    _updateUI(BatchPrintPrinterUpdate(sn: sn, state: state, elapsed: elapsed));
    _emitProgress();
  }

  void _fail(String sn, String error) {
    final prev = _printerStates[sn];
    if (prev == BatchPrintPrinterState.uploading) _uploadingCount--;
    if (prev == BatchPrintPrinterState.uploadDone) _uploadDoneCount--;
    if (prev == BatchPrintPrinterState.startingPrint) _startingPrintCount--;

    final failState = prev == BatchPrintPrinterState.uploading || prev == null
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
    _uploadingCount = 0;
    _uploadDoneCount = 0;
    _startingPrintCount = 0;
    _failedSns.clear();
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
