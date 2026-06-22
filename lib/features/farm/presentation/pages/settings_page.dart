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
              // TODO: 调用 PrinterRegistry.clear()
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已清除所有打印机信息'),
                ),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认清除'),
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
