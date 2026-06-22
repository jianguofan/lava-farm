/// FarmHub — 群控系统入口 (T3.2)
///
/// 一站式生命周期管理:
///   start()     → 连接 Broker → 加载注册表 → 启动监控
///   discover()  → 扫描局域网打印机
///   onboard()   → 单台打印机入网（验证 → 配置推送 → 注册）
///   shutdown()  → 停止监控 → 断开 Broker → 持久化

import 'dart:async';

import 'broker_connection_manager.dart';
import 'config_push_service.dart';
import 'credential_store.dart';
import 'farm_connection_monitor.dart';
import 'farm_store.dart';
import 'printer_discovery.dart';
import 'printer_info.dart';

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

/// FarmHub — 群控系统总入口
class FarmHub {
  final FarmStore store;
  final BrokerConnectionManager brokerConnMgr;
  final PrinterDiscovery discovery;
  final CredentialStore credentialStore;

  // 运行时组件（start 后初始化）
  FarmConnectionMonitor? connectionMonitor;
  BrokerHealthMonitor? brokerHealthMonitor;
  Timer? _upgradeTimer; // HTTP 降级后台升级重试

  /// 当前 Broker 连接配置
  BrokerConfig? _brokerConfig;

  FarmHub({
    required this.store,
    required this.brokerConnMgr,
    required this.discovery,
    required this.credentialStore,
  });

  bool get isRunning => brokerConnMgr.isConnected;

  // ═══════════════════════════════════════════════════════════
  // 生命周期
  // ═══════════════════════════════════════════════════════════

  /// 启动群控系统
  ///
  /// 1. 连接 Broker（外部或内嵌）
  /// 2. 加载已注册打印机
  /// 3. 启动监控
  Future<void> start({required BrokerConfig brokerConfig}) async {
    _brokerConfig = brokerConfig;

    // 1. 连接到 Broker
    await brokerConnMgr.connect(
      host: brokerConfig.host,
      port: brokerConfig.port,
      username: brokerConfig.username,
      password: brokerConfig.password,
    );

    // 2. 加载已注册打印机（从 Hive）
    // final saved = await PrinterRegistry.loadAll();
    // store.loadFromRegistry(saved);

    // 3. 启动连接监控
    connectionMonitor = FarmConnectionMonitor(
      onForceOffline: (sn, reason) => store.forceOffline(sn, reason),
    );
    connectionMonitor!.start();

    // 4. 启动 Broker 健康监控
    brokerHealthMonitor = BrokerHealthMonitor(
      pingFn: () => brokerConnMgr.ping(),
      onUnhealthy: () {
        // Broker 假活 → 触发重连
        // brokerConnMgr.disconnect() 后会自动重连
      },
    );
    brokerHealthMonitor!.start();

    // 5. 启动 HTTP 降级后台升级（每 5min 重试推送 MQTT 配置）
    _startUpgradeRetries();
  }

  /// 关闭群控系统
  Future<void> shutdown() async {
    _upgradeTimer?.cancel();
    connectionMonitor?.stop();
    brokerHealthMonitor?.stop();
    await brokerConnMgr.disconnect();

    // 持久化
    // await PrinterRegistry.save(store.exportToRegistry());
  }

  // ═══════════════════════════════════════════════════════════
  // 打印机发现
  // ═══════════════════════════════════════════════════════════

  /// 扫描局域网打印机
  Future<List<DiscoveredPrinter>> discover() async {
    final mdns = await discovery.discoverMdns();
    final subnet = await PrinterDiscovery.detectSubnet();
    List<DiscoveredPrinter> tcp = [];
    if (subnet != null) {
      tcp = await discovery.discoverTcp(subnet: subnet);
    }
    return PrinterDiscovery.merge(mdns, tcp);
  }

  // ═══════════════════════════════════════════════════════════
  // 打印机入网
  // ═══════════════════════════════════════════════════════════

  /// 单台打印机入网
  ///
  /// 完整流程:
  ///   1. 验证 Access Code
  ///   2. 获取设备信息
  ///   3. 检查打印机状态（打印中则警告）
  ///   4. 生成 MQTT 凭据
  ///   5. 推送配置到打印机
  ///   6. 等待 MQTT 上线
  ///   7. 注册到 FarmStore + 持久化
  Future<OnboardingResult> onboard({
    required String ip,
    required int port,
    required String accessCode,
  }) async {
    if (_brokerConfig == null) {
      return OnboardingResult.pushFailed('Broker 尚未连接');
    }

    final configPusher = ConfigPushService(printerIp: ip, printerPort: port);

    try {
      // Step 1: 登录验证
      final token = await configPusher.login(accessCode);
      if (token == null) return OnboardingResult.authFailed();

      // Step 2: 获取设备信息
      final info = await configPusher.getServerInfo();
      if (info == null) return OnboardingResult.pushFailed('无法获取设备信息');
      final sn = info.instanceName;

      // Step 3: 打印中状态检查
      if (info.isPrinting) {
        // 返回特殊结果，由 UI 弹窗确认
        return OnboardingResult.printingBlocked(sn);
      }

      // Step 4: 生成 MQTT 凭据
      final mqttPassword = CredentialStore.generatePrinterPassword(sn);
      await credentialStore.savePrinterCredential(
        sn: sn,
        username: 'printer_$sn',
        password: mqttPassword,
      );

      // Step 5: 推送配置
      final mqttConfig = MqttConfig(
        brokerAddress: _brokerConfig!.host,
        brokerPort: _brokerConfig!.port,
        username: 'printer_$sn',
        password: mqttPassword,
        instanceName: sn,
      );

      final result = await configPusher.onboard(
        accessCode: accessCode,
        mqttConfig: mqttConfig,
        // waitForMqttOnline 由 FarmMqttRouter 提供（Phase 5）
      );

      // Step 6: 注册到系统
      store.onPrinterRegistered(PrinterInfo(
        sn: sn,
        ip: ip,
        port: port,
        source: result.resultingSource,
        model: info.model,
        firmwareVersion: info.version,
        apiKey: token,
      ));

      // Step 7: 持久化
      // await PrinterRegistry.save(store.exportToRegistry());

      return OnboardingResult.success(sn: sn, source: result.resultingSource);

    } catch (e) {
      return OnboardingResult.pushFailed('入网异常: $e');
    } finally {
      configPusher.dispose();
    }
  }

  /// 移除打印机
  void removePrinter(String sn) {
    store.onPrinterRemoved(sn);
    connectionMonitor?.remove(sn);
    // await PrinterRegistry.save(store.exportToRegistry());
  }

  // ═══════════════════════════════════════════════════════════
  // HTTP 降级后台升级
  // ═══════════════════════════════════════════════════════════

  /// 后台周期性重试 HTTP 降级的打印机，尝试升级到 MQTT
  void _startUpgradeRetries() {
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      final httpPrinters = store.httpFallbackPrinters;
      for (final printer in httpPrinters) {
        try {
          // 重新尝试推送 MQTT 配置
          final configPusher = ConfigPushService(
            printerIp: printer.ip,
            printerPort: printer.port,
          );

          final mqttPassword = CredentialStore.generatePrinterPassword(printer.sn);
          final mqttConfig = MqttConfig(
            brokerAddress: _brokerConfig?.host ?? '',
            brokerPort: _brokerConfig?.port ?? 1883,
            username: 'printer_${printer.sn}',
            password: mqttPassword,
            instanceName: printer.sn,
          );

          // 使用空字符串作为 apiKey（打印机已入网，无需再次验证）
          final result = await configPusher.onboard(
            accessCode: '',
            mqttConfig: mqttConfig,
          );

          if (result.success) {
            // 升级成功！标记为 MQTT 来源
            store.onPrinterRegistered(PrinterInfo(
              sn: printer.sn,
              ip: printer.ip,
              port: printer.port,
              source: Source.mqtt,
              displayName: printer.displayName,
              model: printer.model,
              firmwareVersion: printer.firmwareVersion,
            ));
          }

          configPusher.dispose();
        } catch (_) {
          // 单台失败不阻塞，下次重试
        }
      }
    });
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await shutdown();
    store.dispose();
  }
}
