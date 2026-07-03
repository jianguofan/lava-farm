/// 农场仪表盘主页 (T11.3)
///
/// 群控桌面端的主界面，整合所有子组件:
///   AppBar: BrokerStatusIndicator + 添加打印机按钮
///   Body: DeploymentModeBanner + StatsBar + FilterChips + PrinterGrid
///   Bottom: BatchToolbar (选中打印机时显示)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/printer_list_provider.dart';
import '../../data/batch_operator.dart';
import '../../data/farm_printer_state.dart';
import '../../data/farm_store.dart';
import '../../data/printer_info.dart';
import '../widgets/batch_toolbar.dart';
import '../widgets/broker_status_indicator.dart';
import '../widgets/deployment_mode_banner.dart';
import '../widgets/printer_grid.dart';
import '../widgets/stats_bar.dart';
import 'broker_setup_page.dart';
import 'camera_monitor_page.dart';
import 'discovery_wizard_page.dart';
import 'printer_detail_page.dart';

/// 筛选模式
enum _PrinterFilter { all, printing, offline, mqtt, http }

/// 农场仪表盘页面
class FarmDashboardPage extends ConsumerStatefulWidget {
  const FarmDashboardPage({super.key});

  @override
  ConsumerState<FarmDashboardPage> createState() => _FarmDashboardPageState();
}

class _FarmDashboardPageState extends ConsumerState<FarmDashboardPage> {
  final _selectedSns = <String>{};
  _PrinterFilter _activeFilter = _PrinterFilter.all;
  bool _autoConnectAttempted = false;

  @override
  void initState() {
    super.initState();
    // 首帧后自动连接 Broker
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());
  }

  Future<void> _autoConnect() async {
    if (_autoConnectAttempted) return;
    _autoConnectAttempted = true;

    final manager = ref.read(brokerConnMgrProvider);
    if (manager.isConnected) return;

    try {
      await manager.connect(
        host: '172.18.1.54',
        port: 1883,
        username: 'lava_app',
        password: 'lava-farm-admin',
      );

      // 注册预设设备（触发 _probeAll 轮询获取 IP）
      final store = ref.read(farmStoreProvider);
      _registerDemoDevices(store);
    } catch (_) {
      // 自动连接失败 — 用户可手动进入 Broker 设置页配置
    }
  }

  void _registerDemoDevices(FarmStore store) {
    const demoDevices = [
      ('8110025060100056K296', '切片工程-01', 'slicing'),
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

  @override
  Widget build(BuildContext context) {
    // 保持 MQTT Router Provider 存活 — 确保连接 Broker 后自动 start()
    ref.watch(farmMqttRouterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lava Farm'),
        actions: [
          BrokerStatusIndicator(
            onTap: () => _openBrokerSettings(context),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: '设备监控',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CameraMonitorPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.dashboard_customize),
            tooltip: '群控打印',
            onPressed: () => _openBatchPrint(context),
          ),
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: '日志查看',
            onPressed: () => Navigator.pushNamed(context, '/logs'),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加打印机',
            onPressed: () => _openDiscovery(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // ── 状态横幅 ──
          _buildBanners(),

          // ── 统计栏 ──
          const StatsBar(),

          // ── 筛选栏 ──
          _buildFilterChips(),

          const Divider(height: 1),

          // ── 打印机网格 ──
          Expanded(
            child: PrinterGrid(
              selectedSns: _selectedSns,
              onSelectionChanged: (updated) =>
                  setState(() => _selectedSns..clear()..addAll(updated)),
              onPrinterTap: (sn) => _openPrinterDetail(context, sn),
              onPrinterLongPress: (sn) {
                // 长按进入多选，已在 PrinterGrid 内部处理
              },
            ),
          ),

          // ── 批量操作工具栏 ──
          BatchToolbar(
            selectedCount: _selectedSns.length,
            onDismiss: () => setState(() => _selectedSns.clear()),
            onAction: (action) => _handleBatchAction(context, action),
          ),
        ],
      ),
    );
  }

  /// 状态横幅（HTTP 降级 — Broker 断连用 ScaffoldMessenger 显示）
  Widget _buildBanners() {
    final httpFallbackCount = ref.watch(httpFallbackCountProvider);

    if (httpFallbackCount > 0) {
      return HttpFallbackBanner(httpFallbackCount: httpFallbackCount);
    }
    return const SizedBox.shrink();
  }

  /// 筛选芯片
  Widget _buildFilterChips() {
    final stats = ref.watch(farmStatsProvider);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _FilterChip(
            label: '全部',
            count: stats.total,
            isActive: _activeFilter == _PrinterFilter.all,
            onTap: () => setState(() => _activeFilter = _PrinterFilter.all),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: '打印中',
            count: stats.printing,
            color: Colors.blue,
            isActive: _activeFilter == _PrinterFilter.printing,
            onTap: () => setState(() => _activeFilter = _PrinterFilter.printing),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: '离线',
            count: stats.total - stats.online,
            color: Colors.grey,
            isActive: _activeFilter == _PrinterFilter.offline,
            onTap: () => setState(() => _activeFilter = _PrinterFilter.offline),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: 'MQTT',
            count: stats.mqttCount,
            color: Colors.purple,
            isActive: _activeFilter == _PrinterFilter.mqtt,
            onTap: () => setState(() => _activeFilter = _PrinterFilter.mqtt),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: 'HTTP',
            count: stats.httpCount,
            color: Colors.orange,
            isActive: _activeFilter == _PrinterFilter.http,
            onTap: () => setState(() => _activeFilter = _PrinterFilter.http),
          ),
        ],
      ),
    );
  }

  /// 处理批量操作
  Future<void> _handleBatchAction(BuildContext context, BatchAction action) async {
    final sns = _selectedSns.toList();
    if (sns.isEmpty && action != BatchAction.emergencyStop) return;

    final operator = ref.read(batchOperatorProvider);

    switch (action) {
      case BatchAction.pause:
        _showSnackBar(context, '正在暂停 ${sns.length} 台打印机...');
        final results = await operator.batchPause(sns);
        _showBatchResult(context, '暂停', results);
        break;
      case BatchAction.cancel:
        _showSnackBar(context, '正在取消 ${sns.length} 台打印机...');
        final results = await operator.batchCancel(sns);
        _showBatchResult(context, '取消', results);
        break;
      case BatchAction.emergencyStop:
        final allSns = ref.read(farmStoreProvider).allPrinters.map((p) => p.sn).toList();
        if (allSns.isEmpty) return;
        _showSnackBar(context, '正在急停所有打印机...', isError: true);
        final results = await operator.batchEmergencyStop();
        _showBatchResult(context, '急停', results);
        break;
      case BatchAction.setTemperatures:
        _showTempDialog(context, sns);
        return; // 不清除选择（对话框内处理）
      case BatchAction.sendGcode:
        _showGcodeDialog(context, sns);
        return; // 不清除选择（对话框内处理）
      case BatchAction.uploadAndPrint:
        _openBatchPrint(context);
        return; // 不清除选择（导航到群控页）
    }

    setState(() => _selectedSns.clear());
  }

  void _showBatchResult(BuildContext context, String action, List<BatchResult> results) {
    final ok = results.where((r) => r.success).length;
    final fail = results.where((r) => !r.success).length;
    final msg = fail > 0
        ? '$action完成: $ok 成功, $fail 失败'
        : '$action完成: 全部 $ok 台成功';
    _showSnackBar(context, msg, isError: fail > 0);
  }

  void _showTempDialog(BuildContext context, List<String> sns) {
    final controller = TextEditingController(text: '210');
    final operator = ref.read(batchOperatorProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('设置喷嘴温度 (${sns.length} 台)'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '温度 °C',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final temp = double.tryParse(controller.text);
              if (temp == null) return;
              Navigator.pop(ctx);
              _showSnackBar(context, '正在设置 ${sns.length} 台打印机温度为 ${temp.toInt()}°C...');
              final results = await operator.batchSetNozzleTemp(
                printerSns: sns, temp: temp,
              );
              _showBatchResult(context, '设置温度', results);
              if (mounted) setState(() => _selectedSns.clear());
            },
            child: const Text('设置'),
          ),
        ],
      ),
    );
  }

  void _showGcodeDialog(BuildContext context, List<String> sns) {
    final controller = TextEditingController();
    final operator = ref.read(batchOperatorProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发送 GCode (${sns.length} 台)'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'GCode',
            hintText: 'G28',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final gcode = controller.text.trim();
              if (gcode.isEmpty) return;
              Navigator.pop(ctx);
              _showSnackBar(context, '正在发送 GCode 到 ${sns.length} 台打印机...');
              final results = await operator.batchGcode(
                printerSns: sns, gcode: gcode,
              );
              _showBatchResult(context, 'GCode', results);
              if (mounted) setState(() => _selectedSns.clear());
            },
            child: const Text('发送'),
          ),
        ],
      ),
    );
  }

  void _openBrokerSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BrokerSetupPage()),
    );
  }

  void _openDiscovery(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DiscoveryWizardPage()),
    );
  }

  void _openPrinterDetail(BuildContext context, String sn) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PrinterDetailPage(sn: sn)),
    );
  }

  void _openBatchPrint(BuildContext context) {
    Navigator.pushNamed(
      context,
      '/batch-print',
      arguments: _selectedSns.toList(),
    );
  }

  void _showSnackBar(BuildContext context, String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// 筛选芯片
class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final Color? color;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    this.color,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Colors.blueGrey;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? effectiveColor.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? effectiveColor : Colors.grey.shade300,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive ? effectiveColor : Colors.grey.shade600,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isActive ? effectiveColor.withOpacity(0.2) : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isActive ? effectiveColor : Colors.grey.shade500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
