import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parse_3mf/parse_3mf.dart';

import '../../../../application/providers/batch_print_provider.dart';

/// Step1：产品 / 文件选择。
///
/// 选择 .3mf 后会调用 [parse_3mf] 解析出结构化元数据 + 预览图，直接在页面展示。
class ProductStep extends ConsumerWidget {
  final BatchPrintArgs args;

  const ProductStep({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batchPrintProvider(args));
    final notifier = ref.read(batchPrintProvider(args).notifier);
    final fileName = state.fileName;
    final isExecuting = state.isExecuting;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 文件选择
          Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 20),
              const SizedBox(width: 8),
              const Text('选择文件', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: fileName != null
                    ? Chip(
                        avatar: const Icon(Icons.check_circle, size: 18, color: Colors.green),
                        label: Text(fileName, style: const TextStyle(fontSize: 13)),
                        onDeleted: isExecuting ? null : notifier.clearFile,
                      )
                    : OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('选择 3MF / GCode 文件'),
                        onPressed: isExecuting ? null : notifier.pickFile,
                      ),
              ),
            ],
          ),
          if (fileName == null) ...[
            const SizedBox(height: 24),
            Center(
              child: Text(
                '选择 3MF / GCode 文件后点击「下一步」',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            _ParsedArea(
              state: state,
              onSelectPlate: notifier.selectPlate,
              onToggleMultiMode: notifier.setMultiPlateMode,
            ),
          ],
        ],
      ),
    );
  }
}

/// 文件选中后的解析展示区：根据扩展名 / 解析状态切换加载、错误、结果三种视图。
class _ParsedArea extends StatelessWidget {
  final BatchPrintState state;
  final ValueChanged<int> onSelectPlate;
  final ValueChanged<bool> onToggleMultiMode;

  const _ParsedArea({
    required this.state,
    required this.onSelectPlate,
    required this.onToggleMultiMode,
  });

  @override
  Widget build(BuildContext context) {
    // 仅 .3mf 是可解析的 ZIP 结构；GCode 等不做解析。
    final is3mf = state.fileName!.toLowerCase().endsWith('.3mf');
    if (!is3mf) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
          const SizedBox(width: 8),
          Text('文件已选择（GCode 无预览，可直接下一步）',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        ],
      );
    }
    if (state.isParsing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(height: 12),
              Text('正在解析 3MF…', style: TextStyle(fontSize: 13, color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    if (state.parseError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: Colors.red.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: Text(state.parseError!,
                  style: TextStyle(fontSize: 13, color: Colors.red.shade700)),
            ),
          ],
        ),
      );
    }
    final meta = state.parsed3mf;
    if (meta == null || meta.profiles.isEmpty) {
      return Text('未解析到内容', style: TextStyle(fontSize: 13, color: Colors.grey.shade500));
    }
    return _ParsedPanel(
      meta: meta,
      images: state.previewImages,
      selectedPlateId: state.printPlate,
      onSelect: onSelectPlate,
      multiPlateMode: state.multiPlateMode,
      onToggleMultiMode: onToggleMultiMode,
    );
  }
}

/// 解析结果面板：主预览图 + 摘要 + 耗材色块 + 各盘列表。
class _ParsedPanel extends StatelessWidget {
  final Metadata meta;
  final Map<String, Uint8List> images;
  final int selectedPlateId;
  final ValueChanged<int> onSelect;
  final bool multiPlateMode;
  final ValueChanged<bool> onToggleMultiMode;

  const _ParsedPanel({
    required this.meta,
    required this.images,
    required this.selectedPlateId,
    required this.onSelect,
    required this.multiPlateMode,
    required this.onToggleMultiMode,
  });

  @override
  Widget build(BuildContext context) {
    final prof = meta.profiles.first;
    final mainPic = prof.pics.isEmpty ? null : prof.pics.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.view_in_ar, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                meta.name ?? prof.name ?? '3MF 模型',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              onPressed: () => _showJson(context),
              icon: const Icon(Icons.data_object, size: 18),
              label: const Text('查看 JSON'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 主预览 + 摘要
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PreviewBox(bytes: mainPic == null ? null : images[mainPic], size: 150),
            const SizedBox(width: 16),
            Expanded(child: _SummaryGrid(prof: prof)),
          ],
        ),
        const SizedBox(height: 12),
        if (prof.filaments.isNotEmpty) ...[
          const Text('耗材', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          _FilamentChips(filaments: prof.filaments),
          const SizedBox(height: 16),
        ],
        // 多盘同打开关（仅 >1 盘时显示）
        if (prof.partitions.length > 1) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: multiPlateMode
                  ? const Color(0xFFE8F0FE)
                  : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: multiPlateMode
                      ? const Color(0xFF0C63E2)
                      : Colors.grey.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.dynamic_feed,
                    size: 18,
                    color: multiPlateMode
                        ? const Color(0xFF0C63E2)
                        : Colors.grey.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('多盘同打',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(
                          multiPlateMode
                              ? '已开启：下一步为每盘分别配置打印机与耗材'
                              : '开启后可让不同盘打印到不同打印机',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                Switch(
                  value: multiPlateMode,
                  onChanged: onToggleMultiMode,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        // 盘列表：单盘模式点选其一；多盘模式改为提示去下一步配置。
        if (multiPlateMode)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.grey.shade500),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '共 ${prof.partitions.length} 盘，点击「下一步」为每盘配置打印机与耗材',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
              ],
            ),
          )
        else ...[
          Text('打印盘（${prof.partitions.length}）· 点击选择要打印的盘',
              style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final pt in prof.partitions) ...[
            _PlateTile(
              partition: pt,
              images: images,
              isSelected: pt.id == selectedPlateId,
              onTap: () => onSelect(pt.id),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  void _showJson(BuildContext context) {
    final json = const JsonEncoder.withIndent('  ').convert(meta.toJson());
    showDialog<void>(
      context: context,
      builder: (_) => _JsonDialog(title: meta.name ?? '3MF JSON', json: json),
    );
  }
}

/// 摘要信息 2×2 网格：喷嘴 / 盘数 / 总重 / 时长。
class _SummaryGrid extends StatelessWidget {
  final Profile prof;

  const _SummaryGrid({required this.prof});

  @override
  Widget build(BuildContext context) {
    final nozzle = prof.nozzle.map((n) => n.toString()).join(' / ');
    final secs = prof.secs;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(children: [
            Expanded(child: _Info(label: '喷嘴', value: nozzle.isEmpty ? '—' : '${nozzle}mm')),
            Expanded(child: _Info(label: '盘数', value: '${prof.partitions.length}')),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: _Info(label: '总重', value: prof.weight == null ? '—' : '${prof.weight}g')),
            Expanded(child: _Info(label: '预估时长', value: _fmtDuration(secs))),
          ]),
        ],
      ),
    );
  }

  String _fmtDuration(int? secs) {
    if (secs == null || secs <= 0) return '未知';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    return h > 0 ? '${h}h${m}m' : '${m}m';
  }
}

class _Info extends StatelessWidget {
  final String label;
  final String value;

  const _Info({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label：', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// 耗材色块行：颜色圆点 + 类型 + 用量。
class _FilamentChips extends StatelessWidget {
  final List<Filament> filaments;

  const _FilamentChips({required this.filaments});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: filaments.map((f) {
        final grams = f.usedG == null ? null : '${f.usedG}g';
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: _colorFromHex(f.color),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey.shade300),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              [
                if (f.id != null) '#${f.id}',
                f.type,
                if (grams != null) grams,
              ].whereType<String>().join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        );
      }).toList(),
    );
  }
}

/// 单个打印盘：可点选；选中态高亮并打勾，其耗材将带入下一步。
class _PlateTile extends StatelessWidget {
  final Partition partition;
  final Map<String, Uint8List> images;
  final bool isSelected;
  final VoidCallback onTap;

  const _PlateTile({
    required this.partition,
    required this.images,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pic = partition.pics.isEmpty ? null : partition.pics.first;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.shade50 : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey.shade200,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            _PreviewBox(bytes: pic == null ? null : images[pic], size: 56),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Plate ${partition.id} · ${partition.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (partition.extras.bedType != null) partition.extras.bedType,
                      if (partition.filaments.isNotEmpty) '${partition.filaments.length} 色',
                      if (partition.weight != null) '${partition.weight}g',
                      if (partition.secs != null) '${partition.secs! ~/ 60}m',
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: isSelected ? Colors.blue : Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }
}

/// 预览图容器：有字节显示图片，否则降级图标。
class _PreviewBox extends StatelessWidget {
  final Uint8List? bytes;
  final double size;

  const _PreviewBox({this.bytes, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null
          ? Center(child: Icon(Icons.image, size: size * 0.3, color: Colors.grey.shade400))
          : Image.memory(
              bytes!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Center(child: Icon(Icons.broken_image, size: size * 0.3, color: Colors.grey.shade400)),
            ),
    );
  }
}

/// JSON 查看弹窗：等宽、可滚动、可复制。
class _JsonDialog extends StatelessWidget {
  final String title;
  final String json;

  const _JsonDialog({required this.title, required this.json});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Text(title, style: const TextStyle(fontSize: 16)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Scrollbar(
          thumbVisibility: true,
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
            ),
          ),
        ),
      ),
    );
  }
}

/// #RRGGBB / #AARRGGBB → [Color]，解析失败回退灰色。
Color _colorFromHex(String? hex) {
  if (hex == null || hex.isEmpty) return Colors.grey.shade400;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) {
    h = 'FF$h';
  } else if (h.length != 8) {
    return Colors.grey.shade400;
  }
  final v = int.tryParse(h, radix: 16);
  return v == null ? Colors.grey.shade400 : Color(v);
}
