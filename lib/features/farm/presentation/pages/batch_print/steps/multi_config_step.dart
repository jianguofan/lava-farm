import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/providers/batch_print_provider.dart';
import '../../../../application/providers/print_head_provider.dart';
import '../../../../application/providers/printer_list_provider.dart';
import '../../../../data/farm_printer_state.dart';
import '../../../../domain/models/print_head.dart';
import '../../../../domain/models/product_material.dart';
import '../widgets/head_picker_dialog.dart';
import '../widgets/material_slot_card.dart';

/// 多盘配置步（多盘同打模式专用）。
///
/// 每个 enabled 盘一张卡：同一行内既选该盘要用的打印机，又配置该盘耗材→打印头。
/// 打印机各盘互斥——被其它盘占用的置灰并标注「盘X」，点击可重新指派（MOVE 语义）。
class MultiConfigStep extends ConsumerWidget {
  final BatchPrintArgs args;

  const MultiConfigStep({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batchPrintProvider(args));
    final notifier = ref.read(batchPrintProvider(args).notifier);
    final heads = ref.watch(printHeadListProvider);
    final printers = ref.watch(printerListProvider);

    final readyPrinters = printers
        .where((p) => p.isOnline && p.ip != '—' && p.ip != 'MQTT')
        .toList();

    // sn → 所属盘号（互斥展示用）
    final ownerOf = <String, int>{};
    for (final a in state.assignments) {
      for (final sn in a.printerSns) {
        ownerOf[sn] = a.plateId;
      }
    }

    Color? headColorFor(ProductMaterial m) {
      final h = heads.where((e) => e.index == m.assignedHead).firstOrNull;
      return h == null ? null : Color(h.argb);
    }

    final locked = state.isExecuting || state.isDone;

    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.dynamic_feed, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '多盘同打 · ${state.assignments.length} 盘',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: locked ? null : notifier.autoMatchAll,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('全部自动匹配'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '为每盘选择打印机并配置耗材打印头；打印机各盘互斥，可点击已分配项重新指派。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 12),
            for (final a in state.assignments)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _PlateCard(
                  assignment: a,
                  thumb: _thumbFor(state, a.plateId),
                  readyPrinters: readyPrinters,
                  ownerOf: ownerOf,
                  heads: heads,
                  headColorFor: headColorFor,
                  locked: locked,
                  onTogglePrinter: (sn) =>
                      notifier.togglePlatePrinter(a.plateId, sn),
                  onToggleEnabled: () =>
                      notifier.togglePlateEnabled(a.plateId),
                  onAutoMatch: () => notifier.autoMatchPlate(a.plateId),
                  onPickHead: (matIdx, material) {
                    final plateId = a.plateId; // 捕获当前盘ID，避免闭包陷阱
                    showHeadPickerDialog(
                      context,
                      material: material,
                      heads: heads,
                      assigned: material.assignedHead,
                      onSelect: (head) {
                        if (head == null) {
                          notifier.clearPlateHead(plateId, matIdx);
                        } else {
                          notifier.assignPlateHead(plateId, matIdx, head);
                        }
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 取某盘预览缩略图字节（partition.pics[0] → previewImages）。
  Uint8List? _thumbFor(BatchPrintState state, int plateId) {
    final pic = state.parsed3mf?.profiles.firstOrNull?.partitions
        .where((p) => p.id == plateId)
        .firstOrNull
        ?.pics
        .firstOrNull;
    if (pic == null) return null;
    return state.previewImages[pic];
  }
}

/// 单盘配置卡。
class _PlateCard extends StatelessWidget {
  final PlateAssignment assignment;
  final Uint8List? thumb;
  final List<FarmPrinterState> readyPrinters;
  final Map<String, int> ownerOf; // sn → 占用盘号
  final List<PrintHead> heads;
  final Color? Function(ProductMaterial) headColorFor;
  final bool locked;
  final ValueChanged<String> onTogglePrinter;
  final VoidCallback onToggleEnabled;
  final VoidCallback onAutoMatch;
  final void Function(int matIdx, ProductMaterial material) onPickHead;

  const _PlateCard({
    required this.assignment,
    required this.thumb,
    required this.readyPrinters,
    required this.ownerOf,
    required this.heads,
    required this.headColorFor,
    required this.locked,
    required this.onTogglePrinter,
    required this.onToggleEnabled,
    required this.onAutoMatch,
    required this.onPickHead,
  });

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    final disabled = !a.enabled;
    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: disabled ? Colors.grey.shade300 : const Color(0xFFEFEFEF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头：预览 + 盘号/名 + 自动匹配 + 启停
            Row(
              children: [
                if (thumb != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(thumb!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _thumbPlaceholder()),
                  )
                else
                  _thumbPlaceholder(),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('盘 ${a.plateId} · ${a.name}',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(
                          '${a.printerSns.length} 台打印机 · ${a.materials.length} 种耗材',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500)),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: disabled || locked ? null : onAutoMatch,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('自动匹配'),
                ),
                IconButton(
                  tooltip: disabled ? '启用此盘' : '禁用此盘',
                  icon: Icon(
                    disabled
                        ? Icons.check_circle_outline
                        : Icons.remove_circle_outline,
                    size: 20,
                    color: disabled ? Colors.grey : Colors.orange.shade400,
                  ),
                  onPressed: locked ? null : onToggleEnabled,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('打印机',
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in readyPrinters)
                  _PrinterChip(
                    printer: p,
                    selected: a.printerSns.contains(p.sn),
                    ownerPlate: ownerOf[p.sn],
                    disabled: disabled || locked,
                    onTap: () => onTogglePrinter(p.sn),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('耗材 → 打印头',
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (a.materials.isEmpty)
              Text('该盘无耗材信息',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < a.materials.length; i++)
                    MaterialSlotCard(
                      material: a.materials[i],
                      index: i,
                      headColor: headColorFor(a.materials[i]),
                      onTap: (disabled || locked)
                          ? null
                          : () => onPickHead(i, a.materials[i]),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _thumbPlaceholder() => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(Icons.view_in_ar, size: 18, color: Colors.grey.shade400),
      );
}

/// 打印机选择 chip：选中（本盘）/ 占用于他盘（灰，可点击改派）/ 空闲。
class _PrinterChip extends StatelessWidget {
  final FarmPrinterState printer;
  final bool selected;
  final int? ownerPlate; // 被哪个盘占用；null=空闲
  final bool disabled;
  final VoidCallback onTap;

  const _PrinterChip({
    required this.printer,
    required this.selected,
    required this.ownerPlate,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final takenElsewhere = ownerPlate != null && !selected;
    final Color bg;
    final Color fg;
    if (selected) {
      bg = const Color(0xFF0C63E2);
      fg = Colors.white;
    } else if (takenElsewhere) {
      bg = Colors.grey.shade100;
      fg = Colors.grey.shade500;
    } else {
      bg = Colors.white;
      fg = const Color(0xFF242424);
    }
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? const Color(0xFF0C63E2)
                : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.check_circle
                  : takenElsewhere
                      ? Icons.swap_horiz
                      : Icons.radio_button_unchecked,
              size: 14,
              color: fg,
            ),
            const SizedBox(width: 4),
            Text(printer.displayLabel,
                style: TextStyle(
                    fontSize: 12,
                    color: fg,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400)),
            if (takenElsewhere) ...[
              const SizedBox(width: 4),
              Text('盘$ownerPlate', style: TextStyle(fontSize: 10, color: fg)),
            ],
          ],
        ),
      ),
    );
  }
}
