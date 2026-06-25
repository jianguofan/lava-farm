/// 打印机状态机 — 领域服务（纯逻辑，无副作用）
///
/// 职责:
/// - 检测打印状态转换（standby → printing → paused → complete → error）
/// - 判断是否需要创建快照
/// - 自动注册新设备判定
/// - 时间戳保护逻辑
///
/// 所有方法都是纯函数，不依赖任何外部状态，易于单元测试。

import '../../data/farm_printer_state.dart';
import '../../data/printer_info.dart';

/// 打印机状态机 — 提取自 FarmStore 的业务逻辑
class PrinterStateMachine {
  /// 判断是否应该自动注册新设备
  static bool shouldAutoRegister(
    String sn,
    Map<String, FarmPrinterState> existingPrinters,
  ) {
    return !existingPrinters.containsKey(sn);
  }

  /// 检测打印状态转换，返回需要创建的快照列表
  static List<FarmSnapshot> detectTransitions({
    required String sn,
    required Map<String, dynamic> status,
    required FarmPrinterState? previousState,
    required DateTime now,
    required bool isNewDevice,
    required bool wasOffline,
  }) {
    final snapshots = <FarmSnapshot>[];

    // 新设备首次出现
    if (isNewDevice) {
      snapshots.add(FarmSnapshot(
        timestamp: now,
        reason: '设备自动发现',
        context: '首次通过 MQTT 状态消息发现设备',
        data: {'sn': sn},
      ));
    }

    // 从离线恢复
    if (wasOffline) {
      snapshots.add(FarmSnapshot(
        timestamp: now,
        reason: '设备上线',
        context: 'MQTT 状态消息到达，设备恢复在线',
        data: {'sn': sn},
      ));
    }

    // 打印状态变更
    if (previousState != null) {
      final previousPrintState = previousState.printState?.value;
      final currentPrintState = status['print_stats.state'] as String?;

      if (previousPrintState != null &&
          currentPrintState != null &&
          previousPrintState != currentPrintState) {
        snapshots.add(FarmSnapshot(
          timestamp: now,
          reason: '打印状态变更',
          context: '$previousPrintState → $currentPrintState',
          data: {
            'from': previousPrintState,
            'to': currentPrintState,
          },
        ));
      }
    }

    return snapshots;
  }

  /// 时间戳保护：MQTT 消息可能乱序到达
  static bool isTimestampValid(
    DateTime? eventTime,
    DateTime? lastDataTimestamp,
  ) {
    if (eventTime == null || lastDataTimestamp == null) return true;
    return eventTime.isAfter(lastDataTimestamp);
  }

  /// 创建离线快照
  static FarmSnapshot createOfflineSnapshot({
    required DateTime now,
    required String reason,
    Map<String, dynamic>? previousState,
  }) {
    return FarmSnapshot(
      timestamp: now,
      reason: reason,
      data: {'previousState': previousState},
    );
  }

  /// 创建批量操作失败快照
  static FarmSnapshot createBatchFailureSnapshot({
    required DateTime now,
    required String operation,
    String? error,
  }) {
    return FarmSnapshot(
      timestamp: now,
      reason: 'batch_${operation}_failed',
      context: error,
      data: {'operation': operation},
    );
  }

  /// 自动生成打印机的默认显示名（用 SN 后 6 位）
  static String defaultDisplayName(String sn) {
    return sn.length >= 6 ? sn.substring(sn.length - 6) : sn;
  }

  /// 创建自动发现的 PrinterInfo
  static PrinterInfo createAutoDiscoveredInfo(String sn) {
    return PrinterInfo(
      sn: sn,
      displayName: defaultDisplayName(sn),
      ip: 'MQTT',
      port: 7125,
      source: Source.mqtt,
    );
  }

  /// 判断打印状态是否为打印中
  static bool isPrintingState(String? state) => state == 'printing';

  /// 判断打印状态是否为暂停
  static bool isPausedState(String? state) => state == 'paused';

  /// 判断是否应从已有的打印相关状态清理
  static bool shouldClearPrintFields(String? newState) {
    return newState != null &&
        newState != 'printing' &&
        newState != 'paused';
  }
}
