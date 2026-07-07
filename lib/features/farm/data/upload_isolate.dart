/// HTTP 文件上传 Isolate
///
/// 将耗时的 HTTP multipart 上传移到独立 Isolate 中执行，
/// 确保主线程事件循环不受阻塞，MQTT 消息收发不受影响。
///
/// 通信协议:
///
///   Main → Isolate (通过初始 SendPort):
///     {
///       'ip': '192.168.1.100',
///       'port': 7125,
///       'fileName': 'model.3mf',
///       'fileBytes': <Uint8List>,
///       'progressPort': <SendPort>,
///     }
///
///   Isolate → Main (通过 progressPort):
///     {'type': 'progress', 'sent': 12345, 'total': 26214400}
///     {'type': 'ready_for_cancel', 'cancelPort': <SendPort>}  // 只发一次
///     {'type': 'done', 'success': true}
///
///   Main → Isolate (通过 cancelPort):
///     'cancel'

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 上传 Isolate 入口
void uploadIsolateEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  // 取消通道：Isolate 内部创建，通过 progressPort 把 SendPort 交给 Main
  final cancelReceivePort = ReceivePort();
  bool cancelled = false;
  cancelReceivePort.listen((msg) {
    if (msg == 'cancel') cancelled = true;
  });

  receivePort.listen((message) {
    if (message is! Map<String, dynamic>) return;

    final ip = message['ip'] as String;
    final port = message['port'] as int;
    final fileName = message['fileName'] as String;
    final fileBytes = message['fileBytes'] as Uint8List;
    final progressPort = message['progressPort'] as SendPort;

    // 告知 Main 取消通道的 SendPort
    progressPort.send({
      'type': 'ready_for_cancel',
      'cancelPort': cancelReceivePort.sendPort,
    });

    // 启动上传（不阻塞 receivePort，回调内独立运行）
    _runUpload(
      ip: ip,
      port: port,
      fileName: fileName,
      fileBytes: fileBytes,
      progressPort: progressPort,
      cancelled: () => cancelled,
    );
  });
}

/// 独立运行上传，完成后通过 progressPort 回报
void _runUpload({
  required String ip,
  required int port,
  required String fileName,
  required List<int> fileBytes,
  required SendPort progressPort,
  required bool Function() cancelled,
}) {
  Future(() async {
    try {
      await _doUploadInIsolate(
        ip: ip,
        port: port,
        fileName: fileName,
        fileBytes: fileBytes,
        cancelled: cancelled,
        onProgress: (sent, total) {
          progressPort.send({
            'type': 'progress',
            'sent': sent,
            'total': total,
          });
        },
      );

      if (cancelled()) {
        progressPort.send({
          'type': 'done',
          'success': false,
          'error': '上传已取消',
          'cancelled': true,
        });
      } else {
        progressPort.send({'type': 'done', 'success': true});
      }
    } catch (e) {
      progressPort.send({
        'type': 'done',
        'success': false,
        'error': e.toString(),
        'cancelled': cancelled(),
      });
    }
  });
}

/// Isolate 内部的实际上传逻辑（与主线程版本完全一致）
Future<void> _doUploadInIsolate({
  required String ip,
  required int port,
  required String fileName,
  required List<int> fileBytes,
  required bool Function() cancelled,
  required void Function(int sent, int total) onProgress,
}) async {
  const uploadChunkSize = 64 * 1024;
  const uploadTimeout = Duration(minutes: 10);

  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 10);

  try {
    final uri = Uri.parse('http://$ip:$port/server/files/upload');
    final request = await client.postUrl(uri);
    request.headers.set('Authorization', '');

    final boundary =
        '----LavaFarmUpload${DateTime.now().millisecondsSinceEpoch}';
    request.headers.set(
      'Content-Type',
      'multipart/form-data; boundary=$boundary',
    );

    final header = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="$fileName"\r\n'
      'Content-Type: application/octet-stream\r\n'
      '\r\n',
    );
    final footer = utf8.encode('\r\n--$boundary--\r\n');

    final totalBytes = header.length + fileBytes.length + footer.length;
    request.contentLength = totalBytes;

    void reportProgress(int bytesSent) {
      final capped = (bytesSent / totalBytes).clamp(0.0, 0.95) * totalBytes;
      onProgress(capped.round(), totalBytes);
    }

    // StreamController 真流式发送
    final streamCtrl = StreamController<List<int>>();
    int sent = 0;

    Future<void> produceChunks() async {
      try {
        streamCtrl.add(header);
        sent = header.length;
        reportProgress(sent);

        int offset = 0;
        while (offset < fileBytes.length) {
          if (cancelled()) {
            await streamCtrl.close();
            return;
          }
          final end = (offset + uploadChunkSize).clamp(0, fileBytes.length);
          streamCtrl.add(Uint8List.fromList(fileBytes.sublist(offset, end)));
          offset = end;
          sent = header.length + offset;
          reportProgress(sent);
          await Future.delayed(Duration.zero);
        }

        streamCtrl.add(footer);
        sent = totalBytes;
        reportProgress(sent);
        await streamCtrl.close();
      } catch (e) {
        streamCtrl.addError(e);
      }
    }

    produceChunks();

    final response = await request
        .addStream(streamCtrl.stream)
        .then((_) => request.close())
        .timeout(uploadTimeout);
    client.close();

    if (cancelled()) return;

    onProgress(totalBytes, totalBytes);

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final respBody = await response.transform(utf8.decoder).join();
    final json = jsonDecode(respBody) as Map<String, dynamic>;
    final item = json['item'] as Map<String, dynamic>?;
    final resultItem = json['result']?['item'] as Map<String, dynamic>?;
    if (item == null && resultItem == null) {
      throw Exception('上传响应格式异常');
    }
  } finally {
    client.close();
  }
}
