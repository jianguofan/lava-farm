/// 右侧批量控制抽屉
import 'package:flutter/material.dart';

import '../../data/farm_printer_state.dart';

class BatchControlDrawer extends StatefulWidget {
  final List<FarmPrinterState> selectedPrinters;
  final Future<List<BatchResult>> Function(BatchControlOperation operation, double? value)
      onSubmit;

  const BatchControlDrawer({
    super.key,
    required this.selectedPrinters,
    required this.onSubmit,
  });

  @override
  State<BatchControlDrawer> createState() => _BatchControlDrawerState();
}

class _BatchControlDrawerState extends State<BatchControlDrawer> {
  BatchControlOperation _operation = BatchControlOperation.pause;
  final _valueController = TextEditingController(text: '65');
  bool _submitting = false;

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 520,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _SectionTitle(step: 1, title: '操作类型', subtitle: '请选择要对所选设备执行的操作'),
                  const SizedBox(height: 12),
                  _buildOperationGrid(),
                  const SizedBox(height: 16),
                  _buildCurrentSelection(),
                  if (_operation.requiresValue) ...[
                    const SizedBox(height: 16),
                    _buildValueInput(),
                  ],
                  const SizedBox(height: 20),
                  _SectionTitle(
                    step: 2,
                    title: '已选设备',
                    subtitle: '以下设备将按所选操作批量执行',
                    trailing: '已选 ${widget.selectedPrinters.length} 台',
                  ),
                  const SizedBox(height: 12),
                  _buildPrinterTable(),
                ],
              ),
            ),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text('批量控制', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            onPressed: _submitting ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildOperationGrid() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: BatchControlOperation.values.map((operation) {
        final selected = operation == _operation;
        return InkWell(
          onTap: _submitting ? null : () => setState(() => _operation = operation),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 150,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected ? Colors.blue.withOpacity(0.08) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? Colors.blue : Colors.grey.shade200, width: selected ? 2 : 1),
            ),
            child: Column(
              children: [
                Stack(
                  alignment: Alignment.topRight,
                  children: [
                    Center(child: Icon(operation.icon, color: selected ? Colors.blue : Colors.grey.shade600)),
                    if (selected)
                      const Icon(Icons.check_circle, size: 16, color: Colors.blue),
                  ],
                ),
                const SizedBox(height: 8),
                Text(operation.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCurrentSelection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Row(
        children: [
          Icon(_operation.icon, color: Colors.blue),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: '当前选择：'),
                TextSpan(text: _operation.label, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
          Text('确认无误后提交', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildValueInput() {
    return TextField(
      controller: _valueController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: _operation.valueLabel,
        suffixText: '°C',
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildPrinterTable() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 38,
        dataRowMaxHeight: 44,
        columns: const [
          DataColumn(label: Text('#')),
          DataColumn(label: Text('型号')),
          DataColumn(label: Text('设备编号')),
          DataColumn(label: Text('状态')),
        ],
        rows: [
          for (var i = 0; i < widget.selectedPrinters.length; i++)
            DataRow(cells: [
              DataCell(Text('${i + 1}')),
              DataCell(Text(widget.selectedPrinters[i].model ?? 'U1')),
              DataCell(Text(widget.selectedPrinters[i].displayName ?? widget.selectedPrinters[i].sn)),
              DataCell(Text(_statusLabel(widget.selectedPrinters[i]))),
            ]),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.grey.shade200))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _submitting || widget.selectedPrinters.isEmpty ? null : _submit,
            icon: _submitting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: Text('提交操作：${_operation.label}'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final value = _operation.requiresValue ? double.tryParse(_valueController.text) : null;
    if (_operation.requiresValue && value == null) return;
    setState(() => _submitting = true);
    final results = await widget.onSubmit(_operation, value);
    if (!mounted) return;
    setState(() => _submitting = false);
    Navigator.pop(context, results);
  }

  String _statusLabel(FarmPrinterState printer) {
    if (!printer.isOnline) return '离线';
    if (printer.isPrinting) return '运行';
    if (printer.isPaused) return '暂停';
    return '在线';
  }
}

class _SectionTitle extends StatelessWidget {
  final int step;
  final String title;
  final String subtitle;
  final String? trailing;

  const _SectionTitle({
    required this.step,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(radius: 14, child: Text('$step')),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
          ),
        ),
        if (trailing != null) Chip(label: Text(trailing!)),
      ],
    );
  }
}

enum BatchControlOperation {
  pause,
  resume,
  stopAndClear,
  setBedTemp,
  setNozzleTemp,
}

extension BatchControlOperationX on BatchControlOperation {
  String get label {
    switch (this) {
      case BatchControlOperation.pause:
        return '暂停';
      case BatchControlOperation.resume:
        return '继续';
      case BatchControlOperation.stopAndClear:
        return '停止并清盘';
      case BatchControlOperation.setBedTemp:
        return '设置热床温度';
      case BatchControlOperation.setNozzleTemp:
        return '设置喷嘴温度';
    }
  }

  IconData get icon {
    switch (this) {
      case BatchControlOperation.pause:
        return Icons.pause_circle_outline;
      case BatchControlOperation.resume:
        return Icons.play_circle_outline;
      case BatchControlOperation.stopAndClear:
        return Icons.power_settings_new;
      case BatchControlOperation.setBedTemp:
        return Icons.hot_tub_outlined;
      case BatchControlOperation.setNozzleTemp:
        return Icons.wb_sunny_outlined;
    }
  }

  bool get requiresValue =>
      this == BatchControlOperation.setBedTemp ||
      this == BatchControlOperation.setNozzleTemp;

  String get valueLabel {
    switch (this) {
      case BatchControlOperation.setBedTemp:
        return '设置热床温度';
      case BatchControlOperation.setNozzleTemp:
        return '设置喷嘴温度';
      default:
        return '参数';
    }
  }
}
