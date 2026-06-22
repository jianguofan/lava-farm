/// Broker 设置页面
///
/// App 是纯 MQTT 客户端，连接中央 Broker。
/// Broker 健康由 MQTT keepalive + PINGREQ/PINGRESP 保障，
/// 不需要也不应该通过 Docker CLI 管理 Broker 进程。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../data/broker_connection_manager.dart';
import '../../data/farm_mqtt_router.dart';
import '../../data/farm_store.dart';
import '../../data/printer_info.dart';

/// Broker 设置页面
class BrokerSetupPage extends ConsumerStatefulWidget {
  const BrokerSetupPage({super.key});

  @override
  ConsumerState<BrokerSetupPage> createState() => _BrokerSetupPageState();
}

class _BrokerSetupPageState extends ConsumerState<BrokerSetupPage> {
  FarmMqttRouter? _router;
  bool _isBusy = false;
  String? _errorMessage;

  // ── 表单 ──
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '1883');
  final _usernameController = TextEditingController(text: 'lava_app');
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _router?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brokerState = ref.watch(brokerStateProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Broker 设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── MQTT 连接状态（来自 keepalive + PINGRESP，非 Docker CLI）──
            _buildMqttConnectionCard(brokerState),
            const SizedBox(height: 24),

            // ── 连接表单 ──
            _buildConnectionForm(brokerState),

            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(_errorMessage!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // MQTT 连接状态卡片
  // ═══════════════════════════════════════════════════════════

  Widget _buildMqttConnectionCard(BrokerConnState? brokerState) {
    final state = brokerState ?? BrokerConnState.disconnected;
    final isConnected = state.isConnected;

    return Card(
      color: isConnected ? Colors.green.shade50 : Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              switch (state) {
                BrokerConnState.connected => Icons.cloud_done,
                BrokerConnState.connecting => Icons.sync,
                BrokerConnState.degraded => Icons.cloud_off,
                BrokerConnState.error => Icons.error,
                BrokerConnState.disconnected => Icons.cloud_off,
              },
              size: 40,
              color: switch (state) {
                BrokerConnState.connected => Colors.green,
                BrokerConnState.connecting => Colors.orange,
                BrokerConnState.degraded => Colors.orange,
                BrokerConnState.error => Colors.red,
                BrokerConnState.disconnected => Colors.grey,
              },
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MQTT: ${state.label}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isConnected ? Colors.green.shade800 : Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isConnected
                        ? '${_hostController.text}:${_portController.text} (keepalive 保活中)'
                        : 'Broker 健康由 MQTT PINGREQ/PINGRESP 检测，App 自动重连',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 连接表单
  // ═══════════════════════════════════════════════════════════

  Widget _buildConnectionForm(BrokerConnState? brokerState) {
    final isConnected = brokerState?.isConnected ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '连接信息',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _hostController,
          decoration: const InputDecoration(
            labelText: 'Broker 地址',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          enabled: !_isBusy,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _portController,
          decoration: const InputDecoration(
            labelText: '端口',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: TextInputType.number,
          enabled: !_isBusy,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _usernameController,
          decoration: const InputDecoration(
            labelText: '用户名',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          enabled: !_isBusy,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _passwordController,
          decoration: const InputDecoration(
            labelText: '密码',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          obscureText: true,
          enabled: !_isBusy,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (_isBusy || isConnected) ? null : _connectToBroker,
                icon: _isBusy
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.link),
                label: Text(_isBusy ? '连接中...' : '连接'),
              ),
            ),
            if (isConnected) ...[
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _disconnectFromBroker,
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                ),
              ),
            ],
          ],
        ),
        if (_isBusy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 操作
  // ═══════════════════════════════════════════════════════════

  Future<void> _connectToBroker() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 1883;
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (host.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = '请填写完整的连接信息');
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      final manager = ref.read(brokerConnMgrProvider);
      await manager.connect(
        host: host, port: port, username: username, password: password,
      );

      // MQTT 已连接 → 创建 Router 订阅通配符 topic
      final transport = manager.transport;
      if (transport != null) {
        final store = ref.read(farmStoreProvider);
        _router = FarmMqttRouter(store: store, transport: transport);
        await _router!.start();

        // 注册预设设备
        _registerDemoDevices(store);
      }
    } catch (e) {
      setState(() => _errorMessage = '连接失败: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<void> _disconnectFromBroker() async {
    try {
      await _router?.stop();
      _router = null;
      await ref.read(brokerConnMgrProvider).disconnect();
    } catch (e) {
      setState(() => _errorMessage = '断开失败: $e');
    }
  }

  void _registerDemoDevices(FarmStore store) {
    const demoDevices = [
      ('8110026042710299B378', '切片工程-01', 'slicing'),
      ('81100260503102537008', '切片工程-02', 'slicing'),
      ('8110026050310266IC73', '切片工程-03', 'slicing'),
      ('81100260503003514ZB5', '切片工程-04', 'slicing'),
      ('8110026050310190EKV9', 'web全栈-01', 'web'),
      ('8110026050310268AUFG', 'web全栈-02', 'web'),
      ('8110025060100049IXMZ', '服务端运维-01', 'backend'),
      ('8110025070800048LD98', '服务端运维-02', 'backend'),
      ('8110025070800069BU7J', '客户端-01', 'client'),
      ('811002605310262H7H8', '客户端-02', 'client'),
      ('8110026050300191X4HB', '测试-01', 'test'),
    ];

    for (final (sn, name, group) in demoDevices) {
      if (store.getPrinter(sn) == null) {
        store.onPrinterRegistered(PrinterInfo(
          sn: sn,
          displayName: name,
          ip: '—',
          port: 7125,
          group: group,
          source: Source.mqtt,
          model: 'Snapmaker J1',
        ));
      }
    }
  }
}
