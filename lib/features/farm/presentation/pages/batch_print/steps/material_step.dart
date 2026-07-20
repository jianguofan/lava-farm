import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/providers/batch_print_provider.dart';
import '../../../../application/providers/print_head_provider.dart';
import '../../../../domain/models/product_material.dart';
import '../widgets/head_picker_dialog.dart';
import '../widgets/material_slot_card.dart';

/// Step2：耗材 → 打印头分配。
///
/// 耗材（来自 3mf 选中盘的 filaments，颜色/类型/克重只读）通过点击卡片选择
/// 装入哪个打印头（1–4）。进入时自动按 CIEDE2000 色距匹配，可手动覆盖或重新匹配。
/// 打印头预设（颜色/类型/喷嘴）在「打印头设置」页维护（全局一套）。
class MaterialStep extends ConsumerWidget {
  final BatchPrintArgs args;

  const MaterialStep({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batchPrintProvider(args));
    final notifier = ref.read(batchPrintProvider(args).notifier);
    final materials = state.materials;
    final heads = ref.watch(printHeadListProvider);
    final selectedPlate = state.parsed3mf?.profiles.firstOrNull?.partitions
        .where((p) => p.id == state.printPlate)
        .firstOrNull;

    Color? headColorFor(ProductMaterial m) {
      final h = heads.where((e) => e.index == m.assignedHead).firstOrNull;
      return h == null ? null : Color(h.argb);
    }

    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── 配置耗材 卡片 ──
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFEFEFEF)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '配置耗材',
                              style: TextStyle(
                                color: Color(0xFF242424),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (materials.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text(
                                '共 ${materials.length} 种',
                                style: const TextStyle(
                                    color: Color(0xFF8E8E8E), fontSize: 12),
                              ),
                            ],
                            const Spacer(),
                            TextButton.icon(
                              onPressed: notifier.autoMatch,
                              icon: const Icon(Icons.auto_awesome, size: 16),
                              label: const Text('自动匹配'),
                            ),
                            IconButton(
                              tooltip: '打印头设置',
                              icon: const Icon(Icons.tune, size: 18),
                              onPressed: () => Navigator.pushNamed(
                                  context, '/print-head-settings'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (selectedPlate != null)
                          Text(
                            '盘 ${selectedPlate.id} · ${selectedPlate.name}（点击卡片选择打印头）',
                            style: const TextStyle(
                                color: Color(0xFF8E8E8E), fontSize: 12),
                          ),
                        const SizedBox(height: 16),
                        if (materials.isEmpty)
                          _EmptyAdd(onAdded: notifier.addMaterial)
                        else
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (var i = 0; i < materials.length; i++)
                                MaterialSlotCard(
                                  material: materials[i],
                                  index: i,
                                  headColor: headColorFor(materials[i]),
                                  onTap: () => showHeadPickerDialog(
                                    context,
                                    material: materials[i],
                                    heads: heads,
                                    assigned: materials[i].assignedHead,
                                    onSelect: (head) {
                                      if (head == null) {
                                        notifier.clearHead(i);
                                      } else {
                                        notifier.assignHead(i, head);
                                      }
                                    },
                                  ),
                                ),
                              // _AddSlotCard(onTap: notifier.addMaterial),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      '耗材颜色/克重来自切片文件（只读）；点击卡片选择装入的打印头。'
                      '克重为 0 以「!」标记；未分配以「?」标记。',
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打印头选择弹窗见 [showHeadPickerDialog]（已抽到 widgets/）。
}

/// 添加耗材槽位（虚框 + 号）。
class _AddSlotCard extends StatelessWidget {
  final VoidCallback onTap;
  const _AddSlotCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: MaterialSlotCard.width,
        height: MaterialSlotCard.height,
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFD9D9D9)),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, color: Color(0xFF8E8E8E), size: 28),
            SizedBox(height: 6),
            Text('添加耗材',
                style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// 空状态：未检测到耗材信息 + 添加按钮。
class _EmptyAdd extends StatelessWidget {
  final VoidCallback onAdded;
  const _EmptyAdd({required this.onAdded});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_outlined,
                size: 40, color: Colors.grey.shade300),
            const SizedBox(height: 8),
            const Text('未检测到耗材信息', style: TextStyle(color: Color(0xFF8E8E8E))),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加耗材'),
              onPressed: onAdded,
            ),
          ],
        ),
      ),
    );
  }
}
