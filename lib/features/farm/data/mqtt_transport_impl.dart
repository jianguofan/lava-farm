/// MQTT Transport 实现
///
/// 使用 mqtt_client 包封装与 Mosquitto Broker 的 TCP 连接。
/// 实现 MqttTransportAdapter 接口供 BrokerConnectionManager 使用。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart' as mqtt;
import 'package:mqtt_client/mqtt_server_client.dart' as mqtt_server;
import 'package:typed_data/typed_data.dart' as typed;

import 'broker_connection_manager.dart';

/// MQTT Transport 具体实现（包装 mqtt_client）
class MqttTransportImpl implements MqttTransportAdapter {
  final BrokerConfig _config;
  mqtt_server.MqttServerClient? _client;
  StreamSubscription<List<mqtt.MqttReceivedMessage<mqtt.MqttMessage>>>? _updateSub;

  final StreamController<MqttMessage> _messageController =
      StreamController<MqttMessage>.broadcast();

  MqttTransportImpl(this._config);

  // ═══════════════════════════════════════════════════════════
  // MqttTransportAdapter 接口
  // ═══════════════════════════════════════════════════════════

  @override
  Future<void> connect() async {
    print('[MQTT] 开始连接: host=${_config.host} port=${_config.port} username=${_config.username}');
    print('[MQTT] 密码长度: ${_config.password.length} chars');

    // 桌面端必须用 MqttServerClient（不能直接用 MqttClient）
    final client = mqtt_server.MqttServerClient.withPort(
      _config.host,
      _config.username,
      _config.port,
    );

    // 纯 TCP，不用 WebSocket
    client.useWebSocket = false;
    client.secure = false;

    // 日志（调试时临时改为 true）
    client.logging(on: false);

    // Keepalive 60 秒
    client.keepAlivePeriod = 60;

    // 无 ping 响应 10 秒后主动断开
    client.disconnectOnNoResponsePeriod = 10;

    // 不自动重连（由 BrokerConnectionManager 控制）
    client.autoReconnect = false;

    client.onDisconnected = () {
      print('[MQTT] ⚠️ 非预期断开 (onDisconnected)');
    };
    client.onConnected = () {
      print('[MQTT] ✓ onConnected 回调触发');
    };

    // 连接消息配置
    final connMsg = mqtt.MqttConnectMessage()
        .withClientIdentifier(_config.username)
        .authenticateAs(_config.username, _config.password)
        .withWillTopic('${_config.username}/notification')
        .withWillMessage('{"server":"offline"}')
        .startClean();

    client.connectionMessage = connMsg;
    print('[MQTT] 连接消息已配置: clientId=${_config.username} keepAlive=60');

    try {
      print('[MQTT] 调用 client.connect()...');
      final result = await client.connect();
      print('[MQTT] client.connect() 返回: state=${result?.state} returnCode=${result?.returnCode}');
    } catch (e, st) {
      print('[MQTT] ❌ 连接失败: $e');
      print('[MQTT] 异常类型: ${e.runtimeType}');
      print('[MQTT] 堆栈: $st');
      try { client.disconnect(); } catch (_) {}
      rethrow;
    }

    // 连接成功后监听消息流
    print('[MQTT] updates stream: ${client.updates != null ? "可用" : "null"}');
    _updateSub = client.updates?.listen(_onUpdates);
    _client = client;
    print('[MQTT] ✓✓✓ 连接完全建立!');
  }

  @override
  Future<void> disconnect() async {
    print('[MQTT] disconnect() 调用');
    await _cleanup();
  }

  @override
  Future<void> ping() async {
    final client = _client;
    if (client == null) throw Exception('MQTT 未连接');

    final state = client.connectionStatus?.state;
    if (state != mqtt.MqttConnectionState.connected) {
      throw Exception('MQTT 连接异常 (state=$state)');
    }
    // mqtt_client keepAlive 机制自动发送 PINGREQ/PINGRESP
    // 这里仅验证连接状态有效
  }

  @override
  Future<void> subscribe(String topic, {int qos = 1}) async {
    final client = _client;
    if (client == null) throw Exception('MQTT 未连接');
    print('[MQTT] subscribe: $topic qos=$qos');
    client.subscribe(topic, _toMqttQos(qos));
  }

  @override
  Future<void> publish(String topic, List<int> payload, {int qos = 1}) async {
    final client = _client;
    if (client == null) throw Exception('MQTT 未连接');

    final builder = mqtt.MqttClientPayloadBuilder();
    builder.addBuffer(typed.Uint8Buffer()..addAll(payload));
    client.publishMessage(topic, _toMqttQos(qos), builder.payload!);
  }

  @override
  Stream<MqttMessage> get messageStream => _messageController.stream;

  // ═══════════════════════════════════════════════════════════
  // 内部
  // ═══════════════════════════════════════════════════════════

  int _msgCount = 0;
  DateTime _lastMsgLog = DateTime.now();

  void _onUpdates(List<mqtt.MqttReceivedMessage<mqtt.MqttMessage>> messages) {
    _msgCount += messages.length;

    for (final msg in messages) {
      // 提取 payload 字节
      Uint8List payloadBytes;
      if (msg.payload is mqtt.MqttPublishMessage) {
        final pubMsg = msg.payload as mqtt.MqttPublishMessage;
        payloadBytes = Uint8List.fromList(pubMsg.payload.message);
      } else {
        payloadBytes = utf8.encode(msg.payload.toString());
      }

      _messageController.add(MqttMessage(
        topic: msg.topic,
        payload: payloadBytes,
      ));
    }

    // 每 5 秒汇总一次，不逐条打印
    final now = DateTime.now();
    if (now.difference(_lastMsgLog).inSeconds >= 5) {
      print('[MQTT] 📊 5s 内收到 $_msgCount 条消息');
      _msgCount = 0;
      _lastMsgLog = now;
    }
  }

  Future<void> _cleanup() async {
    await _updateSub?.cancel();
    _updateSub = null;
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
  }

  static mqtt.MqttQos _toMqttQos(int qos) {
    switch (qos) {
      case 0:
        return mqtt.MqttQos.atMostOnce;
      case 2:
        return mqtt.MqttQos.exactlyOnce;
      default:
        return mqtt.MqttQos.atLeastOnce;
    }
  }
}

/// Transport 工厂
class MqttTransportFactory {
  Future<MqttTransportAdapter> create(BrokerConfig config) async {
    return MqttTransportImpl(config);
  }
}
