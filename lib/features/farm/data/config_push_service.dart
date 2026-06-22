/// Moonraker 配置推送服务 (T3.1)
///
/// 通过 Moonraker HTTP API 远程推送 MQTT 配置到打印机。
///
/// 完整流程:
///   1. POST /access/login — 验证 Access Code，获取 token
///   2. GET /server/info — 获取设备 SN 和状态
///   3. 检查打印机状态（打印中则警告）
///   4. POST /server/config — 写入 [mqtt] 配置段（含 Broker 凭据）
///   5. POST /server/restart — 重启 Moonraker 生效
///   6. 轮询 GET /server/info 等待重启完成
///   7. 等待打印机连接新 Broker (+/notification online)
///
/// 失败处理:
///   - 最多重试 3 次（15s 间隔）
///   - 全部失败 → 标记 HTTP 降级
///   - 后台每 5 分钟持续重试（不永久卡在降级）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'printer_info.dart';

/// 配置推送结果
class ConfigPushResult {
  final bool success;
  final String sn;
  final Source resultingSource; // mqtt | http
  final String? error;

  const ConfigPushResult({
    required this.success,
    required this.sn,
    required this.resultingSource,
    this.error,
  });

  static ConfigPushResult mqtt(String sn) =>
      ConfigPushResult(success: true, sn: sn, resultingSource: Source.mqtt);

  static ConfigPushResult httpFallback(String sn, String reason) =>
      ConfigPushResult(success: false, sn: sn, resultingSource: Source.http, error: reason);
}

/// Moonraker 服务器信息
class MoonrakerServerInfo {
  final bool klippyConnected;
  final String instanceName;
  final String? model;
  final String? version;
  final Map<String, dynamic>? printStats;

  const MoonrakerServerInfo({
    required this.klippyConnected,
    required this.instanceName,
    this.model,
    this.version,
    this.printStats,
  });

  /// 是否正在打印
  bool get isPrinting =>
      printStats?['state'] == 'printing';

  factory MoonrakerServerInfo.fromJson(Map<String, dynamic> json) {
    final result = json['result'] as Map<String, dynamic>? ?? json;
    final status = result['status'] as Map<String, dynamic>?;
    return MoonrakerServerInfo(
      klippyConnected: result['klippy_connected'] as bool? ?? false,
      instanceName: result['instance_name'] as String? ?? 'unknown',
      model: result['model'] as String?,
      version: result['version'] as String?,
      printStats: status?['print_stats'] as Map<String, dynamic>?,
    );
  }
}

/// MQTT 配置
class MqttConfig {
  final String brokerAddress;
  final int brokerPort;
  final String username;
  final String password;
  final String instanceName;
  final double statusInterval;

  const MqttConfig({
    required this.brokerAddress,
    this.brokerPort = 1883,
    required this.username,
    required this.password,
    required this.instanceName,
    this.statusInterval = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'config': {
      'mqtt': {
        'address': brokerAddress,
        'port': brokerPort,
        'username': username,
        'password': password,
        'instance_name': instanceName,
        'status_interval': statusInterval,
        'enable_moonraker_api': true,
      }
    }
  };
}

/// 打印机状态检查结果
enum PrinterStatusCheck {
  ok,             // 空闲，可以操作
  printing,       // 正在打印，需要用户确认
  unknown,        // 无法确定状态
}

/// 配置推送服务
///
/// 封装 Moonraker HTTP API 的几个关键端点:
/// - POST /access/login
/// - GET /server/info
/// - POST /server/config
/// - POST /server/restart
class ConfigPushService {
  final String printerIp;
  final int printerPort;
  final HttpClient _client;

  /// 重试配置
  static const maxRetries = 3;
  static const retryDelay = Duration(seconds: 15);
  static const restartTimeout = Duration(seconds: 20);

  String? _apiKey; // 登录后获取的 token

  ConfigPushService({
    required this.printerIp,
    this.printerPort = 7125,
    HttpClient? client,
  }) : _client = client ?? HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

  // ═══════════════════════════════════════════════════════════
  // Step 1: 登录验证
  // ═══════════════════════════════════════════════════════════

  /// 验证 Access Code 并获取 API Token
  ///
  /// 返回 token，失败返回 null。
  Future<String?> login(String accessCode) async {
    try {
      final response = await _post(
        '/access/login',
        body: {'access_code': accessCode},
      );

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        _apiKey = json['result']?['token'] as String?;
        return _apiKey;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // Step 2: 获取设备信息
  // ═══════════════════════════════════════════════════════════

  /// 获取设备 SN 和当前状态
  Future<MoonrakerServerInfo?> getServerInfo() async {
    try {
      final response = await _get('/server/info');
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        return MoonrakerServerInfo.fromJson(json);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 检查打印机当前状态
  ///
  /// 返回 PrinterStatusCheck 供调用方决定是否继续操作。
  Future<PrinterStatusCheck> checkPrinterStatus() async {
    try {
      final info = await getServerInfo();
      if (info == null) return PrinterStatusCheck.unknown;
      return info.isPrinting ? PrinterStatusCheck.printing : PrinterStatusCheck.ok;
    } catch (_) {
      return PrinterStatusCheck.unknown;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // Step 3: 推送 MQTT 配置
  // ═══════════════════════════════════════════════════════════

  /// 写入 MQTT 配置到打印机 Moonraker
  ///
  /// MQTT 配置包含:
  /// - Broker 地址和端口
  /// - 打印机专属的用户名和密码
  /// - instance_name（使用 SN）
  /// - status_interval（状态推送间隔）
  Future<bool> pushMqttConfig(MqttConfig config) async {
    try {
      final response = await _post(
        '/server/config',
        body: config.toJson(),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // Step 4: 重启 Moonraker
  // ═══════════════════════════════════════════════════════════

  /// 发送重启指令
  Future<bool> sendRestart() async {
    try {
      final response = await _post('/server/restart', body: {});
      // Moonraker 可能在返回前就重启，timeout 是预期行为
      return response.statusCode == 200;
    } on SocketException {
      // Moonraker 重启中，连接拒绝是正常的
      return true;
    } catch (_) {
      // 超时也可能发生，视为成功
      return true;
    }
  }

  /// 等待 Moonraker 重启完成
  ///
  /// 轮询 GET /server/info 直到 klippy_connected 恢复为 true。
  /// 超时返回 false。
  Future<bool> waitForRestartComplete({Duration timeout = restartTimeout}) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final info = await getServerInfo();
        if (info != null && info.klippyConnected) {
          return true;
        }
      } catch (_) {
        // 连接拒绝 = 仍在重启中，继续等待
      }
    }
    return false;
  }

  // ═══════════════════════════════════════════════════════════
  // Step 5: 完整入网流程
  // ═══════════════════════════════════════════════════════════

  /// 执行完整入网流程（含重试）
  ///
  /// 返回 ConfigPushResult，包含最终通信模式（mqtt / http）。
  Future<ConfigPushResult> onboard({
    required String accessCode,
    required MqttConfig mqttConfig,
    Future<bool> Function(String sn, Duration timeout)? waitForMqttOnline,
  }) async {
    // 1. 登录
    final token = await login(accessCode);
    if (token == null) {
      return ConfigPushResult.httpFallback('unknown', 'Access Code 验证失败');
    }

    // 2. 获取设备信息
    final info = await getServerInfo();
    if (info == null) {
      return ConfigPushResult.httpFallback('unknown', '无法获取设备信息');
    }
    final sn = info.instanceName;

    // 如果 instance_name 与预期不符，使用实际的
    final effectiveConfig = mqttConfig.instanceName == sn
        ? mqttConfig
        : MqttConfig(
            brokerAddress: mqttConfig.brokerAddress,
            brokerPort: mqttConfig.brokerPort,
            username: mqttConfig.username,
            password: mqttConfig.password,
            instanceName: sn,
            statusInterval: mqttConfig.statusInterval,
          );

    // 3. 推送配置（含重试）
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final pushed = await pushMqttConfig(effectiveConfig);
        if (!pushed) {
          if (attempt == maxRetries - 1) {
            return ConfigPushResult.httpFallback(sn, '配置推送失败（已重试 $maxRetries 次）');
          }
          await Future.delayed(retryDelay);
          continue;
        }

        // 4. 重启
        await sendRestart();

        // 5. 等待重启完成
        final restarted = await waitForRestartComplete();
        if (!restarted) {
          return ConfigPushResult.httpFallback(sn, 'Moonraker 重启超时');
        }

        // 6. 等待 MQTT 上线
        if (waitForMqttOnline != null) {
          final online = await waitForMqttOnline(sn, const Duration(seconds: 20));
          if (online) return ConfigPushResult.mqtt(sn);
          return ConfigPushResult.httpFallback(sn, '等待 MQTT 上线超时');
        }

        return ConfigPushResult.mqtt(sn);

      } catch (e) {
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(seconds: 5 * (attempt + 1))); // 递增间隔
        }
      }
    }

    return ConfigPushResult.httpFallback(
      info.instanceName,
      '配置推送失败（已重试 $maxRetries 次）',
    );
  }

  // ═══════════════════════════════════════════════════════════
  // HTTP 辅助
  // ═══════════════════════════════════════════════════════════

  Future<HttpClientResponse> _get(String path) async {
    final uri = Uri.parse('http://$printerIp:$printerPort$path');
    final request = await _client.getUrl(uri);
    _setHeaders(request);
    return await request.close().timeout(const Duration(seconds: 10));
  }

  Future<HttpClientResponse> _post(String path, {required Map<String, dynamic> body}) async {
    final uri = Uri.parse('http://$printerIp:$printerPort$path');
    final request = await _client.postUrl(uri);
    _setHeaders(request);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    return await request.close().timeout(const Duration(seconds: 10));
  }

  void _setHeaders(HttpClientRequest request) {
    if (_apiKey != null) {
      request.headers.set('X-Api-Key', _apiKey!);
    }
  }

  /// 释放 HTTP 客户端
  void dispose() {
    _client.close();
  }
}
