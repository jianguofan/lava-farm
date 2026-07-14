import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/providers/bed_inspection_provider.dart';
import '../../../../application/services/batch_print_coordinator.dart';
import '../../../../data/farm_printer_state.dart';
import '../../../../domain/models/bed_inspection_result.dart';
import 'inspection_status_line.dart';

/// 可选打印机卡片（含摄像头快照 + 执行状态图标）。
class SelectablePrinterCard extends ConsumerWidget {
  final FarmPrinterState printer;
  final bool isSelected;
  final bool isLocked; // isExecuting || isDone → 禁用点击
  final BedInspectionResult? inspectionResult;
  final BatchPrintPrinterState? printerState;
  final VoidCallback? onToggle;

  /// 床板检测时抓取并记录的图片（按 SN）。非空时优先显示这张静态图，
  /// 否则回退到实时拉流或检测中转圈。
  final Uint8List? imageBytes;

  const SelectablePrinterCard({
    super.key,
    required this.printer,
    required this.isSelected,
    required this.isLocked,
    required this.inspectionResult,
    required this.printerState,
    required this.onToggle,
    this.imageBytes,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 逐台检测态：仅本卡片的 inspecting 翻转时重建，不波及其余卡片
    final isInspecting = ref.watch(bedInspectionInspectingProvider(printer.sn));
    final isOnline = printer.isOnline && printer.ip != '—';
    final frameUrl =
        'http://${printer.ip}:${printer.port}/server/files/camera/monitor.jpg';

    return GestureDetector(
      onTap: isLocked ? null : onToggle,
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
                    Icon(
                      isSelected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: isOnline ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 4),
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
                        printer.displayLabel,
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
                const SizedBox(height: 2),
                Text(
                  '${printer.ip}:${printer.port}',
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // 摄像头快照：优先显示检测时记录的静态图，其次检测中转圈，最后实时拉流兜底
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: double.infinity,
                    height: 64,
                    child: imageBytes != null
                        ? Image.memory(
                            imageBytes!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.shade100,
                              child: Icon(Icons.broken_image,
                                  size: 20, color: Colors.grey.shade300),
                            ),
                          )
                        : isInspecting && inspectionResult == null
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
                InspectionStatusLine(result: inspectionResult),
                const Spacer(),
                // 执行状态指示
                if (isLocked) _PrinterStateIcon(state: printerState),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单台打印机执行状态图标（卡片内嵌）。
class _PrinterStateIcon extends StatelessWidget {
  final BatchPrintPrinterState? state;

  const _PrinterStateIcon({required this.state});

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case null:
      case BatchPrintPrinterState.queued:
        return Icon(Icons.hourglass_empty,
            size: 14, color: Colors.grey.shade400);
      case BatchPrintPrinterState.uploading:
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        );
      case BatchPrintPrinterState.uploadDone:
        return const _StateLabel(
          icon: Icons.cloud_done_outlined,
          color: Colors.blue,
          label: '上传完成',
        );
      case BatchPrintPrinterState.startingPrint:
        return const _StateLabel(
          icon: Icons.play_circle_outline,
          color: Colors.orange,
          label: '启动中',
        );
      case BatchPrintPrinterState.success:
        return const _StateLabel(
          icon: Icons.check_circle,
          color: Colors.green,
          label: '成功',
        );
      case BatchPrintPrinterState.uploadFailed:
        return const _StateLabel(
          icon: Icons.error_outline,
          color: Colors.red,
          label: '上传失败',
        );
      case BatchPrintPrinterState.printFailed:
        return const _StateLabel(
          icon: Icons.warning_amber,
          color: Colors.orange,
          label: '打印失败',
        );
    }
  }
}

class _StateLabel extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;

  const _StateLabel(
      {required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 9, color: color)),
      ],
    );
  }
}
