/// 应用设置页面
///
/// 提供全局应用配置:
/// - Broker 部署模式（快速体验 / 生产模式）
/// - 外部 Broker 连接配置入口
/// - 打印机列表管理（导出 / 清除）
/// - 外观设置（主题 / 语言）
/// - 关于信息

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/printer_list_provider.dart';
import 'broker_setup_page.dart';

/// 应用设置页面
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // ── 区块 1: Broker 部署 ──
          _SectionHeader(title: 'Broker 部署'),
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('Docker Mosquitto Broker'),
            subtitle: const Text('管理 Docker 容器中的 MQTT Broker'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BrokerSetupPage(),
                ),
              );
            },
          ),

          // ── 分隔 ──
          const Divider(),

          // ── 区块 2: 打印机管理 ──
          _SectionHeader(title: '打印机管理'),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('添加打印机'),
            subtitle: const Text('打开发现向导，扫描并添加打印机'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pushNamed(context, '/discovery');
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('CSV 批量导入'),
            subtitle: const Text('从 CSV 文件导入打印机列表'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pushNamed(context, '/discovery');
            },
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('导出打印机列表'),
            subtitle: const Text('将当前打印机列表导出为 CSV'),
            onTap: () {
              // TODO: 实现 CSV 导出
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('CSV 导出功能即将上线')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.auto_delete, color: Colors.orange),
            title: _ExpiredDevicesTile(),
            subtitle: const Text('删除长期离线的打印机（默认 24 小时）'),
            onTap: () => _confirmDeleteExpired(),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('清除所有打印机', style: TextStyle(color: Colors.red)),
            subtitle: const Text('从本地存储中移除所有已注册的打印机'),
            onTap: () => _confirmClearPrinters(),
          ),

          // ── 分隔 ──
          const Divider(),

          // ── 区块 3: 外观 ──
          _SectionHeader(title: '外观'),
          ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('主题'),
            subtitle: const Text('跟随系统'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: 主题选择器
            },
          ),

          // ── 分隔 ──
          const Divider(),

          // ── 区块 5: 关于 ──
          _SectionHeader(title: '关于'),
          const ListTile(
            leading: Icon(Icons.info),
            title: Text('Lava Farm'),
            subtitle: Text('版本 0.1.0'),
          ),
          ListTile(
            leading: const Icon(Icons.description),
            title: const Text('开源许可'),
            subtitle: const Text('查看第三方库许可信息'),
            onTap: () {
              showLicensePage(
                context: context,
                applicationName: 'Lava Farm',
                applicationVersion: '0.1.0',
                applicationLegalese: 'Copyright © 2026 Lava Farm',
              );
            },
          ),
        ],
      ),
    );
  }

  /// 删除过期设备确认对话框
  void _confirmDeleteExpired() {
    final expiredCount = ref.read(expiredPrinterCountProvider);
    final expiredPrinters = ref.read(expiredPrintersProvider);

    if (expiredCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有过期设备（离线超过 24 小时）')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除过期设备'),
        content: Text(
          '检测到 $expiredCount 台设备离线超过 24 小时：\n\n'
          '${expiredPrinters.map((p) => '• ${p.displayName ?? p.sn} (最后在线: ${_formatTimeAgo(p.lastStatusTime)})').join('\n')}\n\n'
          '此操作将从系统中移除这些设备，打印机本身不会受到影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final hub = ref.read(farmHubProvider);
              final removed = hub.removeExpiredPrinters();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已删除 $removed 台过期设备'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  /// 清除打印机确认对话框
  void _confirmClearPrinters() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清除'),
        content: const Text(
          '此操作将永久删除本地存储的所有打印机信息。\n\n'
          '打印机本身不会受到影响，你可以之后重新添加。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final hub = ref.read(farmHubProvider);
              final allSns = ref.read(farmStoreProvider).allPrinters.map((p) => p.sn).toList();
              for (final sn in allSns) {
                hub.removePrinter(sn);
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已清除 ${allSns.length} 台打印机信息')),
                );
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return '${diff.inDays} 天前';
    if (diff.inHours > 0) return '${diff.inHours} 小时前';
    if (diff.inMinutes > 0) return '${diff.inMinutes} 分钟前';
    return '刚刚';
  }
}

/// 过期设备数量标题（响应式）
class _ExpiredDevicesTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(expiredPrinterCountProvider);
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: '删除过期设备'),
          if (count > 0)
            TextSpan(
              text: '  ($count)',
              style: TextStyle(
                color: Colors.orange.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}

/// 区块标题
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
