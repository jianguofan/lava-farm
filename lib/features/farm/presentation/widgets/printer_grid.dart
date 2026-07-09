/// 打印机网格布局 (T11.2)
///
/// 自适应列数响应式网格:
/// - 宽屏: 6-8 列
/// - 标准: 4-5 列
/// - 窄屏: 2-3 列
///
/// 支持:
/// - 多选（勾选 / 全选 / 按群组选）
/// - 批量操作工具栏联动
/// - 搜索/筛选
/// - 页面加载时自动触发 device IP 解析（有缓存跳过）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/printer_list_provider.dart';
import '../../data/farm_printer_state.dart';
import 'printer_card.dart';

/// 打印机网格
class PrinterGrid extends ConsumerStatefulWidget {
  /// 选中的打印机 SN 集合
  final Set<String> selectedSns;
  final ValueChanged<Set<String>> onSelectionChanged;
  final void Function(String sn)? onPrinterTap;
  final void Function(String sn)? onPrinterLongPress;
  final void Function(String sn)? onDeletePrinter;

  const PrinterGrid({
    super.key,
    required this.selectedSns,
    required this.onSelectionChanged,
    this.onPrinterTap,
    this.onPrinterLongPress,
    this.onDeletePrinter,
  });

  @override
  ConsumerState<PrinterGrid> createState() => _PrinterGridState();
}

class _PrinterGridState extends ConsumerState<PrinterGrid> {
  bool _initialIpFetchDone = false;

  @override
  void initState() {
    super.initState();
    // 首帧后立刻触发 IP 解析，不等待 30s 定时器
    WidgetsBinding.instance.addPostFrameCallback((_) => _triggerIpResolution());
  }

  void _triggerIpResolution() {
    if (_initialIpFetchDone) return;
    _initialIpFetchDone = true;
    final router = ref.read(farmMqttRouterProvider);
    router?.resolveIpsForUnknownDevices();
  }

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printerListProvider);

    if (printers.isEmpty) {
      return _EmptyState();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 计算列数：卡片最小宽度 160px
        final crossAxisCount = (constraints.maxWidth / 160).floor().clamp(2, 8);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 操作栏：全选 + 计数
            _SelectionBar(
              totalCount: printers.length,
              selectedCount: widget.selectedSns.length,
              onSelectAll: () => _toggleSelectAll(printers),
              onClearSelection: () => widget.onSelectionChanged({}),
            ),

            // 网格
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.3, // 卡片宽高比
                ),
                itemCount: printers.length,
                itemBuilder: (context, index) {
                  final printer = printers[index];
                  final card = PrinterCard(
                    sn: printer.sn,
                    isSelected: widget.selectedSns.contains(printer.sn),
                    onTap: () {
                      if (widget.selectedSns.isNotEmpty) {
                        // 选择模式下点击 = 切换选中
                        _toggleSelection(printer.sn);
                      } else {
                        widget.onPrinterTap?.call(printer.sn);
                      }
                    },
                    onLongPress: () {
                      if (widget.selectedSns.isNotEmpty) {
                        // 多选模式下长按 = 切换选中
                        _toggleSelection(printer.sn);
                      } else {
                        // 非多选模式下长按 = 弹出删除确认
                        _showDeleteDialog(context, printer.sn, printer.displayName ?? printer.sn);
                      }
                      widget.onPrinterLongPress?.call(printer.sn);
                    },
                  );

                  // 仅在非多选模式下支持滑动删除
                  if (widget.selectedSns.isNotEmpty) {
                    return card;
                  }

                  return Dismissible(
                    key: Key('dismiss_${printer.sn}'),
                    direction: DismissDirection.endToStart,
                    confirmDismiss: (_) => _confirmDismiss(context, printer.sn, printer.displayName ?? printer.sn),
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.red.shade400,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
                    ),
                    child: card,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// 长按删除确认对话框
  void _showDeleteDialog(BuildContext context, String sn, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除打印机'),
        content: Text('确定要移除打印机 "$name" 吗？\n\n打印机本身不会受到影响，你可以之后重新添加。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDeletePrinter?.call(sn);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 滑动删除确认（Dismissible confirmDismiss）
  Future<bool> _confirmDismiss(BuildContext context, String sn, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除打印机'),
        content: Text('确定要移除打印机 "$name" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.onDeletePrinter?.call(sn);
      return true;
    }
    return false;
  }

  void _toggleSelection(String sn) {
    final updated = Set<String>.from(widget.selectedSns);
    if (updated.contains(sn)) {
      updated.remove(sn);
    } else {
      updated.add(sn);
    }
    widget.onSelectionChanged(updated);
  }

  void _toggleSelectAll(List<FarmPrinterState> printers) {
    if (widget.selectedSns.length == printers.length) {
      widget.onSelectionChanged({}); // 全不选
    } else {
      widget.onSelectionChanged(printers.map((p) => p.sn).toSet()); // 全选
    }
  }
}

/// 选择操作栏
class _SelectionBar extends StatelessWidget {
  final int totalCount;
  final int selectedCount;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;

  const _SelectionBar({
    required this.totalCount,
    required this.selectedCount,
    required this.onSelectAll,
    required this.onClearSelection,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text(
            '$totalCount 台打印机',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const Spacer(),
          if (selectedCount > 0) ...[
            Text(
              '已选 $selectedCount 台',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onSelectAll,
              child: Text(
                selectedCount == totalCount ? '全不选' : '全选',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: onClearSelection,
              child: const Text('取消', style: TextStyle(fontSize: 11)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 空状态占位
class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.print_outlined, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '还没有打印机',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右上角 + 开始发现打印机',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}
