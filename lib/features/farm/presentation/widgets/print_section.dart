/// 单机打印流程：选文件 → HTTP 上传 → MQTT server.files.start_local_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';

enum PrintState { idle, picking, uploading, starting, done, error }

/// 单机上传 + 打印 Widget
class PrintSection extends ConsumerStatefulWidget {
  final String sn;
  final String ip;
  final int port;

  const PrintSection({super.key, required this.sn, required this.ip, required this.port});

  @override
  ConsumerState<PrintSection> createState() => _PrintSectionState();
}

class _PrintSectionState extends ConsumerState<PrintSection> {
  PrintState _state = PrintState.idle;
  String? _fileName;
  String? _error;
  double _uploadProgress = 0;

  Future<void> _pickFileAndPrint() async {
    // 1. 选择文件
    setState(() => _state = PrintState.picking);
    const typeGroup = XTypeGroup(
      label: '3D 打印文件',
      extensions: ['gcode', '3mf', 'zip', 'g', 'gco'],
    );
    final xfile = await openFile(acceptedTypeGroups: [typeGroup]);
    if (xfile == null) {
      if (mounted) setState(() => _state = PrintState.idle);
      return;
    }

    final fileName = xfile.name;

    setState(() { _fileName = fileName; _state = PrintState.uploading; });

    try {
      // 2. HTTP 上传文件
      final fileBytes = await xfile.readAsBytes();
      final uploadOk = await _uploadFile(fileName, fileBytes);
      if (!uploadOk) {
        if (mounted) setState(() { _state = PrintState.error; _error = '文件上传失败'; });
        return;
      }

      // 3. MQTT server.files.start_local_print
      setState(() => _state = PrintState.starting);
      final router = ref.read(farmMqttRouterProvider);
      if (router == null) {
        if (mounted) setState(() { _state = PrintState.error; _error = 'MQTT 未连接'; });
        return;
      }

      final result = await router.sendCommand(
        widget.sn,
        'server.files.start_local_print',
        {
          'type': _fileType(fileName),
          'path': fileName,
          'print_plate': 1,
        },
      );

      if (mounted) {
        setState(() => result.success
            ? _state = PrintState.done
            : (_state = PrintState.error, _error = result.error ?? '打印启动失败'));
      }
    } catch (e) {
      if (mounted) setState(() { _state = PrintState.error; _error = e.toString(); });
    }
  }

  Future<bool> _uploadFile(String fileName, List<int> fileBytes) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final uri = Uri.parse('http://${widget.ip}:${widget.port}/server/files/upload');
      final request = await client.postUrl(uri);

      final boundary = '----LavaFarmUpload${DateTime.now().millisecondsSinceEpoch}';
      request.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
      // Moonraker 要求即使为空也要带 Authorization header
      request.headers.set('Authorization', '');

      // 构建 multipart body
      final body = BytesBuilder();
      body.add(utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$fileName"\r\n'
        'Content-Type: application/octet-stream\r\n'
        '\r\n',
      ));
      body.add(fileBytes);
      body.add(utf8.encode('\r\n--$boundary--\r\n'));

      final bodyBytes = body.toBytes();
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      // 进度模拟：按文件大小估算（实际网络写入由 OS 处理）
      if (mounted) setState(() => _uploadProgress = 0.5);

      final response = await request.close().timeout(const Duration(minutes: 10));
      client.close();

      if (mounted) setState(() => _uploadProgress = 1.0);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final respBody = await response.transform(utf8.decoder).join();
        final json = jsonDecode(respBody) as Map<String, dynamic>;
        // Moonraker 响应: {"action":"create_file","item":{...}}  或  {"result":{"item":{...}}}
        final item = json['item'] as Map<String, dynamic>?;
        final resultItem = json['result']?['item'] as Map<String, dynamic>?;
        debugPrint('[PrintSection] 上传响应: ${respBody.length > 200 ? respBody.substring(0, 200) : respBody}');
        return item != null || resultItem != null;
      }

      debugPrint('[PrintSection] 上传失败 HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      client.close();
      debugPrint('[PrintSection] 上传异常: $e');
      return false;
    }
  }

  String _fileType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.3mf')) return '3mf';
    if (lower.endsWith('.zip')) return 'zip';
    return 'gcode';
  }

  final _quickFileController = TextEditingController(text: '1781578138875-dca71561.3mf');

  void _reset() => setState(() { _state = PrintState.idle; _error = null; _fileName = null; });

  Future<void> _quickPrint() async {
    final fileName = _quickFileController.text.trim();
    if (fileName.isEmpty) return;

    setState(() { _fileName = fileName; _state = PrintState.starting; });

    final router = ref.read(farmMqttRouterProvider);
    if (router == null) {
      if (mounted) setState(() { _state = PrintState.error; _error = 'MQTT 未连接'; });
      return;
    }

    final result = await router.sendCommand(
      widget.sn,
      'server.files.start_local_print',
      {
        'type': _fileType(fileName),
        'path': fileName,
        'print_plate': 1,
      },
    );

    if (mounted) {
      setState(() => result.success
          ? _state = PrintState.done
          : (_state = PrintState.error, _error = result.error ?? '打印启动失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.print, size: 16, color: Color(0xFF0C63E2)),
                const SizedBox(width: 6),
                const Text('上传并打印',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_state == PrintState.done)
                  TextButton(onPressed: _reset, child: const Text('再次打印', style: TextStyle(fontSize: 12))),
              ],
            ),
            const Divider(),

            switch (_state) {
              PrintState.idle => SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _pickFileAndPrint,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('选择文件并打印'),
                ),
              ),
              PrintState.picking => const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
              PrintState.uploading => Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Expanded(child: Text('上传中: $_fileName', style: const TextStyle(fontSize: 12))),
                      Text('${(_uploadProgress * 100).toInt()}%',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _uploadProgress),
                ],
              ),
              PrintState.starting => Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('正在启动打印: $_fileName', style: const TextStyle(fontSize: 12)),
                ],
              ),
              PrintState.done => Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('✅ 打印已启动: $_fileName',
                    style: TextStyle(color: Colors.green.shade700, fontSize: 13)),
              ),
              PrintState.error => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('❌ $_error',
                        style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(onPressed: _pickFileAndPrint, child: const Text('重试')),
                ],
              ),
            },

            // 快速打印已有文件
            if (_state == PrintState.idle) ...[
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _quickFileController,
                        decoration: const InputDecoration(
                          hintText: '已有文件名（跳过上传）',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _quickPrint,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('直接打印', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
