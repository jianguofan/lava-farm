/// 单打印机详情页
///
/// 显示内容:
/// - 设备元数据卡片（SN / IP / 型号 / 固件 / Moonraker 信息）
/// - 实时温度仪表
/// - 摄像头实时画面（CameraView 轮询）
/// - 打印进度条 + 预估剩余时间
/// - 事件时间线（连接 / 状态变更 / 错误）
/// - 手动控制面板（归零 / 设置温度 / 发送 GCode）

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/printer_list_provider.dart';
import '../../data/farm_printer_state.dart';
import '../../data/printer_discovery.dart';
import '../../data/printer_info.dart';
import '../widgets/camera_view.dart';
import '../widgets/print_section.dart';

/// 打印机详情页
class PrinterDetailPage extends ConsumerStatefulWidget {
  final String sn;

  const PrinterDetailPage({super.key, required this.sn});

  @override
  ConsumerState<PrinterDetailPage> createState() => _PrinterDetailPageState();
}

class _PrinterDetailPageState extends ConsumerState<PrinterDetailPage> {
  @override
  void initState() {
    super.initState();
    // 进入详情 → 按需拉取全量状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final router = ref.read(farmMqttRouterProvider);
      router?.fetchFullState(widget.sn);
    });
  }

  @override
  Widget build(BuildContext context) {
    final printer = ref.watch(
      printerRegistryProvider.select((state) => state[widget.sn]),
    );

    if (printer == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('打印机未找到')),
        body: const Center(child: Text('该打印机可能已移除')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(printer.displayName ?? printer.sn),
        actions: [
          _ConnectionChip(printer: printer),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 区块 1: 设备元数据 ──
            _MetadataCard(printer: printer),
            const SizedBox(height: 16),

            // ── 区块 1.5: 完整状态快照（rawStateSnapshot） ──
            if (printer.rawStateSnapshot != null)
              _RawStateSnapshotCard(printer: printer),
            if (printer.rawStateSnapshot != null) const SizedBox(height: 16),

            // ── 区块 1.6: 原始消息历史 ──
            if (printer.rawMessages.isNotEmpty)
              _RawMessageHistoryCard(printer: printer),
            if (printer.rawMessages.isNotEmpty) const SizedBox(height: 16),

            // ── 区块 2: 上传并打印 ──
            if (printer.isOnline)
              PrintSection(
                sn: printer.sn,
                ip: printer.ip,
                port: printer.port,
              ),
            if (printer.isOnline) const SizedBox(height: 16),

            // ── 区块 3: 温度仪表 ──
            _TemperatureSection(printer: printer),
            const SizedBox(height: 16),

            // ── 区块 3: 摄像头实时画面 ──
            if (printer.isOnline)
              _CameraSection(
                sn: printer.sn,
                ip: printer.ip,
                port: printer.port,
              ),
            if (printer.isOnline) const SizedBox(height: 16),

            // ── 区块 4: 打印进度 ──
            if (printer.isPrinting) ...[
              _PrintProgressSection(printer: printer),
              const SizedBox(height: 16),
            ],

            // ── 区块 5: 事件时间线 ──
            _EventTimeline(printer: printer),
            const SizedBox(height: 16),

            // ── 区块 6: 手动控制 ──
            _ManualControlSection(sn: widget.sn),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 连接状态 Chip
// ═══════════════════════════════════════════════════════════════

class _ConnectionChip extends StatelessWidget {
  final FarmPrinterState printer;
  const _ConnectionChip({required this.printer});

  @override
  Widget build(BuildContext context) {
    final isOnline = printer.isOnline;
    return Chip(
      avatar: Icon(
        isOnline ? Icons.wifi : Icons.wifi_off,
        size: 16,
        color: isOnline ? Colors.green : Colors.grey,
      ),
      label: Text(
        '${printer.source.label} · ${printer.connectionState.label}',
        style: const TextStyle(fontSize: 12),
      ),
      backgroundColor: isOnline ? Colors.green.shade50 : Colors.grey.shade100,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 设备元数据卡片
// ═══════════════════════════════════════════════════════════════

class _MetadataCard extends StatelessWidget {
  final FarmPrinterState printer;
  const _MetadataCard({required this.printer});

  @override
  Widget build(BuildContext context) {
    final lastStatus = printer.lastStatusTime;
    final serverInfoAge = printer.serverInfoFetchedAt != null
        ? DateTime.now().difference(printer.serverInfoFetchedAt!)
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Color(0xFF0C63E2)),
                const SizedBox(width: 6),
                const Text('设备元数据',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(
                  '${printer.source.label} · ${printer.connectionState.label}',
                  style: TextStyle(
                    fontSize: 11,
                    color: printer.isOnline ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
            const Divider(),

            // ── 基本信息 ──
            _MetaRow('序列号', printer.sn),
            _MetaRow('主机名', printer.hostname ?? '—'),
            _MetaRow('IP 地址', '${printer.ip}:${printer.port}'),
            _MetaRow('分组', printer.group ?? '未分组'),

            // ── 设备信息 ──
            if (printer.model != null || printer.firmwareVersion != null) ...[
              const SizedBox(height: 6),
              if (printer.model != null) _MetaRow('型号', printer.model!),
              if (printer.firmwareVersion != null)
                _MetaRow('固件', printer.firmwareVersion!),
            ],
            if (printer.softwareVersion != null)
              _MetaRow('软件版本', printer.softwareVersion!),

            // ── Moonraker 信息 ──
            if (printer.moonrakerVersion != null ||
                printer.apiVersionString != null ||
                printer.klippyState != null) ...[
              const SizedBox(height: 6),
              if (printer.moonrakerVersion != null)
                _MetaRow('Moonraker', printer.moonrakerVersion!),
              if (printer.apiVersionString != null)
                _MetaRow('API 版本', printer.apiVersionString!),
              if (printer.klippyState != null)
                _MetaRow('Klippy', printer.klippyState!),
            ],
            if (printer.cpuInfo != null) _MetaRow('CPU', printer.cpuInfo!),

            // ── 状态时间 ──
            const SizedBox(height: 6),
            _MetaRow('最后状态', _formatDateTime(lastStatus)),
            if (serverInfoAge != null)
              _MetaRow('设备信息', '${serverInfoAge.inSeconds}s 前获取'),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 温度仪表
// ═══════════════════════════════════════════════════════════════

class _TemperatureSection extends StatelessWidget {
  final FarmPrinterState printer;
  const _TemperatureSection({required this.printer});

  @override
  Widget build(BuildContext context) {
    final extruders = printer.extruders;
    final hasBed = printer.bedTemp != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('温度', style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),

            // 挤出机
            if (extruders.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: extruders.map((ext) => Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: _TemperatureGauge(
                      label: extruders.length == 1 ? '喷嘴' : 'E${ext.index}',
                      current: ext.currentTemp,
                      target: ext.targetTemp,
                      isStale: ext.isStale,
                      color: _extruderColor(ext.index),
                    ),
                  )).toList(),
                ),
              ),
              if (hasBed) const SizedBox(height: 12),
            ],

            // 热床
            if (hasBed)
              _TemperatureGauge(
                label: '热床',
                current: printer.bedTemp?.value ?? 0,
                target: printer.bedTarget?.value,
                isStale: printer.bedTemp?.isStale ?? false,
                color: Colors.orange,
              ),
          ],
        ),
      ),
    );
  }

  Color _extruderColor(int index) {
    const colors = [Colors.red, Colors.blue, Colors.green, Colors.purple, Colors.teal];
    return colors[(index - 1) % colors.length];
  }
}

class _TemperatureGauge extends StatelessWidget {
  final String label;
  final double current;
  final double? target;
  final bool isStale;
  final Color color;

  const _TemperatureGauge({
    required this.label,
    required this.current,
    this.target,
    this.isStale = false,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isHeating = target != null && (current - target!).abs() > 1.0;
    return Column(
      children: [
        SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: CircularProgressIndicator(
                  value: (target != null && target! > 0)
                      ? (current / target!).clamp(0.0, 1.2) / 1.2
                      : null,
                  strokeWidth: 6,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(
                    isStale ? Colors.grey : (isHeating ? Colors.orange : color),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${current.toStringAsFixed(0)}°',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isStale ? Colors.grey : null,
                    ),
                  ),
                  if (target != null)
                    Text(
                      '/${target!.toStringAsFixed(0)}°',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        if (isStale)
          Text('(过期)', style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 打印进度
// ═══════════════════════════════════════════════════════════════

class _PrintProgressSection extends StatelessWidget {
  final FarmPrinterState printer;
  const _PrintProgressSection({required this.printer});

  @override
  Widget build(BuildContext context) {
    final progress = printer.progress?.value ?? 0.0;
    final file = printer.currentFile?.value ?? '未知文件';
    final layers = (printer.layerNum != null && printer.totalLayers != null)
        ? '${printer.layerNum!.value} / ${printer.totalLayers!.value} 层'
        : null;
    final eta = printer.estimatedTime?.value;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('打印进度', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  '${(progress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 12),
            _MetaRow('文件', file),
            if (layers != null) _MetaRow('层数', layers),
            if (eta != null)
              _MetaRow('预估剩余', '${eta.toStringAsFixed(0)} 秒'),
            if (printer.totalDuration != null)
              _MetaRow('已用时间', '${(printer.totalDuration! / 60).toStringAsFixed(1)} 分钟'),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 手动控制
// ═══════════════════════════════════════════════════════════════

class _ManualControlSection extends StatefulWidget {
  final String sn;
  const _ManualControlSection({required this.sn});

  @override
  State<_ManualControlSection> createState() => _ManualControlSectionState();
}

class _ManualControlSectionState extends State<_ManualControlSection> {
  final _gcodeController = TextEditingController();
  final _tempController = TextEditingController(text: '210');
  bool _isSending = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _gcodeController.dispose();
    _tempController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('手动控制', style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),

            // 急停按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isSending ? null : () {
                  // TODO: 调用 batchEmergencyStop
                },
                icon: const Icon(Icons.warning_amber, color: Colors.red),
                label: const Text('紧急停止', style: TextStyle(color: Colors.red)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 温度控制
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _tempController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '温度 °C',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isSending ? null : () {},
                  icon: const Icon(Icons.whatshot, size: 18),
                  label: const Text('设置喷嘴'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isSending ? null : () {},
                  icon: const Icon(Icons.heat_pump, size: 18),
                  label: const Text('设置热床'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // GCode 发送
            TextField(
              controller: _gcodeController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'GCode 指令',
                hintText: '例如: G28 (归零)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _GcodeChip('G28', '归零'),
                const SizedBox(width: 6),
                _GcodeChip('G90', '绝对定位'),
                const SizedBox(width: 6),
                _GcodeChip('G91', '相对定位'),
                const SizedBox(width: 6),
                _GcodeChip('M106 S255', '风扇全速'),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _isSending || _gcodeController.text.isEmpty
                      ? null
                      : () {
                          setState(() => _isSending = true);
                          Future.delayed(const Duration(seconds: 1), () {
                            if (!_disposed && mounted) setState(() => _isSending = false);
                          });
                        },
                  icon: _isSending
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send, size: 16),
                  label: const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GcodeChip extends StatelessWidget {
  final String gcode;
  final String label;
  const _GcodeChip(this.gcode, this.label);

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: () {},
      visualDensity: VisualDensity.compact,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 事件时间线
// ═══════════════════════════════════════════════════════════════

class _EventTimeline extends StatelessWidget {
  final FarmPrinterState printer;
  const _EventTimeline({required this.printer});

  @override
  Widget build(BuildContext context) {
    final snapshots = printer.snapshots;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('事件时间线',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${snapshots.length} 条',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
              ],
            ),
            const Divider(),
            if (snapshots.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: Text('暂无事件', style: TextStyle(color: Colors.grey)),
                ),
              )
            else
              SizedBox(
                height: 300,
                child: ListView.separated(
                  itemCount: snapshots.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    // 倒序：最新事件在前
                    final snapshot = snapshots[snapshots.length - 1 - i];
                    return _EventRow(snapshot: snapshot);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final FarmSnapshot snapshot;
  const _EventRow({required this.snapshot});

  Color get _color {
    final reason = snapshot.reason;
    if (reason.contains('离线') || reason.contains('offline') || reason.contains('失败')) {
      return const Color(0xFFF40004);
    }
    if (reason.contains('上线') || reason.contains('online') || reason.contains('发现')) {
      return const Color(0xFF00D4AA);
    }
    if (reason.contains('状态变更') || reason.contains('打印')) {
      return const Color(0xFF0C63E2);
    }
    if (reason.contains('信息更新') || reason.contains('batch')) {
      return const Color(0xFFFF9900);
    }
    return const Color(0xFF999999);
  }

  @override
  Widget build(BuildContext context) {
    final ts = '${snapshot.timestamp.hour.toString().padLeft(2, '0')}:'
        '${snapshot.timestamp.minute.toString().padLeft(2, '0')}:'
        '${snapshot.timestamp.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(shape: BoxShape.circle, color: _color),
          ),
          const SizedBox(width: 8),
          Text(ts,
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF999999), fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: _color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(snapshot.reason,
                style: TextStyle(fontSize: 10, color: _color)),
          ),
          if (snapshot.context != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(snapshot.context!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 摄像头区块
// ═══════════════════════════════════════════════════════════════

class _CameraSection extends ConsumerStatefulWidget {
  final String sn;
  final String ip;
  final int port;

  const _CameraSection({
    required this.sn,
    required this.ip,
    required this.port,
  });

  @override
  ConsumerState<_CameraSection> createState() => _CameraSectionState();
}

class _CameraSectionState extends ConsumerState<_CameraSection> {
  bool _isActive = false;
  String? _frameUrl;
  bool _isStarting = false;
  bool _isResolving = false;
  String? _error;

  /// 可用作摄像头 HTTP 请求的真实 IP（覆盖占位符如 'MQTT'）
  late String _effectiveIp;
  late final TextEditingController _ipController;

  bool get _ipIsValid {
    final ip = _effectiveIp.trim();
    return RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(ip);
  }

  @override
  void initState() {
    super.initState();
    _effectiveIp = widget.ip;
    _ipController = TextEditingController(text: widget.ip);
  }

  @override
  void dispose() {
    _ipController.dispose();
    if (_isActive) {
      _isActive = false;
      _frameUrl = null;
      final cameraService = ref.read(cameraServiceProvider);
      if (cameraService != null) {
        cameraService.stopMonitor(
          sn: widget.sn,
          ip: _effectiveIp.trim(),
          port: widget.port,
        );
      }
    }
    super.dispose();
  }

  Future<void> _toggleCamera() async {
    if (_isActive) {
      await _stopCamera();
    } else {
      await _startCamera();
    }
  }

  Future<void> _startCamera() async {
    setState(() {
      _isStarting = true;
      _error = null;
    });

    final cameraService = ref.read(cameraServiceProvider);
    if (cameraService == null) {
      setState(() {
        _isStarting = false;
        _error = 'MQTT 未连接，无法发送摄像头命令';
      });
      return;
    }

    final result = await cameraService.startMonitor(
      sn: widget.sn,
      ip: _effectiveIp.trim(),
      port: widget.port,
    );

    if (!mounted) return;

    if (result.success && result.frameUrl != null) {
      setState(() {
        _frameUrl = result.frameUrl;
        _isActive = true;
        _isStarting = false;
      });
    } else {
      setState(() {
        _isStarting = false;
        _error = result.error ?? '摄像头启动失败，请检查打印机是否支持摄像头';
      });
    }
  }

  Future<void> _stopCamera() async {
    if (_frameUrl != null && _isActive) {
      final cameraService = ref.read(cameraServiceProvider);
      await cameraService?.stopMonitor(
        sn: widget.sn,
        ip: _effectiveIp.trim(),
        port: widget.port,
      );
    }
    if (mounted) {
      setState(() {
        _isActive = false;
        _frameUrl = null;
        _error = null;
      });
    }
  }

  /// 解析打印机真实 LAN IP
  ///
  /// MQTT machine.system_info 优先（设备在线即可秒回）；
  /// 降级到子网扫描 + /server/info SN 匹配。
  Future<void> _resolveIp() async {
    setState(() => _isResolving = true);

    try {
      String? ip;

      // 1) MQTT 优先 — 直接问设备要网络信息
      final cameraService = ref.read(cameraServiceProvider);
      if (cameraService != null) {
        ip = await cameraService.resolveDeviceIp(widget.sn);
      }

      // 2) 降级：子网扫描
      if (ip == null) {
        ip = await PrinterDiscovery.resolveIpBySn(widget.sn);
      }

      if (!mounted) return;

      if (ip != null) {
        final resolved = ip;
        setState(() {
          _effectiveIp = resolved;
          _ipController.text = resolved;
          _isResolving = false;
        });
        ref.read(printerRegistryProvider.notifier)
            .updatePrinter(widget.sn, (p) { p.ip = resolved; return p; });
      } else {
        setState(() => _isResolving = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('实时摄像头',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                _isActive
                    ? TextButton.icon(
                        onPressed: _toggleCamera,
                        icon: const Icon(Icons.videocam_off, size: 18),
                        label: const Text('关闭'),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                      )
                    : ElevatedButton.icon(
                        onPressed: _isStarting ? null : _toggleCamera,
                        icon: _isStarting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.videocam, size: 18),
                        label: Text(_isStarting ? '开启中...' : '开启实时摄像头'),
                      ),
              ],
            ),
            const SizedBox(height: 8),

            if (!_ipIsValid)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.lan, size: 16, color: Colors.orange),
                    const SizedBox(width: 8),
                    const Text('设备 IP: ',
                        style: TextStyle(fontSize: 13, color: Colors.orange)),
                    SizedBox(
                      width: 140,
                      height: 32,
                      child: TextField(
                        controller: _ipController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: '如 172.18.4.46',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        ),
                        style: const TextStyle(fontSize: 13),
                        onChanged: (v) => setState(() => _effectiveIp = v),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      height: 32,
                      child: _isResolving
                          ? const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : TextButton.icon(
                              onPressed: _resolveIp,
                              icon: const Icon(Icons.wifi_find, size: 16),
                              label: const Text('扫描', style: TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                    ),
                  ],
                ),
              ),

            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: Colors.red.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: _startCamera,
                      child: const Text('重试', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),

            if (_isActive && _frameUrl != null)
              CameraView(
                frameUrl: _frameUrl!,
                isActive: _isActive,
              ),

            if (!_isActive && _error == null)
              Container(
                width: double.infinity,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.videocam, size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 8),
                    Text(
                      '点击上方按钮开启摄像头实时画面',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 完整状态快照卡片
// ═══════════════════════════════════════════════════════════════

/// 展示 rawStateSnapshot 中的所有字段
///
/// 分两组：
/// - 已在 updateTelemetry 中提取的字段（绿色标记）
/// - 未提取的额外字段（橙色标记），用于调试发现新数据源
class _RawStateSnapshotCard extends StatefulWidget {
  final FarmPrinterState printer;
  const _RawStateSnapshotCard({required this.printer});

  @override
  State<_RawStateSnapshotCard> createState() => _RawStateSnapshotCardState();
}

class _RawStateSnapshotCardState extends State<_RawStateSnapshotCard> {
  bool _expanded = false;

  /// updateTelemetry 中已提取的键前缀集合
  static const _extractedPrefixes = {
    'extruder.temperature', 'extruder.target',
    'heater_bed.temperature', 'heater_bed.target',
    'print_stats.state', 'print_stats.filename',
    'print_stats.total_duration', 'print_stats.filament_used',
    'print_stats.info.layer_num', 'print_stats.info.total_layer',
    'virtual_sdcard.progress',
  };

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.printer.rawStateSnapshot;
    if (snapshot == null || snapshot.isEmpty) return const SizedBox.shrink();

    final keys = snapshot.keys.toList()..sort();

    final extracted = <String>[];
    final extra = <String>[];
    for (final k in keys) {
      if (_extractedPrefixes.any((p) => k.startsWith(p))) {
        extracted.add(k);
      } else {
        extra.add(k);
      }
    }

    final age = widget.printer.rawStateSnapshotTime != null
        ? DateTime.now().difference(widget.printer.rawStateSnapshotTime!)
        : null;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.storage, size: 16, color: Color(0xFF0C63E2)),
                  const SizedBox(width: 6),
                  const Text('完整状态快照',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${keys.length} 字段',
                      style: TextStyle(fontSize: 10, color: Colors.blue.shade700),
                    ),
                  ),
                  if (extra.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '+${extra.length} 未提取',
                        style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (age != null)
                    Text(
                      '${age.inSeconds}s 前',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (extracted.isNotEmpty) ...[
                    Text('已提取字段',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.green.shade700)),
                    const SizedBox(height: 4),
                    ...extracted.map((k) => _SnapshotFieldRow(
                          keyName: k,
                          value: snapshot[k],
                          isExtracted: true,
                        )),
                    const SizedBox(height: 8),
                  ],
                  if (extra.isNotEmpty) ...[
                    Text('额外字段（未在 updateTelemetry 中提取）',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange.shade700)),
                    const SizedBox(height: 4),
                    ...extra.map((k) => _SnapshotFieldRow(
                          keyName: k,
                          value: snapshot[k],
                          isExtracted: false,
                        )),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 快照字段行
class _SnapshotFieldRow extends StatelessWidget {
  final String keyName;
  final dynamic value;
  final bool isExtracted;

  const _SnapshotFieldRow({
    required this.keyName,
    required this.value,
    required this.isExtracted,
  });

  @override
  Widget build(BuildContext context) {
    final displayValue = value is Map || value is List
        ? const JsonEncoder.withIndent('  ').convert(value)
        : value.toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 5, right: 6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isExtracted ? Colors.green.shade400 : Colors.orange.shade300,
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: keyName,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: isExtracted ? Colors.green.shade800 : Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  TextSpan(
                    text: '  →  ',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                  TextSpan(
                    text: displayValue.length > 80
                        ? '${displayValue.substring(0, 80)}…'
                        : displayValue,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 原始消息历史卡片
// ═══════════════════════════════════════════════════════════════

/// 展示 rawMessages 环形缓冲中的历史消息
///
/// 每条消息显示时间戳 + 方法名 + 可展开的 JSON 内容
class _RawMessageHistoryCard extends StatefulWidget {
  final FarmPrinterState printer;
  const _RawMessageHistoryCard({required this.printer});

  @override
  State<_RawMessageHistoryCard> createState() => _RawMessageHistoryCardState();
}

class _RawMessageHistoryCardState extends State<_RawMessageHistoryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final messages = widget.printer.rawMessages;
    if (messages.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.history, size: 16, color: Color(0xFF0C63E2)),
                  const SizedBox(width: 6),
                  const Text('原始消息历史',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${messages.length} 条',
                      style: TextStyle(fontSize: 10, color: Colors.purple.shade700),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            SizedBox(
              height: 300,
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: messages.length,
                itemBuilder: (_, index) {
                  final msg = messages[messages.length - 1 - index];
                  return _RawMessageTile(
                    message: msg,
                    index: messages.length - index,
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单条原始消息
class _RawMessageTile extends StatefulWidget {
  final Map<String, dynamic> message;
  final int index;

  const _RawMessageTile({required this.message, required this.index});

  @override
  State<_RawMessageTile> createState() => _RawMessageTileState();
}

class _RawMessageTileState extends State<_RawMessageTile> {
  bool _jsonExpanded = false;

  @override
  Widget build(BuildContext context) {
    final method = widget.message['method'] as String? ?? '?';
    final params = widget.message['params'];

    DateTime? msgTime;
    if (params is List && params.length >= 2 && params[1] is num) {
      msgTime = DateTime.fromMillisecondsSinceEpoch(
        ((params[1] as num) * 1000).toInt(),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _jsonExpanded = !_jsonExpanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.blue.shade100,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '#${widget.index}',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade700),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      method,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (msgTime != null)
                    Text(
                      '${msgTime.hour.toString().padLeft(2, '0')}:'
                      '${msgTime.minute.toString().padLeft(2, '0')}:'
                      '${msgTime.second.toString().padLeft(2, '0')}',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _jsonExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (_jsonExpanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(6),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      GestureDetector(
                        onTap: () {
                          final jsonStr =
                              const JsonEncoder.withIndent('  ').convert(widget.message);
                          Clipboard.setData(ClipboardData(text: jsonStr));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制完整 JSON'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.copy, size: 12, color: Colors.white70),
                              SizedBox(width: 4),
                              Text('复制',
                                  style: TextStyle(
                                      fontSize: 10, color: Colors.white70)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(widget.message),
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Color(0xFFD4D4D4),
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
