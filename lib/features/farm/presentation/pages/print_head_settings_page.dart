/// 打印头设置页
///
/// 维护全局一套 4 个物理打印头的预设：装载耗材颜色、类型、喷嘴直径、是否启用。
/// 持久化在 ~/.lava_farm/print_heads.json（[PrintHeadRepository]）。
/// 这套预设用于耗材→打印头的自动匹配（[FilamentMatcher]）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/print_head_provider.dart';
import '../../data/print_head_repository.dart';
import '../../domain/models/print_head.dart';

/// 编辑弹窗中的预设色板。
const List<int> kHeadColorPalette = [
  0xFF9E9E9E, // 灰
  0xFF333333, // 黑
  0xFFFFFFFF, // 白
  0xFFF00000, // 红
  0xFFFF9900, // 橙
  0xFFFFC701, // 黄
  0xFF0DCD3A, // 绿
  0xFF0C63E2, // 蓝
  0xFF8E44AD, // 紫
  0xFF1ABC9C, // 青
];

class PrintHeadSettingsPage extends ConsumerWidget {
  const PrintHeadSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(printHeadProvider);
    final heads = async.value ?? PrintHeadRepository.defaultHeads();

    return Scaffold(
      appBar: AppBar(
        title: const Text('打印头设置'),
        actions: [
          IconButton(
            tooltip: '恢复默认',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('恢复默认'),
                  content: const Text('将 4 个打印头重置为默认配置？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('重置'),
                    ),
                  ],
                ),
              );
              if (ok == true)
                ref.read(printHeadProvider.notifier).resetDefault();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '预设机台 4 个打印头装载的耗材；耗材自动匹配按类型 + 喷嘴 + 颜色就近分配。',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
          for (final head in heads)
            _HeadCard(
              head: head,
              onTap: () async {
                final updated = await showDialog<PrintHead>(
                  context: context,
                  builder: (_) => _HeadEditDialog(head: head),
                );
                if (updated != null) {
                  ref
                      .read(printHeadProvider.notifier)
                      .updateHead(head.index, updated);
                }
              },
            ),
        ],
      ),
    );
  }
}

class _HeadCard extends StatelessWidget {
  final PrintHead head;
  final VoidCallback onTap;

  const _HeadCard({required this.head, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: Color(head.argb),
        radius: 18,
        child: Text(
          '${head.index}',
          style: TextStyle(
            color: _isLight(Color(head.argb))
                ? const Color(0xFF666666)
                : Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text('打印头 ${head.index}'),
      subtitle: Text(
        '${head.filamentType} · ${head.nozzleDiameter}mm · ${head.enabled ? "启用" : "未启用"}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFFBFBFBF)),
    );
  }
}

/// 打印头编辑弹窗。
class _HeadEditDialog extends StatefulWidget {
  final PrintHead head;

  const _HeadEditDialog({required this.head});

  @override
  State<_HeadEditDialog> createState() => _HeadEditDialogState();
}

class _HeadEditDialogState extends State<_HeadEditDialog> {
  late final TextEditingController _typeCtrl;
  late final TextEditingController _nozzleCtrl;
  late int _argb;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _typeCtrl = TextEditingController(text: widget.head.filamentType);
    _nozzleCtrl =
        TextEditingController(text: widget.head.nozzleDiameter.toString());
    _argb = widget.head.argb;
    _enabled = widget.head.enabled;
  }

  @override
  void dispose() {
    _typeCtrl.dispose();
    _nozzleCtrl.dispose();
    super.dispose();
  }

  PrintHead get _result => widget.head.copyWith(
        filamentType:
            _typeCtrl.text.trim().isEmpty ? 'PLA' : _typeCtrl.text.trim(),
        nozzleDiameter: double.tryParse(_nozzleCtrl.text.trim()) ??
            widget.head.nozzleDiameter,
        argb: _argb,
        enabled: _enabled,
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('打印头 ${widget.head.index}'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('耗材颜色',
                style: TextStyle(fontSize: 13, color: Color(0xFF666666))),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in kHeadColorPalette)
                  GestureDetector(
                    onTap: () => setState(() => _argb = c),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _argb == c
                              ? const Color(0xFF0C63E2)
                              : const Color(0xFFD9D9D9),
                          width: _argb == c ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _typeCtrl,
              decoration: const InputDecoration(
                labelText: '耗材类型',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nozzleCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '喷嘴直径 (mm)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_result),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

bool _isLight(Color c) =>
    (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue) / 255 > 0.6;
