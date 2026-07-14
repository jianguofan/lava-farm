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

/// 检测状态（results + images + inspecting + loading 合并为单一 state，避免分离字段的响应性问题）
class BedInspectionState {
  final Map<String, BedInspectionResult> results;
  final Map<String, Uint8List> images; // 抓取到的压缩图片字节，按 SN
  final Set<String> inspecting; // 正在检测中的 SN（逐台追踪，驱动单卡转圈）
  final bool isLoading;

  const BedInspectionState({
    this.results = const {},
    this.images = const {},
    this.inspecting = const {},
    this.isLoading = false,
  });

  BedInspectionState copyWith({
    Map<String, BedInspectionResult>? results,
    Map<String, Uint8List>? images,
    Set<String>? inspecting,
    bool? isLoading,
  }) {
    return BedInspectionState(
      results: results ?? this.results,
      images: images ?? this.images,
      inspecting: inspecting ?? this.inspecting,
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
  ///
  /// 逐台渐进刷新：进入即把所有待检测 SN 标为 inspecting（卡片立即转圈），
  /// 每台完成（成功/失败/跳过）经 onResult 回调立即回写结果并清掉该 SN 的转圈，
  /// 不再整批等待。检测不阻塞步骤推进——[canAdvanceTo] 仅看 selectedSns。
  Future<void> inspectAll() async {
    final service = _service;
    final store = _store;
    if (service == null || store == null) return;
    if (state.isLoading) return;

    final printers = store.allPrinters;
    // 与 service 内部过滤一致的谓词：仅在线且有有效 IP 的才会上报结果
    final pendingSns = printers
        .where((p) => p.isOnline && p.hasValidIp)
        .map((p) => p.sn)
        .toSet();

    state = state.copyWith(
      isLoading: true,
      inspecting: {...state.inspecting, ...pendingSns},
    );

    try {
      final (:results, :images) = await service.inspectAll(
        printers,
        onResult: (sn, result, imageBytes) {
          if (!mounted) return;
          final newResults =
              Map<String, BedInspectionResult>.from(state.results);
          final newImages = Map<String, Uint8List>.from(state.images);
          final newInspecting = Set<String>.from(state.inspecting)..remove(sn);
          if (result != null) newResults[sn] = result;
          if (imageBytes != null) newImages[sn] = imageBytes;
          state = state.copyWith(
            results: newResults,
            images: newImages,
            inspecting: newInspecting,
          );
        },
      );
      if (!mounted) return; // 页面已关闭，放弃更新
      // 兜底：onResult 已逐台清 inspecting，这里再清一次防漏，并合并聚合结果
      state = state.copyWith(
        results: {...state.results, ...results},
        images: {...state.images, ...images},
        inspecting: const <String>{},
        isLoading: false,
      );
    } catch (e, stack) {
      debugPrint('[BedInspectionNotifier] inspectAll 异常: $e');
      debugPrint('$stack');
      if (!mounted) return;
      state = state.copyWith(isLoading: false, inspecting: const <String>{});
    }
  }

  /// 检测单台打印机
  Future<void> inspectOne(String sn) async {
    final service = _service;
    final store = _store;
    if (service == null || store == null) return;

    final printer = store.getPrinter(sn);
    if (printer == null) return;

    state = state.copyWith(inspecting: {...state.inspecting, sn});
    try {
      final (:result, :imageBytes) = await service.inspectPrinter(printer);
      if (!mounted) return;
      final newResults = Map<String, BedInspectionResult>.from(state.results);
      final newImages = Map<String, Uint8List>.from(state.images);
      final newInspecting = Set<String>.from(state.inspecting)..remove(sn);
      if (result != null) newResults[sn] = result;
      if (imageBytes != null) newImages[sn] = imageBytes;
      state = state.copyWith(
        results: newResults,
        images: newImages,
        inspecting: newInspecting,
      );
    } catch (e) {
      debugPrint('[BedInspectionNotifier] inspectOne($sn) 失败: $e');
      if (!mounted) return;
      state = state.copyWith(
        inspecting: Set<String>.from(state.inspecting)..remove(sn),
      );
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

/// 单台打印机是否正在检测中（精确重建：仅该 SN 的 inspecting 翻转时重建对应卡片，
/// 不因其他打印机的开始/结束而重建）
final bedInspectionInspectingProvider =
    Provider.family<bool, String>((ref, sn) {
  return ref.watch(
      bedInspectionResultsProvider.select((s) => s.inspecting.contains(sn)));
});
