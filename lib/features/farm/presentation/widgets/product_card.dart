/// 产品卡片
import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/models/product_definition.dart';

class ProductCard extends StatelessWidget {
  final ProductDefinition product;
  final VoidCallback? onProduce;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const ProductCard({
    super.key,
    required this.product,
    this.onProduce,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onProduce,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildThumbnail()),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          product.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _InfoGrid(product: product),
                  const SizedBox(height: 8),
                  _MaterialChips(product: product),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: onProduce,
                          icon: const Icon(Icons.send, size: 16),
                          label: const Text('投产'),
                        ),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') onEdit?.call();
                          if (value == 'delete') onDelete?.call();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    final path = product.thumbnailPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(File(path), fit: BoxFit.cover);
    }
    return Container(
      color: Colors.grey.shade100,
      child: Center(
        child: Text(
          'basicsoft',
          style: TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w800,
            fontStyle: FontStyle.italic,
            shadows: [Shadow(color: Colors.grey.shade300, blurRadius: 1)],
          ),
        ),
      ),
    );
  }
}

class _InfoGrid extends StatelessWidget {
  final ProductDefinition product;

  const _InfoGrid({required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(children: [
            Expanded(child: _Info(label: '机台型号', value: product.machineModel)),
            Expanded(child: _Info(label: '生产时长', value: _formatDuration(product.estimatedDuration))),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: _Info(label: '物料总重', value: '${product.totalFilamentGrams.toStringAsFixed(1)}g')),
            Expanded(child: _Info(label: '单盘数量', value: '${product.plateQuantity}')),
          ]),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    if (duration == Duration.zero) return '待补全';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) return '${hours}h${minutes}m';
    return '${minutes}m';
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

class _MaterialChips extends StatelessWidget {
  final ProductDefinition product;

  const _MaterialChips({required this.product});

  @override
  Widget build(BuildContext context) {
    if (product.materials.isEmpty) {
      return Text('耗材待补全', style: TextStyle(fontSize: 12, color: Colors.grey.shade500));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: product.materials.map((m) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Color(m.argb),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey.shade300),
              ),
            ),
            const SizedBox(width: 4),
            Text('${m.grams.toStringAsFixed(1)}g', style: const TextStyle(fontSize: 12)),
          ],
        );
      }).toList(),
    );
  }
}
