/// 床板异物检测 Providers
///
/// bedInspectionServiceProvider    — 检测服务（依赖 MQTT router）
/// bedInspectionResultsProvider    — 检测结果 Map<SN, BedInspectionResult>
/// bedInspectionLoadingProvider    — 是否正在检测中
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

/// 检测结果 Notifier
class BedInspectionNotifier
    extends StateNotifier<Map<String, BedInspectionResult>> {
  final BedInspectionService? _service;
  final FarmStore? _store;

  BedInspectionNotifier(this._service, this._store) : super({});

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  /// 检测所有在线打印机
  Future<void> inspectAll() async {
    final service = _service;
    final store = _store;
    if (service == null || store == null) return;
    if (_isLoading) return;

    _isLoading = true;
    try {
      final printers = store.allPrinters;
      final results = await service.inspectAll(printers, concurrency: 3);
      state = {...state, ...results};
    } catch (e, stack) {
      debugPrint('[BedInspectionNotifier] inspectAll 异常: $e');
      debugPrint('$stack');
    } finally {
      _isLoading = false;
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
      final result = await service.inspectPrinter(printer);
      if (result != null) {
        state = {...state, sn: result};
      }
    } catch (e) {
      debugPrint('[BedInspectionNotifier] inspectOne($sn) 失败: $e');
    }
  }

  /// 清空所有检测结果
  void clear() {
    state = {};
  }
}

/// 检测结果 Provider
final bedInspectionResultsProvider = StateNotifierProvider<
    BedInspectionNotifier, Map<String, BedInspectionResult>>((ref) {
  final service = ref.watch(bedInspectionServiceProvider);
  final store = ref.watch(farmStoreProvider);
  return BedInspectionNotifier(service, store);
});

/// 是否正在检测中
final bedInspectionLoadingProvider = Provider<bool>((ref) {
  final notifier = ref.watch(bedInspectionResultsProvider.notifier);
  return notifier.isLoading;
});

/// 单台打印机的检测结果（精确重建）
final bedInspectionResultProvider =
    Provider.family<BedInspectionResult?, String>((ref, sn) {
  final results = ref.watch(bedInspectionResultsProvider);
  return results[sn];
});
