/// 打印机列表 Providers (T4.3)
///
/// 从 FarmStore 派生各种视图: 全部/打印中/离线/HTTP降级/统计
/// 使用 FarmPrinterState（farm_printer_state.dart）作为统一状态模型。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/farm_printer_state.dart';

// ═══════════════════════════════════════════════════════════
// 核心 Store
// ═══════════════════════════════════════════════════════════

/// 打印机注册表 — 持有 Map<SN, FarmPrinterState>
class PrinterRegistryNotifier
    extends StateNotifier<Map<String, FarmPrinterState>> {
  PrinterRegistryNotifier() : super({});

  void addPrinter(FarmPrinterState printer) {
    state = {...state, printer.sn: printer};
  }

  void removePrinter(String sn) {
    state = Map.from(state)..remove(sn);
  }

  void updatePrinter(
    String sn,
    FarmPrinterState Function(FarmPrinterState) updateFn,
  ) {
    final current = state[sn];
    if (current == null) return;
    state = {...state, sn: updateFn(current)};
  }

  FarmPrinterState? getPrinter(String sn) => state[sn];
  List<FarmPrinterState> get allPrinters => state.values.toList();
}

// ═══════════════════════════════════════════════════════════
// Providers
// ═══════════════════════════════════════════════════════════

/// 打印机注册表 Provider
final printerRegistryProvider =
    StateNotifierProvider<PrinterRegistryNotifier,
        Map<String, FarmPrinterState>>((ref) {
  return PrinterRegistryNotifier();
});

/// 全部打印机列表（按 SN 排序）
final printerListProvider = Provider<List<FarmPrinterState>>((ref) {
  final registry = ref.watch(printerRegistryProvider);
  final printers = registry.values.toList();
  printers.sort((a, b) => a.sn.compareTo(b.sn));
  return printers;
});

/// 打印中的打印机
final printingPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isPrinting).toList();
});

/// 离线打印机
final offlinePrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => !p.isOnline).toList();
});

/// HTTP 降级打印机
final httpFallbackPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isHttp).toList();
});

/// 农场统计数据
class FarmStats {
  final int total;
  final int online;
  final int printing;
  final int mqttCount;
  final int httpCount;

  const FarmStats({
    required this.total,
    required this.online,
    required this.printing,
    required this.mqttCount,
    required this.httpCount,
  });

  double get onlineRate => total > 0 ? online / total : 0.0;
}

final farmStatsProvider = Provider<FarmStats>((ref) {
  final printers = ref.watch(printerListProvider);
  return FarmStats(
    total: printers.length,
    online: printers.where((p) => p.isOnline).length,
    printing: printers.where((p) => p.isPrinting).length,
    mqttCount: printers.where((p) => p.isMqtt).length,
    httpCount: printers.where((p) => p.isHttp).length,
  );
});
