/// 产品中心页面
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/product_provider.dart';
import '../../domain/models/product_definition.dart';
import '../widgets/product_card.dart';

class ProductCenterPage extends ConsumerStatefulWidget {
  const ProductCenterPage({super.key});

  @override
  ConsumerState<ProductCenterPage> createState() => _ProductCenterPageState();
}

class _ProductCenterPageState extends ConsumerState<ProductCenterPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(productProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('产品中心'),
        actions: [
          FilledButton.icon(
            onPressed: _importProduct,
            icon: const Icon(Icons.upload_file),
            label: const Text('导入产品'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索产品名、机型',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          Expanded(
            child: productsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('产品库加载失败：$error')),
              data: (products) => _buildGrid(_filter(products)),
            ),
          ),
        ],
      ),
    );
  }

  List<ProductDefinition> _filter(List<ProductDefinition> products) {
    if (_query.isEmpty) return products;
    final q = _query.toLowerCase();
    return products.where((p) {
      return p.name.toLowerCase().contains(q) ||
          p.machineModel.toLowerCase().contains(q);
    }).toList();
  }

  Widget _buildGrid(List<ProductDefinition> products) {
    if (products.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('暂无产品定义'),
            const SizedBox(height: 8),
            Text(
              '导入 G-code 或 Gcode.3MF 后会生成产品卡片',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320,
        mainAxisExtent: 360,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: products.length,
      itemBuilder: (context, index) {
        final product = products[index];
        return ProductCard(
          product: product,
          onProduce: () => _openBatchPrint(product),
          onDelete: () => _confirmDelete(product),
        );
      },
    );
  }

  Future<void> _importProduct() async {
    const typeGroup = XTypeGroup(
      label: 'Printable files',
      extensions: ['gcode', 'g', '3mf'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;

    try {
      await ref.read(productProvider.notifier).importFile(File(file.path));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('产品导入完成')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('产品导入失败：$error')),
      );
    }
  }

  void _openBatchPrint(ProductDefinition product) {
    Navigator.pushNamed(context, '/batch-print', arguments: {
      'productId': product.id,
    });
  }

  Future<void> _confirmDelete(ProductDefinition product) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除产品'),
        content: Text('确认删除“${product.displayName}”？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(productProvider.notifier).delete(product.id);
    }
  }
}
