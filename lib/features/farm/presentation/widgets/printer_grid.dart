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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/printer_list_provider.dart';
import '../../data/farm_printer_state.dart';
import 'printer_card.dart';

/// 打印机网格
class PrinterGrid extends ConsumerWidget {
  /// 选中的打印机 SN 集合
  final Set<String> selectedSns;
  final ValueChanged<Set<String>> onSelectionChanged;
  final void Function(String sn)? onPrinterTap;
  final void Function(String sn)? onPrinterLongPress;

  const PrinterGrid({
    super.key,
    required this.selectedSns,
    required this.onSelectionChanged,
    this.onPrinterTap,
    this.onPrinterLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              selectedCount: selectedSns.length,
              onSelectAll: () => _toggleSelectAll(printers),
              onClearSelection: () => onSelectionChanged({}),
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
                  return PrinterCard(
                    sn: printer.sn,
                    isSelected: selectedSns.contains(printer.sn),
                    onTap: () {
                      if (selectedSns.isNotEmpty) {
                        // 选择模式下点击 = 切换选中
                        _toggleSelection(printer.sn);
                      } else {
                        onPrinterTap?.call(printer.sn);
                      }
                    },
                    onLongPress: () {
                      // 长按进入多选模式
                      if (selectedSns.isEmpty) {
                        _toggleSelection(printer.sn);
                      }
                      onPrinterLongPress?.call(printer.sn);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _toggleSelection(String sn) {
    final updated = Set<String>.from(selectedSns);
    if (updated.contains(sn)) {
      updated.remove(sn);
    } else {
      updated.add(sn);
    }
    onSelectionChanged(updated);
  }

  void _toggleSelectAll(List<FarmPrinterState> printers) {
    if (selectedSns.length == printers.length) {
      onSelectionChanged({}); // 全不选
    } else {
      onSelectionChanged(printers.map((p) => p.sn).toSet()); // 全选
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
