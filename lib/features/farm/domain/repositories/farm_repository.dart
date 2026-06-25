/// 群控仓储接口 — 领域层抽象
///
/// 定义群控系统的所有数据操作契约。
/// 具体实现在 data/repositories/farm_repository_impl.dart 中，
/// 组合 MQTT + HTTP 数据源，实现此接口。
///
/// 使用此接口的好处:
/// - FarmHub 等应用服务依赖抽象而非具体实现
/// - 单元测试时可以直接 mock
/// - 未来切换通信方式不需要改上层代码

import '../../data/broker_connection_manager.dart';
import '../../data/farm_command_gateway.dart';
import '../../data/farm_printer_state.dart';
import '../../data/printer_discovery.dart';
import '../../data/printer_info.dart';

/// 打印机事件流 — 从 MQTT/HTTP 数据源聚合后的统一事件
enum PrinterEventType { statusUpdate, notification, offline, online }

class PrinterEvent {
  final String sn;
  final PrinterEventType type;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  const PrinterEvent({
    required this.sn,
    required this.type,
    this.data,
    required this.timestamp,
  });
}

/// 入网结果
class OnboardingResult {
  final bool success;
  final String? sn;
  final Source? source;
  final String? error;

  const OnboardingResult._({
    required this.success,
    this.sn,
    this.source,
    this.error,
  });

  factory OnboardingResult.success({required String sn, required Source source}) =>
      OnboardingResult._(success: true, sn: sn, source: source);

  factory OnboardingResult.authFailed() =>
      OnboardingResult._(success: false, error: 'Access Code 验证失败');

  factory OnboardingResult.pushFailed(String reason) =>
      OnboardingResult._(success: false, error: reason);

  factory OnboardingResult.printingBlocked(String sn) =>
      OnboardingResult._(success: false, sn: sn, error: '打印机正在打印中，操作被用户取消');
}

/// 群控仓储接口
///
/// 所有对打印机群的操作都通过此接口，屏蔽 MQTT/HTTP 的差异。
abstract class FarmRepository {
  // ── 连接管理 ──

  /// 连接到 MQTT Broker
  Future<void> connect(BrokerConfig config);

  /// 断开连接
  Future<void> disconnect();

  /// 是否已连接
  bool get isConnected;

  /// Broker 连接状态流
  Stream<BrokerConnState> get brokerStateStream;

  // ── 设备管理 ──

  /// 获取单台打印机状态
  FarmPrinterState? getPrinter(String sn);

  /// 获取全部打印机
  List<FarmPrinterState> get allPrinters;

  /// 注册打印机
  void registerPrinter(PrinterInfo info);

  /// 移除打印机
  void removePrinter(String sn);

  // ── 命令 ──

  /// 向单台打印机发送命令
  Future<CommandResult> sendCommand(
    String sn,
    String method, [
    Map<String, dynamic>? params,
  ]);

  /// 向多台打印机发送命令
  BatchHandle sendToMany({
    required List<String> sns,
    required String method,
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
    int maxConcurrency = 20,
  });

  // ── 发现 ──

  /// 扫描局域网打印机
  Future<List<DiscoveredPrinter>> discover();

  // ── 入网 ──

  /// 单台打印机入网（验证 → 配置推送 → 注册）
  Future<OnboardingResult> onboard({
    required String ip,
    required int port,
    required String accessCode,
    BrokerConfig? brokerConfig,
  });

  // ── 生命周期 ──

  /// 释放所有资源
  Future<void> dispose();
}
