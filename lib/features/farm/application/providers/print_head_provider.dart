/// 打印头预设 Providers
///
/// 风格与 [productProvider] / [productionHistoryProvider] 一致：
/// StateNotifierProvider<_, AsyncValue<List<_>>> + 派生 *ListProvider。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/print_head_repository.dart';
import '../../domain/models/print_head.dart';

final printHeadRepositoryProvider = Provider<PrintHeadRepository>((ref) {
  return PrintHeadRepository();
});

final printHeadProvider =
    StateNotifierProvider<PrintHeadNotifier, AsyncValue<List<PrintHead>>>(
  (ref) => PrintHeadNotifier(ref.read(printHeadRepositoryProvider))..load(),
);

/// 解包后的打印头列表（加载中/失败返回默认 4 头，保证 UI 永远有值可用）。
final printHeadListProvider = Provider<List<PrintHead>>((ref) {
  final async = ref.watch(printHeadProvider);
  return async.value ?? PrintHeadRepository.defaultHeads();
});

class PrintHeadNotifier extends StateNotifier<AsyncValue<List<PrintHead>>> {
  final PrintHeadRepository _repository;

  PrintHeadNotifier(this._repository) : super(const AsyncValue.loading());

  Future<void> load() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_repository.loadAll);
  }

  /// 更新指定 1-based 编号的打印头。
  Future<void> updateHead(int index, PrintHead head) async {
    final list = (state.value ?? PrintHeadRepository.defaultHeads())
        .map((h) => h.index == index ? head : h)
        .toList();
    await _repository.saveAll(list);
    state = AsyncValue.data(list);
  }

  /// 整体替换（保持顺序）。
  Future<void> replace(List<PrintHead> heads) async {
    await _repository.saveAll(heads);
    state = AsyncValue.data(heads);
  }

  /// 恢复默认 4 头。
  Future<void> resetDefault() async {
    final defaults = PrintHeadRepository.defaultHeads();
    await _repository.saveAll(defaults);
    state = AsyncValue.data(defaults);
  }
}
