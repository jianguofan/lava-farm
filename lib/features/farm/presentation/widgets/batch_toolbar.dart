/// 批量操作工具栏 (T11.3)
///
/// 当有打印机被选中时显示在 Dashboard 底部，
/// 提供批量操作按钮: 暂停 / 取消 / 急停 / 设置温度 / 发送 GCode / 上传打印

import 'package:flutter/material.dart';

/// 批量操作类型
enum BatchAction {
  pause,
  cancel,
  emergencyStop,
  setTemperatures,
  sendGcode,
  uploadAndPrint,
}

/// 批量操作工具栏
class BatchToolbar extends StatelessWidget {
  final int selectedCount;
  final void Function(BatchAction action)? onAction;
  final VoidCallback? onDismiss;

  const BatchToolbar({
    super.key,
    required this.selectedCount,
    this.onAction,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedCount == 0) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // 关闭 + 选中计数
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            const SizedBox(width: 4),
            Text(
              '$selectedCount 台',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),

            // 操作按钮
            _ActionButton(
              icon: Icons.pause,
              label: '暂停',
              onTap: () => onAction?.call(BatchAction.pause),
            ),
            const SizedBox(width: 4),
            _ActionButton(
              icon: Icons.stop,
              label: '取消',
              color: Colors.red,
              onTap: () => _confirmAction(
                context,
                BatchAction.cancel,
                '确认取消 $selectedCount 台打印机的当前打印任务？',
              ),
            ),
            const SizedBox(width: 4),
            _ActionButton(
              icon: Icons.warning_amber,
              label: '急停',
              color: Colors.red.shade700,
              onTap: () => _confirmAction(
                context,
                BatchAction.emergencyStop,
                '⚠️ 确认对所有打印机执行紧急停止？',
                isDestructive: true,
              ),
            ),
            const SizedBox(width: 8),
            // 更多操作菜单
            PopupMenuButton<BatchAction>(
              icon: const Icon(Icons.more_horiz, size: 20),
              onSelected: (action) => onAction?.call(action),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: BatchAction.setTemperatures,
                  child: ListTile(
                    leading: Icon(Icons.thermostat),
                    title: Text('设置温度'),
                    dense: true,
                  ),
                ),
                const PopupMenuItem(
                  value: BatchAction.sendGcode,
                  child: ListTile(
                    leading: Icon(Icons.code),
                    title: Text('发送 GCode'),
                    dense: true,
                  ),
                ),
                const PopupMenuItem(
                  value: BatchAction.uploadAndPrint,
                  child: ListTile(
                    leading: Icon(Icons.cloud_upload),
                    title: Text('上传并打印'),
                    dense: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmAction(
    BuildContext context,
    BatchAction action,
    String message, {
    bool isDestructive = false,
  }) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(action.label),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              onAction?.call(action);
            },
            style: isDestructive
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            child: Text(isDestructive ? '确认执行' : '确认'),
          ),
        ],
      ),
    );
  }
}

/// 单个操作按钮
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Colors.grey.shade700;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: effectiveColor),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: effectiveColor),
            ),
          ],
        ),
      ),
    );
  }
}

extension BatchActionLabel on BatchAction {
  String get label {
    switch (this) {
      case BatchAction.pause: return '暂停打印';
      case BatchAction.cancel: return '取消打印';
      case BatchAction.emergencyStop: return '紧急停止';
      case BatchAction.setTemperatures: return '设置温度';
      case BatchAction.sendGcode: return '发送 GCode';
      case BatchAction.uploadAndPrint: return '上传并打印';
    }
  }
}
