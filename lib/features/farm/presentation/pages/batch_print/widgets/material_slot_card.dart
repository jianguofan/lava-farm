import 'package:flutter/material.dart';

import '../../../../domain/models/product_material.dart';

/// 耗材槽位卡片（对应 Figma「配置耗材」Component 292）。
///
/// 顶部颜色条：耗材所需的切片颜色 + 类型 + 克重（只读，来自 3mf）。
/// 徽标：分配到的打印头编号（1–4），圆心取**该头预设色**，便于和顶部所需色对比；
/// 未分配显示「?」，克重为 0 切换红色「!」提醒。
class MaterialSlotCard extends StatelessWidget {
  final ProductMaterial material;
  final int index;
  final Color? headColor; // 已分配打印头的预设色
  final VoidCallback? onTap;

  const MaterialSlotCard({
    super.key,
    required this.material,
    required this.index,
    this.headColor,
    this.onTap,
  });

  static const double width = 88;
  static const double height = 116;
  static const double stripHeight = 50;
  static const double badgeSize = 26;

  @override
  Widget build(BuildContext context) {
    final sliceColor = Color(material.argb);
    final light = _isLight(sliceColor);
    final stripText = light ? const Color(0xFF8E8E8E) : Colors.white;
    final numberText = light ? const Color(0xFF666666) : Colors.white;
    final needsAttention = material.grams <= 0;
    final assigned = material.assignedHead;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEAEAEA)),
        ),
        child: Column(
          children: [
            // 顶部颜色条：耗材所需色 + 类型 + 克重
            Container(
              height: stripHeight,
              color: sliceColor,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    material.colorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: stripText,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${material.grams.toStringAsFixed(0)}g',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: stripText,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 打印头编号徽标：已分配显示头号（头预设色底），未分配显示「?」
            _buildBadge(needsAttention, assigned, headColor, numberText),
            const Spacer(),
            const Icon(Icons.expand_more, size: 16, color: Color(0xFFBFBFBF)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(
      bool needsAttention, int? assigned, Color? headColor, Color numberText) {
    // 克重为 0 → 红色「!」提醒（优先）
    if (needsAttention) {
      return Container(
        width: badgeSize,
        height: badgeSize,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFE5E5E5)),
        ),
        alignment: Alignment.center,
        child:
            const Icon(Icons.priority_high, size: 16, color: Color(0xFFD80000)),
      );
    }
    // 已分配打印头 → 头预设色底 + 头号
    if (assigned != null) {
      final bg = headColor ?? Colors.grey.shade300;
      return Container(
        width: badgeSize,
        height: badgeSize,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border:
              _isLight(bg) ? Border.all(color: const Color(0xFFE5E5E5)) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          '$assigned',
          style: TextStyle(
            color: _isLight(bg) ? const Color(0xFF666666) : Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    // 未分配 → 描边「?」
    return Container(
      width: badgeSize,
      height: badgeSize,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFD9D9D9)),
      ),
      alignment: Alignment.center,
      child: const Text('?',
          style: TextStyle(
              color: Color(0xFF8E8E8E),
              fontSize: 13,
              fontWeight: FontWeight.w600)),
    );
  }
}

/// 按相对亮度判断是否为浅色（>0.6 视为浅色，文字用深色）。
bool _isLight(Color c) {
  final l = (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue) / 255;
  return l > 0.6;
}
