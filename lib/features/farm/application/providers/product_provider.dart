/// 产品库 Providers
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/product_repository.dart';
import '../../domain/models/product_definition.dart';

final productRepositoryProvider = Provider<ProductRepository>((ref) {
  return ProductRepository();
});

final productProvider =
    StateNotifierProvider<ProductNotifier, AsyncValue<List<ProductDefinition>>>(
  (ref) => ProductNotifier(ref.read(productRepositoryProvider))..load(),
);

final productListProvider = Provider<List<ProductDefinition>>((ref) {
  return ref.watch(productProvider).value ?? const [];
});

class ProductNotifier extends StateNotifier<AsyncValue<List<ProductDefinition>>> {
  final ProductRepository _repository;

  ProductNotifier(this._repository) : super(const AsyncValue.loading());

  Future<void> load() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_repository.loadAll);
  }

  Future<void> importFile(File file) async {
    await _repository.importFile(file);
    await load();
  }

  Future<void> upsert(ProductDefinition product) async {
    await _repository.upsert(product);
    await load();
  }

  Future<void> delete(String id) async {
    await _repository.delete(id);
    await load();
  }
}
