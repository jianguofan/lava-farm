/// FarmHub — 群控系统入口（应用层编排服务）
///
/// 一站式生命周期管理:
///   start()     → 连接 Broker → 加载注册表 → 启动监控
///   discover()  → 扫描局域网打印机
///   onboard()   → 单台打印机入网（验证 → 配置推送 → 注册）
///   shutdown()  → 停止监控 → 断开 Broker → 持久化
///
/// 依赖 FarmRepository 接口（领域层抽象），不直接依赖具体数据源。

import 'dart:async';

import '../../data/broker_connection_manager.dart';
import '../../data/broker_user_manager.dart';
import '../../data/config_push_service.dart';
import '../../data/credential_store.dart';
import '../../data/farm_connection_monitor.dart';
import '../../data/farm_store.dart';
import '../../data/printer_discovery.dart';
import '../../data/printer_info.dart';
import '../../domain/repositories/farm_repository.dart';

/// FarmHub — 群控系统总入口
class FarmHub {
  final FarmStore store;
  final BrokerConnectionManager brokerConnMgr;
  final PrinterDiscovery discovery;
  final CredentialStore credentialStore;

  // 运行时组件（start 后初始化）
  FarmConnectionMonitor? connectionMonitor;
  BrokerHealthMonitor? brokerHealthMonitor;
  BrokerUserManager? _brokerUserMgr;
  Timer? _upgradeTimer;

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
  Future<void> start({required BrokerConfig brokerConfig}) async {
    _brokerConfig = brokerConfig;

    // 1. 连接到 Broker
    await brokerConnMgr.connect(
      host: brokerConfig.host,
      port: brokerConfig.port,
      username: brokerConfig.username,
      password: brokerConfig.password,
    );

    // 1.5 初始化 Broker 用户管理器（Dynamic Security API）
    final transport = brokerConnMgr.transport;
    if (transport != null) {
      _brokerUserMgr = BrokerUserManager(transport: transport);
      await _brokerUserMgr!.init();
    }

    // 2. 启动连接监控（被动心跳 — 靠 MQTT 消息流驱动）
    connectionMonitor = FarmConnectionMonitor(
      onForceOffline: (sn, reason) => store.forceOffline(sn, reason),
    );
    store.onHeartbeat = (sn) => connectionMonitor!.heartbeat(sn);
    connectionMonitor!.start();

    // 3. 启动 Broker 健康监控
    brokerHealthMonitor = BrokerHealthMonitor(
      pingFn: () => brokerConnMgr.ping(),
      onUnhealthy: () {},
    );
    brokerHealthMonitor!.start();

    // 4. 启动 HTTP 降级后台升级（每 5min 重试推送 MQTT 配置）
    _startUpgradeRetries();
  }

  /// 关闭群控系统
  Future<void> shutdown() async {
    _upgradeTimer?.cancel();
    connectionMonitor?.stop();
    brokerHealthMonitor?.stop();
    _brokerUserMgr?.dispose();
    _brokerUserMgr = null;
    await brokerConnMgr.disconnect();
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
  Future<OnboardingResult> onboard({
    required String ip,
    required int port,
    required String accessCode,
    BrokerConfig? brokerConfig,
  }) async {
    final effectiveConfig = brokerConfig ?? _brokerConfig;
    if (effectiveConfig == null) {
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
        return OnboardingResult.printingBlocked(sn);
      }

      // Step 4: 生成 MQTT 凭据
      final mqttPassword = CredentialStore.generatePrinterPassword(sn);
      await credentialStore.savePrinterCredential(
        sn: sn,
        username: 'printer_$sn',
        password: mqttPassword,
      );

      // Step 4.5: 在 Broker 上创建打印机用户（Dynamic Security）
      // 必须在推送配置之前执行，否则打印机连接时 Broker 不认凭据
      if (_brokerUserMgr != null) {
        final userResult = await _brokerUserMgr!.createPrinterUser(
          sn: sn,
          password: mqttPassword,
        );
        if (!userResult.success) {
          print('[FarmHub] ⚠️ 创建 Broker 用户失败: ${userResult.error}，继续尝试入网...');
          // 不阻断入网流程 — 用户可能已存在（重试场景）
        }
      }

      // Step 5: 推送配置
      final mqttConfig = MqttConfig(
        brokerAddress: effectiveConfig.host,
        brokerPort: effectiveConfig.port,
        username: 'printer_$sn',
        password: mqttPassword,
        instanceName: sn,
      );

      final result = await configPusher.onboard(
        accessCode: accessCode,
        mqttConfig: mqttConfig,
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

    // 从 Broker 删除打印机用户（fire-and-forget）
    if (_brokerUserMgr != null) {
      _brokerUserMgr!.deletePrinterUser(sn).then((result) {
        if (!result.success) {
          print('[FarmHub] ⚠️ 删除 Broker 用户 $sn 失败: ${result.error}');
        }
      });
    }

    // 清理本地存储的凭据
    credentialStore.removePrinterCredential(sn);
  }

  /// 批量删除过期设备（离线超过 [threshold] 的设备）
  ///
  /// 返回被删除的设备 SN 列表。
  List<String> removeExpiredPrinters({Duration threshold = const Duration(hours: 24)}) {
    final expired = store.getExpiredPrinters(threshold);
    final removed = <String>[];

    for (final printer in expired) {
      try {
        removePrinter(printer.sn);
        removed.add(printer.sn);
        print('[FarmHub] 🗑️ 已删除过期设备: ${printer.sn} (离线自 ${printer.offlineSince ?? printer.lastStatusTime})');
      } catch (e) {
        print('[FarmHub] ⚠️ 删除过期设备 ${printer.sn} 失败: $e');
      }
    }

    return removed;
  }

  // ═══════════════════════════════════════════════════════════
  // HTTP 降级后台升级
  // ═══════════════════════════════════════════════════════════

  void _startUpgradeRetries() {
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      final httpPrinters = store.httpFallbackPrinters;
      for (final printer in httpPrinters) {
        try {
          final configPusher = ConfigPushService(
            printerIp: printer.ip,
            printerPort: printer.port,
          );

          final mqttPassword = CredentialStore.generatePrinterPassword(printer.sn);

          // 确保 Broker 上存在该打印机用户
          if (_brokerUserMgr != null) {
            await _brokerUserMgr!.createPrinterUser(
              sn: printer.sn,
              password: mqttPassword,
            );
          }

          final mqttConfig = MqttConfig(
            brokerAddress: _brokerConfig?.host ?? '',
            brokerPort: _brokerConfig?.port ?? 1883,
            username: 'printer_${printer.sn}',
            password: mqttPassword,
            instanceName: printer.sn,
          );

          final result = await configPusher.onboard(
            accessCode: '',
            mqttConfig: mqttConfig,
          );

          if (result.success) {
            // 更新本地凭据存储
            await credentialStore.savePrinterCredential(
              sn: printer.sn,
              username: 'printer_${printer.sn}',
              password: mqttPassword,
            );

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
        } catch (_) {}
      }
    });
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await shutdown();
    store.dispose();
  }
}
