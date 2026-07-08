/// 置顶异常横幅
///
/// 在控制面板顶部持续展示未解决的农场告警，
/// 最多显示 3 条，带严重级别颜色和操作按钮。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/alert_provider.dart';
import '../../domain/models/farm_alert.dart';

/// 置顶告警横幅
class AlertPinnedBanner extends ConsumerWidget {
  const AlertPinnedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(pinnedAlertsProvider);

    if (alerts.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.orange.shade50,
            Colors.red.shade50,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(
          bottom: BorderSide(
            color: Colors.red.shade200,
            width: 2,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < alerts.length && i < 3; i++)
            _AlertRow(
              alert: alerts[i],
              onAcknowledge: () =>
                  ref.read(alertActionsProvider.notifier).acknowledge(alerts[i].id),
              onMute: () =>
                  ref.read(alertActionsProvider.notifier).mute(alerts[i].id),
            ),
          if (alerts.length > 3)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '还有 ${alerts.length - 3} 条告警...',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单行告警
class _AlertRow extends StatelessWidget {
  final FarmAlert alert;
  final VoidCallback onAcknowledge;
  final VoidCallback onMute;

  const _AlertRow({
    required this.alert,
    required this.onAcknowledge,
    required this.onMute,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (alert.severity) {
      FarmAlertSeverity.critical => (Icons.error, Colors.red.shade700),
      FarmAlertSeverity.warning => (Icons.warning_amber, Colors.orange.shade700),
      FarmAlertSeverity.info => (Icons.info_outline, Colors.blue.shade700),
    };

    return InkWell(
      onTap: onAcknowledge,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            // 严重级别标签
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                alert.severity.label,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
              ),
            ),
            const SizedBox(width: 8),
            // 标题
            Expanded(
              child: Text(
                alert.title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // 详情（短）
            if (alert.detail != null) ...[
              Flexible(
                flex: 2,
                child: Text(
                  alert.detail!,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
            ],
            // 重复计数
            if (alert.count > 1)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${alert.count}',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey.shade700),
                ),
              ),
            const SizedBox(width: 8),
            // 时间
            Text(
              _timeAgo(alert.lastSeenAt),
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
            ),
            const SizedBox(width: 4),
            // 确认按钮
            if (alert.status == FarmAlertStatus.active)
              _MiniButton(
                icon: Icons.check,
                tooltip: '确认',
                onTap: onAcknowledge,
              ),
            // 静音按钮
            _MiniButton(
              icon: Icons.volume_off,
              tooltip: '静音 30 分钟',
              onTap: onMute,
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}min前';
    if (diff.inHours < 24) return '${diff.inHours}h前';
    return '${diff.inDays}d前';
  }
}

class _MiniButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MiniButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: Colors.grey.shade500),
        ),
      ),
    );
  }
}
