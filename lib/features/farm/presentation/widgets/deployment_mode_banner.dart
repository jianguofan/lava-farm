/// 状态横幅组件
///
/// 在 Dashboard 顶部显示重要的系统状态提醒。

import 'package:flutter/material.dart';

/// HTTP 降级横幅
class HttpFallbackBanner extends StatelessWidget {
  final int httpFallbackCount;

  const HttpFallbackBanner({super.key, required this.httpFallbackCount});

  @override
  Widget build(BuildContext context) {
    if (httpFallbackCount == 0) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.amber.shade700,
      child: Row(
        children: [
          const Icon(Icons.wifi_find, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$httpFallbackCount 台打印机使用 HTTP 降级模式',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// Broker 断连横幅
class BrokerDisconnectedBanner extends StatelessWidget {
  const BrokerDisconnectedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.red.shade700,
      child: const Row(
        children: [
          Icon(Icons.cloud_off, color: Colors.white, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Broker 连接断开，正在重连...',
              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// App 关闭确认对话框
class ShutdownConfirmationDialog extends StatelessWidget {
  final int activePrintCount;

  const ShutdownConfirmationDialog({super.key, required this.activePrintCount});

  static Future<bool> show(
    BuildContext context, {
    required int activePrintCount,
  }) async {
    if (activePrintCount == 0) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ShutdownConfirmationDialog(activePrintCount: activePrintCount),
    );
    return result ?? true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.info_outline, color: Colors.blue),
          SizedBox(width: 8),
          Text('确认退出'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$activePrintCount 台打印机正在打印中。',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Broker 作为 Docker 容器独立运行。关闭 App 不会中断打印任务。\n'
            '重新打开 App 即可恢复监控。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('退出（打印继续）'),
        ),
      ],
    );
  }
}
