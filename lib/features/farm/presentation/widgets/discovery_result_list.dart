/// 发现结果列表组件
///
/// 在 DiscoveryWizardPage 的 Step 2 中显示扫描结果。
/// 支持:
/// - 扫描中显示进度指示器
/// - 空结果显示占位提示
/// - 多选打印机（勾选框）
/// - 显示每台打印机的 SN / IP / 型号 / 连接状态

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/discovery_provider.dart';
import '../../data/printer_discovery.dart';

/// 发现结果列表
///
/// 从 [discoveryProvider] 读取扫描状态和结果，
/// 用户可勾选要入网的打印机。
class DiscoveryResultList extends ConsumerWidget {
  const DiscoveryResultList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(discoveryProvider);

    // ── 扫描中 ──
    if (state.isScanning) {
      return _ScanningView(
        progress: state.scanProgress,
        phase: state.scanPhase,
      );
    }

    // ── 扫描出错 ──
    if (state.error != null) {
      return _ErrorView(
        message: state.error!,
        onRetry: () => ref.read(discoveryProvider.notifier).startDiscovery(),
      );
    }

    // ── 空结果 ──
    if (state.mergedResults.isEmpty) {
      return const _EmptyView();
    }

    // ── 结果列表 ──
    return _ResultList(
      printers: state.mergedResults,
      selectedIds: state.selectedIds,
      onToggle: (id) => ref.read(discoveryProvider.notifier).toggleSelection(id),
      onSelectAll: () => ref.read(discoveryProvider.notifier).toggleSelectAll(),
    );
  }
}

/// 扫描中视图
class _ScanningView extends StatelessWidget {
  final double progress;
  final String phase;

  const _ScanningView({required this.progress, required this.phase});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 24),
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(value: progress > 0 ? progress : null),
        ),
        const SizedBox(height: 16),
        Text(
          phase.isNotEmpty ? phase : '正在扫描局域网打印机...',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
        if (progress > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).toStringAsFixed(0)}%',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ],
      ],
    );
  }
}

/// 错误视图
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, size: 48, color: Colors.red),
        const SizedBox(height: 16),
        Text(
          message,
          style: const TextStyle(fontSize: 14, color: Colors.red),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    );
  }
}

/// 空结果视图
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          '未发现打印机',
          style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 8),
        Text(
          '请确保打印机与电脑在同一局域网\n然后尝试 mDNS 或 TCP 扫描',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// 结果列表（含全选和逐条勾选）
class _ResultList extends StatelessWidget {
  final List<DiscoveredPrinter> printers;
  final Set<String> selectedIds;
  final void Function(String id) onToggle;
  final VoidCallback onSelectAll;

  const _ResultList({
    required this.printers,
    required this.selectedIds,
    required this.onToggle,
    required this.onSelectAll,
  });

  bool get _isAllSelected =>
      printers.isNotEmpty && selectedIds.length == printers.length;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── 头部：全选 ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Checkbox(
                value: _isAllSelected,
                tristate: selectedIds.isNotEmpty && !_isAllSelected,
                onChanged: (_) => onSelectAll(),
              ),
              Text(
                '已选择 ${selectedIds.length} / ${printers.length} 台',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // ── 列表 ──
        Expanded(
          child: ListView.separated(
            itemCount: printers.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
            itemBuilder: (context, index) {
              final printer = printers[index];
              final isSelected = selectedIds.contains(printer.id);

              return _PrinterListTile(
                printer: printer,
                isSelected: isSelected,
                onToggle: () => onToggle(printer.id),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 单台打印机列表项
class _PrinterListTile extends StatelessWidget {
  final DiscoveredPrinter printer;
  final bool isSelected;
  final VoidCallback onToggle;

  const _PrinterListTile({
    required this.printer,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Checkbox(
        value: isSelected,
        onChanged: (_) => onToggle(),
      ),
      title: Row(
        children: [
          // 来源图标
          Icon(
            _sourceIcon,
            size: 16,
            color: _sourceColor,
          ),
          const SizedBox(width: 6),
          // 名称
          Expanded(
            child: Text(
              printer.displayName,
              style: const TextStyle(fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 连接状态标识
          if (printer.klippyConnected != null)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: printer.klippyConnected! ? Colors.green : Colors.red,
              ),
            ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(left: 22),
        child: Text(
          _subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
      ),
      onTap: onToggle,
      dense: true,
      selected: isSelected,
      selectedTileColor: Colors.blue.withOpacity(0.05),
    );
  }

  IconData get _sourceIcon {
    switch (printer.source) {
      case DiscoverySource.mdns:
        return Icons.wifi_find;
      case DiscoverySource.tcp:
        return Icons.search;
      case DiscoverySource.manual:
        return Icons.edit;
      case DiscoverySource.csvImport:
        return Icons.upload_file;
    }
  }

  Color get _sourceColor {
    switch (printer.source) {
      case DiscoverySource.mdns:
        return Colors.green;
      case DiscoverySource.tcp:
        return Colors.blue;
      case DiscoverySource.manual:
        return Colors.orange;
      case DiscoverySource.csvImport:
        return Colors.purple;
    }
  }

  String get _subtitle {
    final parts = <String>[];
    parts.add('${printer.ip}:${printer.port}');
    if (printer.model != null) parts.add(printer.model!);
    if (printer.firmwareVersion != null) parts.add('v${printer.firmwareVersion}');
    return parts.join(' · ');
  }
}
