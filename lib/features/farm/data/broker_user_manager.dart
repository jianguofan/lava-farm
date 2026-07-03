/// BrokerUserManager — Mosquitto Dynamic Security 用户管理
///
/// 通过 MQTT $CONTROL API 在运行时管理打印机用户（无需重启 Broker）。
///
/// 使用场景:
///   - 打印机入网时: createPrinterUser(sn, password)
///   - 打印机移除时: deletePrinterUser(sn)
///
/// API 参考:
///   Mosquitto Dynamic Security Plugin v1
///   https://mosquitto.org/documentation/dynamic-security/
///
/// 协议:
///   请求 topic: $CONTROL/dynamic-security/v1
///   响应 topic: $CONTROL/dynamic-security/v1/response
///
///   请求格式: {"commands": [{"command": "createClient", ...}]}
///   响应格式: {"responses": [{"command": "createClient", "error": "..."}]}
///             error 字段不存在 = 成功

import 'dart:async';
import 'dart:convert';

import 'broker_connection_manager.dart';

/// Broker 用户管理结果
class BrokerUserResult {
  final bool success;
  final String? error;

  const BrokerUserResult({required this.success, this.error});

  static const ok = BrokerUserResult(success: true);
  static BrokerUserResult fail(String error) =>
      BrokerUserResult(success: false, error: error);
}

/// Mosquitto Dynamic Security 客户端管理器
///
/// 通过 MQTT $CONTROL topic 管理 Broker 上的打印机用户。
///
/// 使用方法:
///   final manager = BrokerUserManager(transport: transport);
///
///   // 确保已订阅 control topic（连接后调用一次）
///   await manager.init();
///
///   // 创建打印机用户
///   final result = await manager.createPrinterUser(
///     sn: 'ABC123',
///     password: 'xxx',
///   );
class BrokerUserManager {
  final MqttTransportAdapter _transport;

  /// 是否已订阅 control response topic
  bool _initialized = false;

  /// 请求计数器，用于匹配响应
  int _correlationId = 0;

  /// 待处理请求: correlationData → Completer
  final Map<String, Completer<List<Map<String, dynamic>>>> _pending = {};

  /// control response 流订阅
  StreamSubscription<MqttMessage>? _subscription;

  BrokerUserManager({required MqttTransportAdapter transport})
      : _transport = transport;

  // ═══════════════════════════════════════════════════════════
  // 初始化
  // ═══════════════════════════════════════════════════════════

  /// 初始化：订阅 control response topic
  ///
  /// 连接 Broker 后调用一次。重复调用安全（幂等）。
  Future<void> init() async {
    if (_initialized) return;

    await _transport.subscribe(r'$CONTROL/dynamic-security/v1/response', qos: 1);
    _subscription = _transport.messageStream.listen(_onMessage);
    _initialized = true;
  }

  /// 释放资源
  void dispose() {
    _initialized = false;
    _subscription?.cancel();
    _subscription = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError('BrokerUserManager disposed');
      }
    }
    _pending.clear();
  }

  // ═══════════════════════════════════════════════════════════
  // 公共 API
  // ═══════════════════════════════════════════════════════════

  /// 为打印机创建 MQTT 用户
  ///
  /// 用户名为 printer_{SN}，角色为 printer（仅能访问自己的 topic）。
  Future<BrokerUserResult> createPrinterUser({
    required String sn,
    required String password,
  }) async {
    final username = 'printer_$sn';
    return _sendCommand({
      'command': 'createClient',
      'username': username,
      'password': password,
      'textname': 'Printer $sn',
      'textdescription': 'Auto-created by lava-farm onboarding',
      'roles': [
        {'rolename': 'printer', 'priority': 0},
      ],
    });
  }

  /// 删除打印机 MQTT 用户
  Future<BrokerUserResult> deletePrinterUser(String sn) async {
    final username = 'printer_$sn';
    return _sendCommand({
      'command': 'deleteClient',
      'username': username,
    });
  }

  /// 检查打印机用户是否存在
  Future<BrokerUserResult> getPrinterUser(String sn) async {
    final username = 'printer_$sn';
    return _sendCommand({
      'command': 'getClient',
      'username': username,
    });
  }

  /// 修改打印机用户密码
  Future<BrokerUserResult> setPrinterPassword({
    required String sn,
    required String newPassword,
  }) async {
    final username = 'printer_$sn';
    return _sendCommand({
      'command': 'setClientPassword',
      'username': username,
      'password': newPassword,
    });
  }

  /// 列出所有客户端（调试用）
  Future<List<Map<String, dynamic>>> listClients() async {
    final responses = await _sendCommandRaw({
      'command': 'listClients',
      'verbose': false,
    });
    final listResponse = responses.firstOrNull;
    if (listResponse == null) return [];
    final clients = listResponse['clients'] as List<dynamic>?;
    return clients?.cast<Map<String, dynamic>>() ?? [];
  }

  // ═══════════════════════════════════════════════════════════
  // 内部
  // ═══════════════════════════════════════════════════════════

  /// 发送单条指令，返回简化结果
  Future<BrokerUserResult> _sendCommand(Map<String, dynamic> command) async {
    try {
      final responses = await _sendCommandRaw(command);
      final r = responses.firstOrNull;
      if (r == null) {
        return BrokerUserResult.fail('no response from broker');
      }
      final error = r['error'] as String?;
      if (error != null && error.isNotEmpty) {
        return BrokerUserResult.fail(error);
      }
      return BrokerUserResult.ok;
    } catch (e) {
      return BrokerUserResult.fail(e.toString());
    }
  }

  /// 发送指令并返回原始响应列表
  Future<List<Map<String, dynamic>>> _sendCommandRaw(
    Map<String, dynamic> command,
  ) async {
    final data = _generateCorrelationData();
    final completer = Completer<List<Map<String, dynamic>>>();
    _pending[data] = completer;

    final request = {
      'commands': [command],
      'correlationData': data,
    };

    await _transport.publish(
      r'$CONTROL/dynamic-security/v1',
      utf8.encode(jsonEncode(request)),
      qos: 1,
    );

    // 5 秒超时（本地 Broker 通信应该很快）
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pending.remove(data);
        throw TimeoutException('Broker \$CONTROL API 超时: ${command['command']}');
      },
    );
  }

  /// 生成唯一 correlationData
  String _generateCorrelationData() {
    _correlationId++;
    return 'lava-farm-${DateTime.now().millisecondsSinceEpoch}-$_correlationId';
  }

  /// 处理 control response topic 的消息
  void _onMessage(MqttMessage msg) {
    if (msg.topic != r'$CONTROL/dynamic-security/v1/response') return;

    try {
      final body = utf8.decode(msg.payload);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final correlationData = json['correlationData'] as String?;
      if (correlationData == null) return;

      final completer = _pending.remove(correlationData);
      if (completer != null && !completer.isCompleted) {
        final responses = json['responses'] as List<dynamic>?;
        completer.complete(
          responses?.cast<Map<String, dynamic>>() ?? [],
        );
      }
    } catch (_) {
      // 解析失败忽略（可能是其他请求的响应）
    }
  }
}
