/// 农场统计栏 (P11.3)
///
/// Dashboard 顶部的统计卡片行:
///   总数 | 在线 | 打印中 | MQTT | HTTP

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/printer_list_provider.dart';

class StatsBar extends ConsumerWidget {
  const StatsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(farmStatsProvider);

    if (stats.total == 0) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _StatChip(
            label: '总数',
            value: stats.total.toString(),
            icon: Icons.print,
            color: Colors.blueGrey,
          ),
          const SizedBox(width: 8),
          _StatChip(
            label: '在线',
            value: stats.online.toString(),
            icon: Icons.wifi,
            color: Colors.green,
          ),
          const SizedBox(width: 8),
          _StatChip(
            label: '打印中',
            value: stats.printing.toString(),
            icon: Icons.play_arrow,
            color: Colors.blue,
          ),
          const SizedBox(width: 8),
          _StatChip(
            label: 'MQTT',
            value: stats.mqttCount.toString(),
            icon: Icons.sync,
            color: Colors.purple,
          ),
          const SizedBox(width: 8),
          _StatChip(
            label: 'HTTP',
            value: stats.httpCount.toString(),
            icon: Icons.http,
            color: stats.httpCount > 0 ? Colors.orange : Colors.grey,
            badge: stats.httpCount > 0 ? '!' : null,
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? badge;

  const _StatChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.orange.shade700,
              ),
              child: Text(
                badge!,
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
