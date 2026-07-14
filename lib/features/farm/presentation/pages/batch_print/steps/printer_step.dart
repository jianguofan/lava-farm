import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/providers/batch_print_provider.dart';
import '../../../../application/providers/bed_inspection_provider.dart';
import '../../../../application/providers/printer_list_provider.dart';
import '../../../../data/farm_printer_state.dart';
import '../../../../domain/models/bed_inspection_result.dart';
import '../widgets/inspect_button.dart';
import '../widgets/pending_printer_card.dart';
import '../widgets/quick_action.dart';
import '../widgets/selectable_printer_card.dart';

/// Step3：选择打印机 + 床板检测。
///
/// 打印盘号已在 Step1 选择（写入 [BatchPrintState.printPlate]，
/// 经 selectPlate 设定并用于实际下发打印），此处不再重复配置。
class PrinterStep extends ConsumerWidget {
  final BatchPrintArgs args;

  const PrinterStep({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batchPrintProvider(args));
    final notifier = ref.read(batchPrintProvider(args).notifier);

    final printers = ref.watch(printerListProvider);
    final isInspecting = ref.watch(bedInspectionLoadingProvider);
    final inspectionResults = ref.watch(bedInspectionResultsMapProvider);
    final inspectionImages = ref.watch(bedInspectionImagesProvider);

    final readyPrinters = printers
        .where((p) => p.isOnline && p.ip != '—' && p.ip != 'MQTT')
        .toList();
    final pendingPrinters =
        printers.where((p) => p.isOnline && !p.hasValidIp).toList();
    final offlinePrinters = printers.where((p) => !p.isOnline).toList();

    final selectedSns = state.selectedSns;
    final isExecuting = state.isExecuting;

    return Column(
      children: [
        _buildPrinterSection(
          ref,
          readyPrinters: readyPrinters,
          pendingPrinters: pendingPrinters,
          offlinePrinters: offlinePrinters,
          inspectionResults: inspectionResults,
          inspectionImages: inspectionImages,
          isInspecting: isInspecting,
          selectedSns: selectedSns,
          state: state,
          notifier: notifier,
          isExecuting: isExecuting,
        ),
      ],
    );
  }

  Widget _buildPrinterSection(
    WidgetRef ref, {
    required List<FarmPrinterState> readyPrinters,
    required List<FarmPrinterState> pendingPrinters,
    required List<FarmPrinterState> offlinePrinters,
    required Map<String, BedInspectionResult> inspectionResults,
    required Map<String, Uint8List> inspectionImages,
    required bool isInspecting,
    required Set<String> selectedSns,
    required BatchPrintState state,
    required BatchPrintNotifier notifier,
    required bool isExecuting,
  }) {
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
                '选择打印机  ${selectedSns.length}/${readyPrinters.length + pendingPrinters.length} 台在线',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              InspectButton(
                isInspecting: isInspecting,
                onTap: isInspecting
                    ? null
                    : () => ref
                        .read(bedInspectionResultsProvider.notifier)
                        .inspectAll(),
              ),
              const SizedBox(width: 4),
              if (!isExecuting) ...[
                QuickAction(
                  label: '全选就绪',
                  onTap: () => notifier.selectAllReady(readyPrinters),
                ),
                const SizedBox(width: 8),
                QuickAction(
                  label: '取消全选',
                  onTap: notifier.clearSelection,
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
                    final isSelected = selectedSns.contains(printer.sn);
                    return SelectablePrinterCard(
                      printer: printer,
                      isSelected: isSelected,
                      isLocked: isExecuting || state.isDone,
                      isInspecting: isInspecting,
                      inspectionResult: inspectionResults[printer.sn],
                      imageBytes: inspectionImages[printer.sn],
                      printerState: state.printerStates[printer.sn],
                      onToggle: () {
                        final isOnline = printer.isOnline && printer.ip != '—';
                        if (isSelected || isOnline)
                          notifier.togglePrinter(printer.sn);
                      },
                    );
                  } else {
                    final printer =
                        pendingPrinters[index - readyPrinters.length];
                    return PendingPrinterCard(
                      printer: printer,
                      inspectionResult: inspectionResults[printer.sn],
                    );
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
}
