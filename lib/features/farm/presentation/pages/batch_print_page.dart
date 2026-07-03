/// 群控打印页面
///
/// 供用户选择多台打印机 + 3MF/GCode 文件，批量上传并发起打印。
///
/// 功能:
///   1. 选择文件（.3mf / .gcode / .zip）
///   2. 勾选目标打印机（在线可选，离线灰显）
///   3. 床板异物检测（摄像头快照 + LLM 视觉分析）
///   4. 设置打印选项（plate_id 等）
///   5. 点击"开始打印" → BatchPrintCoordinator 执行
///   6. 实时显示每台打印机的上传/打印进度
///   7. 完成后显示汇总 + 重试失败项

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/bed_inspection_provider.dart';
import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/printer_list_provider.dart';
import '../../application/services/batch_print_coordinator.dart';
import '../../data/farm_printer_state.dart';
import '../../domain/models/bed_inspection_result.dart';

/// 群控打印页面
class BatchPrintPage extends ConsumerStatefulWidget {
  /// 从仪表盘传入的预选打印机 SN 列表（可选）
  final Set<String> initialSns;

  const BatchPrintPage({super.key, this.initialSns = const {}});

  @override
  ConsumerState<BatchPrintPage> createState() => _BatchPrintPageState();
}

class _BatchPrintPageState extends ConsumerState<BatchPrintPage> {
  // ── 选择状态 ──
  final _selectedSns = <String>{};
  String? _filePath;
  String? _fileName;
  int _printPlate = 1;

  // ── 执行状态 ──
  bool _isExecuting = false;
  bool _isDone = false;
  final Map<String, BatchPrintPrinterState> _printerStates = {};
  BatchPrintProgress? _progress;
  final List<BatchPrintPrinterUpdate> _updateLog = [];

  // ── 检测状态 ──
  bool _isInspecting = false;

  BatchPrintCoordinator? _coordinator;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _selectedSns.addAll(widget.initialSns);
  }

  @override
  void dispose() {
    _disposed = true;
    _coordinator?.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printerListProvider);
    final gateway = ref.watch(farmCommandGatewayProvider);

    // 监听检测状态
    _isInspecting = ref.watch(bedInspectionLoadingProvider);
    // 触发检测结果重建
    final inspectionResults = ref.watch(bedInspectionResultsProvider);

    // 筛选可用打印机（在线 + 有 IP 才可选）
    final readyPrinters = printers
        .where((p) => p.isOnline && p.ip != '—' && p.ip != 'MQTT')
        .toList();
    // MQTT 在线但 IP 待解析（显示但不给选）
    final pendingPrinters = printers
        .where((p) => p.isOnline && !p.hasValidIp)
        .toList();
    // 离线
    final offlinePrinters = printers.where((p) => !p.isOnline).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('群控打印'),
        actions: [
          if (_isDone)
            TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('重试失败项'),
              onPressed: _hasFailures ? _retryFailed : null,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── 文件选择 ──
          _buildFileSection(),

          const Divider(height: 1),

          // ── 打印机选择 ──
          _buildPrinterSection(readyPrinters, pendingPrinters, offlinePrinters, inspectionResults),

          const Divider(height: 1),

          // ── 打印选项 ──
          _buildOptionsSection(),

          const Divider(height: 1),

          // ── 操作按钮 ──
          _buildActionButton(gateway != null, readyPrinters),

          // ── 进度显示 ──
          if (_isExecuting || _isDone) Expanded(child: _buildProgressSection()),

          // ── 完成操作栏 ──
          if (_isDone) _buildDoneBar(),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 文件选择
  // ═══════════════════════════════════════════════════════════

  Widget _buildFileSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 20),
          const SizedBox(width: 8),
          const Text('选择文件', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(
            child: _fileName != null
                ? Chip(
                    avatar: const Icon(Icons.check_circle, size: 18, color: Colors.green),
                    label: Text(_fileName!, style: const TextStyle(fontSize: 13)),
                    onDeleted: _isExecuting ? null : () => setState(() {
                      _filePath = null;
                      _fileName = null;
                    }),
                  )
                : OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('选择 3MF / GCode 文件'),
                    onPressed:
                        _isExecuting ? null : _pickFile,
                  ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 打印机选择
  // ═══════════════════════════════════════════════════════════

  Widget _buildPrinterSection(
    List<FarmPrinterState> readyPrinters,
    List<FarmPrinterState> pendingPrinters,
    List<FarmPrinterState> offlinePrinters,
    Map<String, BedInspectionResult> inspectionResults,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          Row(
            children: [
              const Icon(Icons.print_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                '选择打印机  ${_selectedSns.length}/${readyPrinters.length + pendingPrinters.length} 台在线',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              // 床板检测按钮
              _InspectButton(
                isInspecting: _isInspecting,
                onTap: _isInspecting
                    ? null
                    : () {
                        ref
                            .read(bedInspectionResultsProvider.notifier)
                            .inspectAll();
                      },
              ),
              const SizedBox(width: 4),
              if (!_isExecuting) ...[
                _QuickAction(
                  label: '全选就绪',
                  onTap: () => setState(() {
                    for (final p in readyPrinters) {
                      _selectedSns.add(p.sn);
                    }
                  }),
                ),
                const SizedBox(width: 8),
                _QuickAction(
                  label: '取消全选',
                  onTap: () => setState(() => _selectedSns.clear()),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // 就绪打印机网格
          if (readyPrinters.isEmpty && pendingPrinters.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '没有可用的在线打印机',
                  style: TextStyle(color: Colors.grey.shade500),
                ),
              ),
            )
          else
            SizedBox(
              height: 180,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: readyPrinters.length + pendingPrinters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  if (index < readyPrinters.length) {
                    final printer = readyPrinters[index];
                    final isSelected = _selectedSns.contains(printer.sn);
                    final inspectionResult = inspectionResults[printer.sn];
                    return _buildSelectablePrinterCard(printer, isSelected,
                        inspectionResult: inspectionResult);
                  } else {
                    final printer = pendingPrinters[index - readyPrinters.length];
                    final inspectionResult = inspectionResults[printer.sn];
                    return _buildPendingPrinterCard(printer,
                        inspectionResult: inspectionResult);
                  }
                },
              ),
            ),

          // 离线打印机
          if (offlinePrinters.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${offlinePrinters.length} 台离线',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ],
      ),
    );
  }

  /// IP 待解析的打印机（在线但无 IP，不可选）
  Widget _buildPendingPrinterCard(FarmPrinterState printer,
      {BedInspectionResult? inspectionResult}) {
    return SizedBox(
      width: 150,
      child: Card(
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Colors.orange.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.hourglass_empty, size: 16, color: Colors.orange.shade600),
                  const SizedBox(width: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      printer.displayName ?? printer.sn,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(printer.sn,
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('IP 解析中...',
                  style: TextStyle(fontSize: 9, color: Colors.orange.shade600)),
              const SizedBox(height: 4),
              // 检测结果（仅显示文字状态，无图因为 IP 未知）
              _buildInspectionStatusLine(inspectionResult),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectablePrinterCard(FarmPrinterState printer, bool isSelected,
      {BedInspectionResult? inspectionResult}) {
    final isOnline = printer.isOnline && printer.ip != '—';
    final frameUrl =
        'http://${printer.ip}:${printer.port}/server/files/camera/monitor.jpg';

    return GestureDetector(
      onTap: _isExecuting
          ? null
          : () => setState(() {
                if (isSelected) {
                  _selectedSns.remove(printer.sn);
                } else if (isOnline) {
                  _selectedSns.add(printer.sn);
                }
              }),
      child: SizedBox(
        width: 160,
        child: Card(
          elevation: isSelected ? 3 : 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: isSelected
                  ? Colors.blue
                  : inspectionResult?.hasForeignObjects == true
                      ? Colors.red.shade300
                      : Colors.transparent,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // 选中框
                    Icon(
                      isSelected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: isOnline ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    // 状态点
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOnline ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        printer.displayName ?? printer.sn,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isOnline ? null : Colors.grey,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  printer.sn,
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${printer.ip}:${printer.port}',
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                // 摄像头快照
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: double.infinity,
                    height: 80,
                    child: _isInspecting && inspectionResult == null
                        ? Container(
                            color: Colors.grey.shade100,
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.blue.shade300),
                              ),
                            ),
                          )
                        : Image.network(
                            frameUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.shade100,
                              child: Icon(Icons.videocam_off,
                                  size: 20, color: Colors.grey.shade300),
                            ),
                            loadingBuilder: (_, child, progress) {
                              if (progress == null) return child;
                              return Container(
                                color: Colors.grey.shade100,
                                child: Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.grey.shade300),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                // 检测结果
                _buildInspectionStatusLine(inspectionResult),
                const Spacer(),
                // 执行状态指示
                if (_isExecuting || _isDone)
                  _buildPrinterStateIcon(printer.sn),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrinterStateIcon(String sn) {
    final state = _printerStates[sn];
    if (state == null) return const SizedBox.shrink();

    IconData icon;
    Color color;
    String label;

    switch (state) {
      case BatchPrintPrinterState.uploading:
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        );
      case BatchPrintPrinterState.uploadDone:
        icon = Icons.cloud_done_outlined;
        color = Colors.blue;
        label = '上传完成';
      case BatchPrintPrinterState.startingPrint:
        icon = Icons.play_circle_outline;
        color = Colors.orange;
        label = '启动中';
      case BatchPrintPrinterState.success:
        icon = Icons.check_circle;
        color = Colors.green;
        label = '成功';
      case BatchPrintPrinterState.uploadFailed:
        icon = Icons.error_outline;
        color = Colors.red;
        label = '上传失败';
      case BatchPrintPrinterState.printFailed:
        icon = Icons.warning_amber;
        color = Colors.orange;
        label = '打印失败';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 9, color: color)),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 打印选项
  // ═══════════════════════════════════════════════════════════

  Widget _buildOptionsSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 20),
          const SizedBox(width: 8),
          const Text('打印选项', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 24),
          const Text('Plate ID:'),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: TextField(
              controller: TextEditingController(text: '$_printPlate'),
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              enabled: !_isExecuting,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0) _printPlate = n;
              },
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '(3MF 多盘文件选择打印盘)',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 操作按钮
  // ═══════════════════════════════════════════════════════════

  Widget _buildActionButton(bool mqttAvailable, List<FarmPrinterState> online) {
    final canStart = !_isExecuting &&
        _filePath != null &&
        _selectedSns.isNotEmpty &&
        mqttAvailable;

    String buttonText;
    if (_isExecuting) {
      buttonText = '执行中...';
    } else if (_isDone) {
      buttonText = '已完成';
    } else {
      buttonText = '开始打印 (${_selectedSns.length} 台)';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: ElevatedButton.icon(
          icon: _isExecuting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.print),
          label: Text(buttonText, style: const TextStyle(fontSize: 15)),
          onPressed: canStart ? _startPrint : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: _isDone
                ? Colors.green
                : _isExecuting
                    ? Colors.grey
                    : Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 进度显示
  // ═══════════════════════════════════════════════════════════

  Widget _buildProgressSection() {
    final progress = _progress;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              const Icon(Icons.sync, size: 20),
              const SizedBox(width: 8),
              Text(
                _isDone ? '执行完成' : '执行进度',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (_isDone)
                Icon(
                  progress?.hasFailures == true
                      ? Icons.warning_amber
                      : Icons.check_circle,
                  color:
                      progress?.hasFailures == true ? Colors.orange : Colors.green,
                  size: 20,
                ),
            ],
          ),

          const SizedBox(height: 12),

          // 进度条
          if (progress != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.isDone ? 1.0 : progress.progress,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
              ),
            ),
            const SizedBox(height: 8),

            // 统计
            Row(
              children: [
                _Stat(label: '上传中', count: progress.uploadingCount, color: Colors.blue),
                const SizedBox(width: 12),
                _Stat(label: '启动中', count: progress.startingPrintCount, color: Colors.orange),
                const SizedBox(width: 12),
                _Stat(label: '成功', count: progress.successCount, color: Colors.green),
                const SizedBox(width: 12),
                _Stat(label: '失败', count: progress.failedCount, color: Colors.red),
                const Spacer(),
                Text(
                  '${progress.completedCount}/${progress.totalPrinters}',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],

          const SizedBox(height: 12),

          // 详细日志
          Expanded(
            child: ListView.separated(
              itemCount: _updateLog.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final update = _updateLog[_updateLog.length - 1 - index]; // 最新在上
                return _buildLogEntry(update);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogEntry(BatchPrintPrinterUpdate update) {
    IconData icon;
    Color color;

    switch (update.state) {
      case BatchPrintPrinterState.uploading:
        icon = Icons.cloud_upload_outlined;
        color = Colors.blue;
      case BatchPrintPrinterState.uploadDone:
        icon = Icons.cloud_done_outlined;
        color = Colors.blue;
      case BatchPrintPrinterState.startingPrint:
        icon = Icons.play_circle_outline;
        color = Colors.orange;
      case BatchPrintPrinterState.success:
        icon = Icons.check_circle;
        color = Colors.green;
      case BatchPrintPrinterState.uploadFailed:
        icon = Icons.error_outline;
        color = Colors.red;
      case BatchPrintPrinterState.printFailed:
        icon = Icons.warning_amber;
        color = Colors.orange;
    }

    final stateLabel = switch (update.state) {
      BatchPrintPrinterState.uploading => '上传中',
      BatchPrintPrinterState.uploadDone => '上传完成',
      BatchPrintPrinterState.startingPrint => '启动打印',
      BatchPrintPrinterState.success => '打印已启动',
      BatchPrintPrinterState.uploadFailed => '上传失败',
      BatchPrintPrinterState.printFailed => '打印启动失败',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              update.sn,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          Text(
            stateLabel,
            style: TextStyle(fontSize: 12, color: color),
          ),
          if (update.error != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                update.error!,
                style: TextStyle(fontSize: 11, color: Colors.red.shade400),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          if (update.elapsed != null) ...[
            const SizedBox(width: 8),
            Text(
              '${update.elapsed!.inSeconds}s',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 完成操作栏
  // ═══════════════════════════════════════════════════════════

  Widget _buildDoneBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (_hasFailures)
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试失败项'),
                onPressed: _retryFailed,
              ),
            ),
          if (_hasFailures) const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回仪表盘'),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 操作逻辑
  // ═══════════════════════════════════════════════════════════

  Future<void> _pickFile() async {
    try {
      const typeGroup = XTypeGroup(
        label: '3D 打印文件',
        extensions: ['gcode', '3mf', 'zip', 'g', 'gco'],
      );
      final xfile = await openFile(acceptedTypeGroups: [typeGroup]);
      if (xfile == null) return;

      if (!_disposed) {
        setState(() {
          _filePath = xfile.path;
          _fileName = xfile.name;
        });
      }
    } catch (e) {
      if (_disposed || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择文件失败: $e')),
      );
    }
  }

  Future<void> _startPrint() async {
    if (_filePath == null || _selectedSns.isEmpty) return;

    // 构建连接信息
    final store = ref.read(farmStoreProvider);
    final connectionInfo = <String, (String ip, int port, String apiKey)>{};

    final validSns = <String>[];
    for (final sn in _selectedSns) {
      final printer = store.getPrinter(sn);
      if (printer == null) continue;
      if (!printer.hasValidIp || !printer.isOnline) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${printer.displayName ?? sn} 不可用（离线或 IP 未知）'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        continue;
      }
      connectionInfo[sn] = (printer.ip, printer.port, ''); // apiKey 暂空
      validSns.add(sn);
    }

    if (validSns.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可用的打印机')),
        );
      }
      return;
    }

    // 创建协调器并监听
    final gateway = ref.read(farmCommandGatewayProvider);
    if (gateway == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MQTT 未连接，无法启动打印')),
        );
      }
      return;
    }

    setState(() {
      _isExecuting = true;
      _isDone = false;
      _printerStates.clear();
      _progress = null;
      _updateLog.clear();
    });

    _coordinator = BatchPrintCoordinator(gateway: gateway);

    // 订阅流
    _coordinator!.printerUpdateStream.listen((update) {
      if (_disposed || !mounted) return;
      setState(() {
        _printerStates[update.sn] = update.state;
        _updateLog.add(update);
      });
    });

    _coordinator!.progressStream.listen((progress) {
      if (_disposed || !mounted) return;
      setState(() {
        _progress = progress;
        if (progress.isDone) {
          _isExecuting = false;
          _isDone = true;
        }
      });
    });

    await _coordinator!.execute(
      printerSns: validSns,
      connectionInfo: connectionInfo,
      localFilePath: _filePath!,
      remoteFileName: _fileName!,
      printPlate: _printPlate,
    );
  }

  Future<void> _retryFailed() async {
    if (_coordinator == null) return;

    setState(() {
      _isExecuting = true;
      _isDone = false;
      _progress = null;
    });

    await _coordinator!.retryFailed(printPlate: _printPlate);
  }

  bool get _hasFailures {
    return _printerStates.values.any(
      (s) =>
          s == BatchPrintPrinterState.uploadFailed ||
          s == BatchPrintPrinterState.printFailed,
    );
  }
}

/// 床板检测按钮
class _InspectButton extends StatelessWidget {
  final bool isInspecting;
  final VoidCallback? onTap;

  const _InspectButton({required this.isInspecting, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isInspecting)
              const SizedBox(
                width: 14,
                height: 14,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
              )
            else
              Icon(Icons.search, size: 14, color: Colors.blue.shade700),
            const SizedBox(width: 2),
            Text(
              isInspecting ? '检测中' : '床板检测',
              style: TextStyle(
                fontSize: 11,
                color: onTap == null ? Colors.grey : Colors.blue.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 检测状态行（紧凑，用于卡片内嵌）
Widget _buildInspectionStatusLine(BedInspectionResult? result) {
  if (result == null) {
    return Text('待检测',
        style: TextStyle(fontSize: 9, color: Colors.grey.shade400));
  }

  if (result.hasForeignObjects) {
    return Row(
      children: [
        const Icon(Icons.warning_amber_rounded, size: 12, color: Colors.red),
        const SizedBox(width: 2),
        Expanded(
          child: Tooltip(
            message: result.bedForeignObjects.description,
            child: Text(
              result.bedForeignObjects.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: Colors.red.shade700, height: 1.3),
            ),
          ),
        ),
      ],
    );
  }

  if (result.isReadyToPrint) {
    return Row(
      children: [
        Icon(Icons.check_circle, size: 12, color: Colors.green.shade600),
        const SizedBox(width: 2),
        Text(
          result.printReadiness.caution ? '可打印（注意）' : '床板干净',
          style: TextStyle(fontSize: 9, color: Colors.green.shade700),
        ),
      ],
    );
  }

  return Row(
    children: [
      Icon(Icons.info_outline, size: 12, color: Colors.orange.shade600),
      const SizedBox(width: 2),
      Expanded(
        child: Tooltip(
          message: result.printReadiness.reason,
          child: Text(
            result.printReadiness.reason,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9, color: Colors.orange.shade700),
          ),
        ),
      ),
    ],
  );
}

/// 快速操作按钮
class _QuickAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
        ),
      ),
    );
  }
}

/// 统计数字
class _Stat extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _Stat({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 4),
        Text('$label ', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Text('$count', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }
}
