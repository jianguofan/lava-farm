import 'package:flutter/material.dart';

/// 快速操作按钮（全选就绪 / 取消全选 等）。
class QuickAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const QuickAction({super.key, required this.label, required this.onTap});

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
