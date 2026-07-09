/// 投产历史 Providers
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/production_history_repository.dart';
import '../../domain/models/production_record.dart';

final productionHistoryRepositoryProvider =
    Provider<ProductionHistoryRepository>((ref) {
  return ProductionHistoryRepository();
});

final productionHistoryProvider =
    StateNotifierProvider<ProductionHistoryNotifier, AsyncValue<List<ProductionRecord>>>(
  (ref) => ProductionHistoryNotifier(
    ref.read(productionHistoryRepositoryProvider),
  )..load(),
);

class ProductionHistoryNotifier
    extends StateNotifier<AsyncValue<List<ProductionRecord>>> {
  final ProductionHistoryRepository _repository;

  ProductionHistoryNotifier(this._repository)
      : super(const AsyncValue.loading());

  Future<void> load() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_repository.loadAll);
  }

  Future<void> add(ProductionRecord record) async {
    await _repository.add(record);
    await load();
  }

  Future<void> clear() async {
    await _repository.clear();
    await load();
  }
}
