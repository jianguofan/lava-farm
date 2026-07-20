import 'package:flutter/material.dart';

import '../../../../domain/models/print_head.dart';
import '../../../../domain/models/product_material.dart';
import '../../../../domain/services/filament_matcher.dart';

/// 弹出打印头选择对话框：列出各头（预设色 + 类型 + 喷嘴 + 与本耗材色距 ΔE），
/// 标注自动推荐头。`onSelect(null)` 表示清除分配。
///
/// 推荐头由 [findMatchingExtruder] 计算，调用方无需重复算。
Future<void> showHeadPickerDialog(
  BuildContext context, {
  required ProductMaterial material,
  required List<PrintHead> heads,
  required int? assigned,
  required ValueChanged<int?> onSelect,
}) {
  final materialColor = Color(material.argb);
  final recommended = findMatchingExtruder(
    type: material.colorName,
    color: materialColor,
    heads: heads,
  );
  return showDialog<void>(
    context: context,
    builder: (_) => HeadPickerDialog(
      material: material,
      heads: heads,
      assigned: assigned,
      recommended: recommended,
      onSelect: onSelect,
    ),
  );
}

/// 打印头选择对话框。
class HeadPickerDialog extends StatelessWidget {
  final ProductMaterial material;
  final List<PrintHead> heads;
  final int? assigned;
  final int? recommended;
  final ValueChanged<int?> onSelect;

  const HeadPickerDialog({
    super.key,
    required this.material,
    required this.heads,
    required this.assigned,
    required this.recommended,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final materialColor = Color(material.argb);
    return AlertDialog(
      title: Text('选择打印头 · ${material.colorName}',
          style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final head in heads)
              HeadPickerOption(
                head: head,
                selected: assigned == head.index,
                recommended: recommended == head.index,
                typeOk: head.filamentType == material.colorName,
                deltaE: colorDistance(materialColor, Color(head.argb)),
                onTap: () {
                  onSelect(head.index);
                  Navigator.of(context).pop();
                },
              ),
            const Divider(height: 24),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFEFEFEF),
                child: Icon(Icons.clear, size: 18, color: Color(0xFF8E8E8E)),
              ),
              title: const Text('清除分配', style: TextStyle(fontSize: 14)),
              dense: true,
              onTap: () {
                onSelect(null);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class HeadPickerOption extends StatelessWidget {
  final PrintHead head;
  final bool selected;
  final bool recommended;
  final bool typeOk;
  final double deltaE;
  final VoidCallback onTap;

  const HeadPickerOption({
    super.key,
    required this.head,
    required this.selected,
    required this.recommended,
    required this.typeOk,
    required this.deltaE,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = !head.enabled;
    return ListTile(
      enabled: !disabled,
      leading: CircleAvatar(
        backgroundColor: Color(head.argb),
        radius: 14,
        child: disabled
            ? const Icon(Icons.block, size: 16, color: Colors.white70)
            : null,
      ),
      title: Row(
        children: [
          Text('打印头 ${head.index}', style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          if (recommended)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF0C63E2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('推荐',
                  style: TextStyle(color: Colors.white, fontSize: 10)),
            ),
          if (!typeOk && !disabled)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text('类型不符',
                  style:
                      TextStyle(color: Colors.orange.shade700, fontSize: 10)),
            ),
        ],
      ),
      subtitle: Text(
        disabled
            ? '未启用'
            : '${head.filamentType} · ${head.nozzleDiameter}mm · ΔE ${deltaE.toStringAsFixed(1)}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: selected
          ? const Icon(Icons.check_circle, color: Color(0xFF0C63E2))
          : const Icon(Icons.radio_button_unchecked, color: Color(0xFFBFBFBF)),
      dense: true,
      onTap: onTap,
    );
  }
}
