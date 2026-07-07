/// 打印机列表 Providers
///
/// 从 FarmStore 派生各种视图: 全部/打印中/离线/HTTP降级/统计。
/// 通过 farmStoreVersionProvider 感知变化，无需中间 StateNotifier。
///
/// 设计原则:
///   - 唯一数据源: farmStoreProvider (FarmStore 实例)
///   - 变更通知: farmStoreVersionProvider (int 版本号)
///   - 派生视图: 以下所有 Provider 都是纯派生，无独立状态

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/farm_printer_state.dart';
import 'broker_state_provider.dart';

// ═══════════════════════════════════════════════════════════
// 基础: 监听版本号 → 读取全部打印机
// ═══════════════════════════════════════════════════════════

/// 全部打印机列表（按 SN 排序）
///
/// 这是所有派生 Provider 的基础。
/// 每次 FarmStore 变更（版本号递增）都会触发重建。
final printerListProvider = Provider<List<FarmPrinterState>>((ref) {
  // 监听版本号 → FarmStore 每次批处理通知后触发此 Provider 重建
  ref.watch(farmStoreVersionProvider);
  // 读取最新数据
  final store = ref.read(farmStoreProvider);
  final printers = store.allPrinters.toList();
  printers.sort((a, b) => a.sn.compareTo(b.sn));
  return printers;
});

// ═══════════════════════════════════════════════════════════
// 派生: 按状态筛选
// ═══════════════════════════════════════════════════════════

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

/// 在线且 MQTT 通道的打印机
final mqttOnlinePrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider)
      .where((p) => p.isOnline && p.isMqtt)
      .toList();
});

// ═══════════════════════════════════════════════════════════
// 农场统计数据
// ═══════════════════════════════════════════════════════════

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

/// 过期设备数量（离线超过 24 小时）
final expiredPrinterCountProvider = Provider<int>((ref) {
  ref.watch(farmStoreVersionProvider);
  final store = ref.read(farmStoreProvider);
  return store.expiredCount;
});

/// 过期设备列表（离线超过 24 小时）
final expiredPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  ref.watch(farmStoreVersionProvider);
  final store = ref.read(farmStoreProvider);
  return store.getExpiredPrinters(const Duration(hours: 24));
});
