import 'package:flutter/material.dart';

/// 床板检测按钮（含 loading 态）。
class InspectButton extends StatelessWidget {
  final bool isInspecting;
  final VoidCallback? onTap;

  const InspectButton({super.key, required this.isInspecting, this.onTap});

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
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
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
