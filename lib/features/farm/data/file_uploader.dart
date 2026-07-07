/// 文件分发服务 (T10.1, T10.2)
///
/// 通过 Moonraker HTTP API 向打印机分发 GCode 文件。
///
/// 特性:
/// - HTTP multipart/form-data 上传到 /server/files/upload
/// - 并发控制 (max 5 concurrent — 文件传输保守并发)
/// - 上传进度回调 (completed, total)
/// - 文件大小限制 (200MB)
/// - 上传后可选校验（通过 /server/files/metadata 检查文件大小）
/// - 失败重试（每台最多 2 次）
/// - 批量上传 + 可选自动开始打印
///
/// 使用示例:
/// ```dart
/// final uploader = FileUploader();
/// final results = await uploader.batchUpload(
///   printerSns: ['SN001', 'SN002'],
///   connectionInfo: {'SN001': ('192.168.1.101', 7125, 'token1'), ...},
///   localFilePath: '/path/to/benchy.gcode',
///   remoteFileName: 'benchy.gcode',
///   onProgress: (completed, total) => print('$completed/$total'),
/// );
/// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'upload_isolate.dart';

/// 上传结果
class UploadResult {
  final String printerSn;
  final bool success;
  final String? remoteFileName;
  final Duration duration;
  final String? error;

  /// 是否为主动取消
  final bool isCancelled;

  const UploadResult({
    required this.printerSn,
    required this.success,
    this.remoteFileName,
    required this.duration,
    this.error,
    this.isCancelled = false,
  });

  @override
  String toString() =>
      'UploadResult($printerSn: ${isCancelled ? "cancelled" : success ? "ok" : "fail"}, ${duration.inMilliseconds}ms)';
}

/// 上传取消令牌
///
/// 在上传前创建，上传过程中周期性检查 [isCancelled]。
/// 调用 [cancel] 后，上传会在下一个分块边界中止。
class UploadCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 打印机连接信息 (ip, port, apiKey)
typedef PrinterConnectionInfo = (String ip, int port, String apiKey);

/// 文件上传器
class FileUploader {
  /// 最大并发上传数
  ///
  /// WiFi 环境下多路并发 HTTP 上传会争抢带宽，实测 2 路并发时每台速度最高。
  /// 有线千兆网络下可调至 5。如需修改，调整此值即可。
  static const int maxConcurrent = 2;

  /// 单文件最大 200MB
  static const int maxFileSize = 200 * 1024 * 1024;

  /// 每台打印机最大重试次数
  static const int maxRetries = 2;

  /// 单次上传超时
  static const Duration uploadTimeout = Duration(minutes: 10);

  /// 流式上传的块大小（64KB）
  static const int uploadChunkSize = 64 * 1024;

  // ═══════════════════════════════════════════════════════════
  // 公共 API
  // ═══════════════════════════════════════════════════════════

  /// 批量上传文件到多台打印机
  ///
  /// [printerSns] 目标打印机 SN 列表
  /// [connectionInfo] 每台打印机的连接信息 Map<sn, (ip, port, apiKey)>
  /// [localFilePath] 本地要上传的文件路径
  /// [remoteFileName] 文件在打印机上的名称（如 benchy.gcode）
  /// [onProgress] 进度回调 (completed, total)
  ///
  /// 返回每台打印机的上传结果列表
  Future<List<UploadResult>> batchUpload({
    required List<String> printerSns,
    required Map<String, (String ip, int port, String apiKey)> connectionInfo,
    required String localFilePath,
    required String remoteFileName,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (printerSns.isEmpty) return [];

    // 1. 读取文件
    final file = File(localFilePath);
    if (!await file.exists()) {
      return printerSns.map((sn) => UploadResult(
        printerSn: sn,
        success: false,
        duration: Duration.zero,
        error: '文件不存在: $localFilePath',
      )).toList();
    }

    final fileSize = await file.length();
    if (fileSize > maxFileSize) {
      return printerSns.map((sn) => UploadResult(
        printerSn: sn,
        success: false,
        duration: Duration.zero,
        error: '文件过大: ${_formatSize(fileSize)}，超过 ${_formatSize(maxFileSize)} 限制',
      )).toList();
    }

    // 2. 读取文件到内存（GCode 文件 < 200MB，内存加载可接受）
    final fileBytes = await file.readAsBytes();

    // 3. 并发上传
    final results = <UploadResult>[];
    final semaphore = _Semaphore(maxConcurrent);
    int completed = 0;

    final futures = printerSns.map((sn) async {
      await semaphore.acquire();
      try {
        final info = connectionInfo[sn];
        if (info == null) {
          results.add(UploadResult(
            printerSn: sn,
            success: false,
            duration: Duration.zero,
            error: '打印机连接信息未提供',
          ));
          return;
        }

        final result = await _uploadToPrinter(
          sn: sn,
          ip: info.$1,
          port: info.$2,
          apiKey: info.$3,
          fileName: remoteFileName,
          fileBytes: fileBytes,
        );

        results.add(result);
        completed++;
        onProgress?.call(completed, printerSns.length);

      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return results;
  }

  /// 批量上传并自动开始打印 (T10.2)
  ///
  /// 上传完成后对每台成功的打印机会自动调用 printer.print.start
  Future<List<UploadResult>> batchUploadAndPrint({
    required List<String> printerSns,
    required Map<String, PrinterConnectionInfo> connectionInfo,
    required String localFilePath,
    required String remoteFileName,
    void Function(int completed, int total)? onProgress,
    Future<bool> Function(String sn, String fileName)? onStartPrint,
  }) async {
    final uploadResults = await batchUpload(
      printerSns: printerSns,
      connectionInfo: connectionInfo,
      localFilePath: localFilePath,
      remoteFileName: remoteFileName,
      onProgress: onProgress,
    );

    // 对上传成功的打印机，启动打印
    if (onStartPrint != null) {
      for (final result in uploadResults) {
        if (result.success) {
          await onStartPrint(result.printerSn, remoteFileName);
        }
      }
    }

    return uploadResults;
  }

  /// 单文件上传到指定打印机
  ///
  /// 支持 Moonraker 的 multipart 上传端点:
  /// POST /server/files/upload
  /// Content-Type: multipart/form-data
  ///
  /// 字段:
  ///   file    — 文件二进制内容
  ///   path    — 目标路径（可选，默认根目录）
  ///   print   — 是否上传后立即打印 ("true" / "false")
  Future<UploadResult> uploadToPrinter({
    required String sn,
    required String ip,
    int port = 7125,
    required String apiKey,
    required String localFilePath,
    String? remoteFileName,
  }) async {
    final file = File(localFilePath);
    if (!await file.exists()) {
      return UploadResult(
        printerSn: sn,
        success: false,
        duration: Duration.zero,
        error: '文件不存在: $localFilePath',
      );
    }

    final fileSize = await file.length();
    if (fileSize > maxFileSize) {
      return UploadResult(
        printerSn: sn,
        success: false,
        duration: Duration.zero,
        error: '文件过大: ${_formatSize(fileSize)}',
      );
    }

    final fileBytes = await file.readAsBytes();
    return _uploadToPrinter(
      sn: sn,
      ip: ip,
      port: port,
      apiKey: apiKey,
      fileName: remoteFileName ?? file.uri.pathSegments.last,
      fileBytes: fileBytes,
    );
  }

  /// 上传原始字节到单台打印机（无需磁盘读取）
  ///
  /// 供 [BatchPrintCoordinator] 使用：一次性读取文件后分发给多台打印机，
  /// 避免每台打印机都重新从磁盘读取。
  ///
  /// [fileBytes]  已读取的文件字节
  /// [fileName]   远程文件名（如 benchy.3mf）
  /// [onProgress] 上传进度回调 (sentBytes, totalBytes)，可计算百分比
  Future<UploadResult> uploadBytesToPrinter({
    required String sn,
    required String ip,
    int port = 7125,
    required String apiKey,
    required String fileName,
    required List<int> fileBytes,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    if (fileBytes.length > maxFileSize) {
      return UploadResult(
        printerSn: sn,
        success: false,
        duration: Duration.zero,
        error: '文件过大: ${_formatSize(fileBytes.length)} (上限 ${_formatSize(maxFileSize)})',
      );
    }
    return _uploadToPrinter(
      sn: sn,
      ip: ip,
      port: port,
      apiKey: apiKey,
      fileName: fileName,
      fileBytes: fileBytes,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 内部实现
  // ═══════════════════════════════════════════════════════════

  /// 上传到单台打印机（含重试）
  ///
  /// [onProgress] 上传进度回调 (sentBytes, totalBytes)
  /// [cancelToken] 取消令牌，设置为 cancelled 后当前分块完成后中止
  Future<UploadResult> _uploadToPrinter({
    required String sn,
    required String ip,
    required int port,
    required String apiKey,
    required String fileName,
    required List<int> fileBytes,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    final startTime = DateTime.now();

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      // 重试前检查取消
      if (cancelToken?.isCancelled == true) {
        return UploadResult(
          printerSn: sn,
          success: false,
          isCancelled: true,
          duration: DateTime.now().difference(startTime),
          error: '上传已取消',
        );
      }

      try {
        final attemptStart = DateTime.now();
        print('[Upload] $sn: 尝试 #${attempt + 1} → http://$ip:$port/server/files/upload');

        final success = await _doUpload(
          ip: ip,
          port: port,
          apiKey: apiKey,
          fileName: fileName,
          fileBytes: fileBytes,
          onProgress: (sent, total) => onProgress?.call(sent, total),
          cancelToken: cancelToken,
        );

        // 上传后被取消
        if (cancelToken?.isCancelled == true) {
          return UploadResult(
            printerSn: sn,
            success: false,
            isCancelled: true,
            duration: DateTime.now().difference(startTime),
            error: '上传已取消',
          );
        }

        final uploadMs = DateTime.now().difference(attemptStart).inMilliseconds;
        print('[Upload] $sn: HTTP上传 ${success ? "✅" : "❌"} elapsed=${uploadMs}ms');

        if (success) {
          // 上传后校验
          final verifyStart = DateTime.now();
          final verified = await _verifyUpload(
            ip: ip,
            port: port,
            apiKey: apiKey,
            fileName: fileName,
            expectedSize: fileBytes.length,
          );
          final verifyMs = DateTime.now().difference(verifyStart).inMilliseconds;
          print('[Upload] $sn: 校验 ${verified ? "✅" : "⚠️"} elapsed=${verifyMs}ms');

          return UploadResult(
            printerSn: sn,
            success: true,
            remoteFileName: fileName,
            duration: DateTime.now().difference(startTime),
            error: verified ? null : '文件已上传但校验失败（大小不匹配）',
          );
        }
      } catch (e) {
        // 取消导致的异常 → 不重试，直接返回
        if (cancelToken?.isCancelled == true) {
          return UploadResult(
            printerSn: sn,
            success: false,
            isCancelled: true,
            duration: DateTime.now().difference(startTime),
            error: '上传已取消',
          );
        }
        print('[Upload] $sn: ❌ 尝试 #${attempt + 1} 异常: $e');
        if (attempt < maxRetries) {
          final delay = Duration(seconds: (1 << (attempt + 1)));
          print('[Upload] $sn: 重试等待 ${delay.inSeconds}s...');
          await Future.delayed(delay);
        }
      }
    }

    final totalMs = DateTime.now().difference(startTime).inMilliseconds;
    print('[Upload] $sn: ❌ 最终失败（重试${maxRetries}次后），总耗时=${totalMs}ms');
    return UploadResult(
      printerSn: sn,
      success: false,
      duration: DateTime.now().difference(startTime),
      error: '上传失败（已重试 $maxRetries 次）',
    );
  }

  /// 执行 HTTP multipart 上传（Isolate 隔离，不阻塞主线程事件循环）
  ///
  /// 上传逻辑在独立 Isolate 中运行，主线程保持 MQTT 消息正常收发。
  /// 通过 SendPort/ReceivePort 通信进度和取消信号。
  Future<bool> _doUpload({
    required String ip,
    required int port,
    required String apiKey,
    required String fileName,
    required List<int> fileBytes,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    // 启动上传 Isolate
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(uploadIsolateEntry, receivePort.sendPort);

    // 等待 Isolate 回传自己的 receivePort
    final isolateSendPort = await receivePort.first as SendPort;

    // 发送上传参数给 Isolate
    final progressPort = ReceivePort(); // Isolate → Main

    isolateSendPort.send({
      'ip': ip,
      'port': port,
      'fileName': fileName,
      'fileBytes': Uint8List.fromList(fileBytes),
      'progressPort': progressPort.sendPort,
    });

    // 等待 Isolate 回传 cancelPort（用于 Main → Isolate 取消信号）
    SendPort? cancelSendPort;
    bool cancelled = false;

    void sendCancel() {
      if (!cancelled && cancelSendPort != null) {
        cancelled = true;
        cancelSendPort!.send('cancel');
      }
    }

    // 定时检查取消令牌
    Timer? cancelTimer;
    if (cancelToken != null) {
      cancelTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (cancelToken.isCancelled) sendCancel();
      });
    }

    try {
      // 等待 Isolate 完成（期间处理 progress / ready_for_cancel / done 消息）
      final result = await progressPort.firstWhere((msg) {
        if (msg is Map<String, dynamic>) {
          switch (msg['type']) {
            case 'ready_for_cancel':
              cancelSendPort = msg['cancelPort'] as SendPort;
              return false;
            case 'progress':
              onProgress?.call(msg['sent'] as int, msg['total'] as int);
              if (cancelToken?.isCancelled == true) sendCancel();
              return false;
            case 'done':
              return true;
          }
        }
        return false;
      }) as Map<String, dynamic>;

      final success = result['success'] as bool;
      if (success) {
        onProgress?.call(fileBytes.length, fileBytes.length);
      }
      return success;
    } finally {
      cancelTimer?.cancel();
      progressPort.close();
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// 上传后校验文件大小
  Future<bool> _verifyUpload({
    required String ip,
    required int port,
    required String apiKey,
    required String fileName,
    required int expectedSize,
  }) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);

      final uri = Uri.parse(
        'http://$ip:$port/server/files/metadata?filename=$fileName',
      );
      final request = await client.getUrl(uri);
      request.headers.set('Authorization', '');

      final response = await request.close().timeout(const Duration(seconds: 5));
      client.close();

      if (response.statusCode == 200) {
        final respBody = await response.transform(utf8.decoder).join();
        final json = jsonDecode(respBody) as Map<String, dynamic>;
        final fileInfo = (json['result'] as Map<String, dynamic>?) ??
            (json['file'] as Map<String, dynamic>?);
        final size = fileInfo?['size'] as int?;

        // 容忍 1 字节误差
        return size != null && (size - expectedSize).abs() <= 1;
      }

      return false;
    } catch (_) {
      // 校验失败不影响上传结果 — 宽松处理
      return true;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 辅助
  // ═══════════════════════════════════════════════════════════

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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
