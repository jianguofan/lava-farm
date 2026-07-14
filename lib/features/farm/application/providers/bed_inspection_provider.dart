/// 床板异物检测 Providers
///
/// bedInspectionServiceProvider    — 检测服务（依赖 MQTT router）
/// bedInspectionResultsProvider    — 检测结果 + loading 状态
library bed_inspection_provider;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bed_inspection_service.dart';
import '../../data/farm_store.dart';
import '../../domain/models/bed_inspection_result.dart';
import 'broker_state_provider.dart';

/// 检测服务 Provider
final bedInspectionServiceProvider = Provider<BedInspectionService?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  if (router == null) return null;
  return BedInspectionService(router: router);
});

/// 检测状态（results + images + loading 合并为单一 state，避免分离字段的响应性问题）
class BedInspectionState {
  final Map<String, BedInspectionResult> results;
  final Map<String, Uint8List> images; // 抓取到的压缩图片字节，按 SN
  final bool isLoading;

  const BedInspectionState({
    this.results = const {},
    this.images = const {},
    this.isLoading = false,
  });

  BedInspectionState copyWith({
    Map<String, BedInspectionResult>? results,
    Map<String, Uint8List>? images,
    bool? isLoading,
  }) {
    return BedInspectionState(
      results: results ?? this.results,
      images: images ?? this.images,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// 检测结果 Notifier
class BedInspectionNotifier extends StateNotifier<BedInspectionState> {
  final BedInspectionService? _service;
  final FarmStore? _store;

  BedInspectionNotifier(this._service, this._store)
      : super(const BedInspectionState());

  /// 检测所有在线打印机
  Future<void> inspectAll() async {
    final service = _service;
    final store = _store;
    if (service == null || store == null) return;
    if (state.isLoading) return;

    state = state.copyWith(isLoading: true);
    try {
      final printers = store.allPrinters;
      final (:results, :images) = await service.inspectAll(printers);
      if (!mounted) return; // 页面已关闭，放弃更新
      state = state.copyWith(
        results: {...state.results, ...results},
        images: {...state.images, ...images},
        isLoading: false,
      );
    } catch (e, stack) {
      debugPrint('[BedInspectionNotifier] inspectAll 异常: $e');
      debugPrint('$stack');
      if (!mounted) return;
      state = state.copyWith(isLoading: false);
    }
  }

  /// 检测单台打印机
  Future<void> inspectOne(String sn) async {
    final service = _service;
    final store = _store;
    if (service == null || store == null) return;

    final printer = store.getPrinter(sn);
    if (printer == null) return;

    try {
      final (:result, :imageBytes) = await service.inspectPrinter(printer);
      if (!mounted) return;
      final newResults = Map<String, BedInspectionResult>.from(state.results);
      final newImages = Map<String, Uint8List>.from(state.images);
      if (result != null) newResults[sn] = result;
      if (imageBytes != null) newImages[sn] = imageBytes;
      state = state.copyWith(results: newResults, images: newImages);
    } catch (e) {
      debugPrint('[BedInspectionNotifier] inspectOne($sn) 失败: $e');
    }
  }

  /// 清空所有检测结果
  void clear() {
    state = const BedInspectionState();
  }
}

/// 检测结果 Provider（state 包含 results + isLoading）
final bedInspectionResultsProvider =
    StateNotifierProvider<BedInspectionNotifier, BedInspectionState>((ref) {
  final service = ref.watch(bedInspectionServiceProvider);
  final store = ref.watch(farmStoreProvider);
  return BedInspectionNotifier(service, store);
});

/// 是否正在检测中（精确选择，避免不必要的重建）
final bedInspectionLoadingProvider = Provider<bool>((ref) {
  return ref.watch(bedInspectionResultsProvider).isLoading;
});

/// 检测结果 Map（精确选择）
final bedInspectionResultsMapProvider =
    Provider<Map<String, BedInspectionResult>>((ref) {
  return ref.watch(bedInspectionResultsProvider).results;
});

/// 抓取到的图片 Map（按 SN，精确选择）
final bedInspectionImagesProvider = Provider<Map<String, Uint8List>>((ref) {
  return ref.watch(bedInspectionResultsProvider).images;
});

/// 单台打印机的检测结果（精确重建，不会因其他打印机变化而重建）
final bedInspectionResultProvider =
    Provider.family<BedInspectionResult?, String>((ref, sn) {
  final results = ref.watch(bedInspectionResultsMapProvider);
  return results[sn];
});
