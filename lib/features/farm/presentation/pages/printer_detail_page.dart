/// 单打印机详情页
///
/// 显示内容:
/// - 设备元数据卡片（SN / IP / 型号 / 固件 / Moonraker 信息）
/// - 实时温度仪表
/// - 摄像头实时画面（定时轮询 server/files/camera/monitor.jpg）
/// - 打印进度条 + 预估剩余时间
/// - 事件时间线（连接 / 状态变更 / 错误）
/// - 手动控制面板（归零 / 设置温度 / 发送 GCode）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/bed_inspection_provider.dart';
import '../../data/farm_printer_state.dart';
import '../../data/camera_service.dart';
import '../../data/printer_discovery.dart';
import '../../data/printer_info.dart';
import '../../domain/models/bed_inspection_result.dart';
import '../widgets/thumbnail_image.dart';
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
    // 进入详情 → 按需拉取全量状态 + 自动 AI 床板检测
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final router = ref.read(farmMqttRouterProvider);
      router?.fetchFullState(widget.sn);
      ref.read(bedInspectionResultsProvider.notifier).inspectOne(widget.sn);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 监听 FarmStore 版本号 + 读取该打印机状态
    ref.watch(farmStoreVersionProvider);
    final printer = ref.read(farmStoreProvider).getPrinter(widget.sn);
    final inspectionResult = ref.watch(bedInspectionResultProvider(widget.sn));
    final isInspecting = ref.watch(bedInspectionLoadingProvider);

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

            // ── 区块 2.5: 床板 AI 异物检测 ──
            if (printer.isOnline) ...[
              _InspectionCard(
                result: inspectionResult,
                isInspecting: isInspecting,
                onRefresh: () {
                  ref.read(bedInspectionResultsProvider.notifier).inspectOne(widget.sn);
                },
              ),
              if (inspectionResult != null || isInspecting) const SizedBox(height: 16),
            ],

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
            if (printer.hasPrintJob) ...[
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
            _IpRefreshRow(sn: printer.sn, ip: printer.ip, port: printer.port),
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

            // ── 设备实时状态 ──
            if (printer.fanSpeed != null || printer.toolheadPosition != null) ...[
              const SizedBox(height: 6),
              if (printer.fanSpeed != null)
                _MetaRow('风扇', '${(printer.fanSpeed!.value * 100).toInt()}% · ${printer.fanRpm?.value.toInt() ?? 0} RPM'),
              if (printer.toolheadPosition != null)
                _MetaRow('位置', 'X${printer.toolheadPosition!.value[0].toStringAsFixed(1)} Y${printer.toolheadPosition!.value[1].toStringAsFixed(1)}'),
              if (printer.homedAxes != null)
                _MetaRow('归零轴', printer.homedAxes!.value),
            ],
            if (printer.purifierMode != null) ...[
              const SizedBox(height: 6),
              _MetaRow('净化器', '模式${printer.purifierMode!.value} · 电压${printer.purifierPowerDetValue?.value.toStringAsFixed(1) ?? "?"}V'),
            ],
            if (printer.fileSize != null)
              _MetaRow('文件大小', '${(printer.fileSize!.value / 1024 / 1024).toStringAsFixed(1)} MB'),

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

/// IP 地址行（带刷新按钮）
class _IpRefreshRow extends ConsumerStatefulWidget {
  final String sn;
  final String ip;
  final int port;

  const _IpRefreshRow({
    required this.sn,
    required this.ip,
    required this.port,
  });

  @override
  ConsumerState<_IpRefreshRow> createState() => _IpRefreshRowState();
}

class _IpRefreshRowState extends ConsumerState<_IpRefreshRow> {
  bool _resolving = false;

  Future<void> _refreshIp() async {
    if (_resolving) return;
    setState(() => _resolving = true);

    try {
      final router = ref.read(farmMqttRouterProvider);
      if (router == null) return;

      final result = await router.sendCommand(widget.sn, 'machine.system_info');
      if (!mounted) return;

      if (result.success && result.data != null) {
        final sysInfo = result.data!['system_info'] as Map<String, dynamic>?;
        final network = sysInfo?['network'] as Map<String, dynamic>?;
        if (network == null) return;

        String? resolved;
        for (final entry in network.entries) {
          final iface = entry.value as Map<String, dynamic>?;
          final addresses = iface?['ip_addresses'] as List?;
          if (addresses == null) continue;

          for (final addr in addresses) {
            if (addr is Map<String, dynamic> &&
                addr['family'] == 'ipv4' &&
                addr['is_link_local'] != true) {
              final ip = addr['address'] as String?;
              if (ip != null && ip != '127.0.0.1') {
                resolved = ip;
                break;
              }
            }
          }
          if (resolved != null) break;
        }

        if (resolved != null) {
          final store = ref.read(farmStoreProvider);
          store.updatePrinter(widget.sn, (p) {
            p.ip = resolved!;
            return p;
          });
          // 同步更新 ipCache
          router.ipCache[widget.sn] = resolved;
          router.persistIp(widget.sn, resolved);
        }
      }
    } catch (e) {
      debugPrint('[_IpRefreshRow] IP 刷新失败: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(
            width: 72,
            child: Text('IP 地址',
                style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
          ),
          Expanded(
            child: Text(
              '${widget.ip}:${widget.port}',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'monospace'),
            ),
          ),
          SizedBox(
            width: 24,
            height: 24,
            child: _resolving
                ? const Padding(
                    padding: EdgeInsets.all(4),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新 IP',
                    onPressed: _refreshIp,
                  ),
          ),
        ],
      ),
    );
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
// 打印控制模块（缩略图 + 进度 + 层数 + 时间 + 暂停/取消）
// ═══════════════════════════════════════════════════════════════

class _PrintProgressSection extends ConsumerStatefulWidget {
  final FarmPrinterState printer;
  const _PrintProgressSection({required this.printer});

  @override
  ConsumerState<_PrintProgressSection> createState() => _PrintProgressSectionState();
}

class _PrintProgressSectionState extends ConsumerState<_PrintProgressSection> {
  bool _isBusy = false;

  Future<void> _pause() async {
    setState(() => _isBusy = true);
    final router = ref.read(farmMqttRouterProvider);
    await router?.sendCommand(widget.printer.sn, 'printer.print.pause');
    if (mounted) setState(() => _isBusy = false);
  }

  Future<void> _resume() async {
    setState(() => _isBusy = true);
    final router = ref.read(farmMqttRouterProvider);
    await router?.sendCommand(widget.printer.sn, 'printer.print.resume');
    if (mounted) setState(() => _isBusy = false);
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认取消打印？'),
        content: const Text('此操作将停止当前打印任务，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认取消'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _isBusy = true);
    final router = ref.read(farmMqttRouterProvider);
    await router?.sendCommand(widget.printer.sn, 'printer.print.cancel');
    if (mounted) setState(() => _isBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.printer;
    final progress = p.progress?.value ?? 0.0;
    final file = p.currentFile?.value ?? '未知文件';
    final layer = p.layerNum?.value;
    final totalLayer = p.totalLayers?.value;
    final isPaused = p.printState?.value == 'paused';

    // 剩余时间：优先用 estimated_time，否则根据进度推算
    String etaText = '--';
    if (p.estimatedTime?.value != null && p.estimatedTime!.value > 0) {
      final secs = p.estimatedTime!.value.toInt();
      etaText = '${secs ~/ 60}分${secs % 60}秒';
    } else if (p.printDuration?.value != null && progress > 0) {
      final elapsed = p.printDuration!.value;
      final remaining = elapsed / progress - elapsed;
      if (remaining > 0) {
        final secs = remaining.toInt();
        etaText = '${secs ~/ 60}分${secs % 60}秒';
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题行 ──
            Row(
              children: [
                const Icon(Icons.print, size: 18, color: Color(0xFF0C63E2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '打印控制',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isPaused ? Colors.orange.shade50 : Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isPaused ? '⏸ 已暂停' : '🖨 打印中',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isPaused ? Colors.orange.shade700 : Colors.green.shade700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── 缩略图 + 进度环 ──
            Row(
              children: [
                // ── 缩略图 ──
                PrintThumbnail(
                  sn: p.sn,
                  filename: p.currentFile?.value,
                  ip: p.ip,
                  port: p.port,
                  width: 80,
                  height: 80,
                ),
                const SizedBox(width: 16),
                // 进度 + 百分比
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${(progress * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 10,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation(
                            isPaused ? Colors.orange : const Color(0xFF0C63E2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── 文件信息 ──
            Text(file, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),

            // ── 指标行：层数 / 剩余时间 ──
            Row(
              children: [
                _MetricChip(
                  icon: Icons.layers,
                  label: '层数',
                  value: layer != null && totalLayer != null
                      ? '$layer / $totalLayer'
                      : '--',
                ),
                const SizedBox(width: 12),
                _MetricChip(
                  icon: Icons.timer,
                  label: '剩余时间',
                  value: etaText,
                ),
                const SizedBox(width: 12),
                _MetricChip(
                  icon: Icons.speed,
                  label: '文件大小',
                  value: p.fileSize != null
                      ? '${(p.fileSize!.value / 1024 / 1024).toStringAsFixed(1)} MB'
                      : '--',
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── 控制按钮 ──
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy ? null : (isPaused ? _resume : _pause),
                    icon: Icon(isPaused ? Icons.play_arrow : Icons.pause, size: 18),
                    label: Text(isPaused ? '继续' : '暂停'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy ? null : _cancel,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('取消'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _MetricChip({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: Colors.grey.shade600),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
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
  String? _frameUrl; // 轮询快照 URL
  bool _isStarting = false;
  bool _isResolving = false;
  String? _error;
  Timer? _pollTimer;

  // 双缓冲：始终显示 front buffer，back buffer 静默加载下一帧
  Uint8List? _bufferA;
  Uint8List? _bufferB;
  bool _showBufferA = true;
  bool _isLoadingFrame = false;
  final HttpClient _frameHttpClient = HttpClient();

  /// 可用作摄像头 HTTP 请求的真实 IP（覆盖占位符如 'MQTT'）
  late String _effectiveIp;
  late final TextEditingController _ipController;

  bool get _ipIsValid {
    final ip = _effectiveIp.trim();
    return RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(ip);
  }

  /// 缓存 cameraService 引用（dispose 时 ref 可能已失效）
  CameraService? _cachedCameraService;

  @override
  void initState() {
    super.initState();
    _effectiveIp = widget.ip;
    _ipController = TextEditingController(text: widget.ip);
  }

  @override
  void dispose() {
    _ipController.dispose();
    _pollTimer?.cancel();
    _pollTimer = null;
    _frameHttpClient.close();
    _bufferA = null;
    _bufferB = null;
    if (_isActive) {
      _isActive = false;
      _frameUrl = null;
      _cachedCameraService?.stopMonitor(
        sn: widget.sn,
        ip: _effectiveIp.trim(),
        port: widget.port,
      );
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

    _cachedCameraService = ref.read(cameraServiceProvider);
    if (_cachedCameraService == null) {
      setState(() {
        _isStarting = false;
        _error = 'MQTT 未连接，无法发送摄像头命令';
      });
      return;
    }

    final result = await _cachedCameraService!.startMonitor(
      sn: widget.sn,
      ip: _effectiveIp.trim(),
      port: widget.port,
    );

    if (!mounted) return;

    if (result.success && result.frameUrl != null) {
      // 重置双缓冲
      _bufferA = null;
      _bufferB = null;
      _showBufferA = true;
      _isLoadingFrame = false;

      setState(() {
        _frameUrl = result.frameUrl;
        _isActive = true;
        _isStarting = false;
      });

      // 立即拉第一帧，之后每 500ms 拉一帧（双缓冲，无闪烁）
      _fetchNextFrame();
      _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _fetchNextFrame();
      });
    } else {
      setState(() {
        _isStarting = false;
        _error = result.error ?? '摄像头启动失败，请检查打印机是否支持摄像头';
      });
    }
  }

  /// 下载下一帧到隐藏 buffer，加载完成后交换显示
  Future<void> _fetchNextFrame() async {
    if (!_isActive || _frameUrl == null || _isLoadingFrame) return;

    _isLoadingFrame = true;
    final loadIntoA = !_showBufferA; // 加载到当前隐藏的 buffer

    try {
      final uri = Uri.parse('${_frameUrl!}?ts=${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
      final request = await _frameHttpClient.getUrl(uri);
      request.headers.set('Accept', 'image/jpeg, image/png, image/*');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode != 200) {
        if (mounted) {
          setState(() => _isLoadingFrame = false);
        }
        return;
      }

      final bytes = await response.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );

      if (!mounted) return;
      if (!_isActive) {
        _isLoadingFrame = false;
        return;
      }

      final imageData = Uint8List.fromList(bytes);
      setState(() {
        if (loadIntoA) {
          _bufferA = imageData;
        } else {
          _bufferB = imageData;
        }
        _showBufferA = loadIntoA; // 交换：显示刚加载完的 buffer
        _isLoadingFrame = false;
      });
    } catch (e) {
      debugPrint('[CameraSection] 帧下载失败: $e');
      if (mounted) {
        setState(() => _isLoadingFrame = false);
      }
    }
  }

  Future<void> _stopCamera() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isLoadingFrame = false;
    if (_isActive) {
      await _cachedCameraService?.stopMonitor(
        sn: widget.sn,
        ip: _effectiveIp.trim(),
        port: widget.port,
      );
    }
    if (mounted) {
      setState(() {
        _isActive = false;
        _frameUrl = null;
        _bufferA = null;
        _bufferB = null;
        _error = null;
      });
    }
  }

  /// 双缓冲摄像头画面显示
  ///
  /// 始终显示 front buffer（已加载完的帧），后台静默加载下一帧到 back buffer，
  /// 加载完成后交换，消除 Image.network 的闪烁问题。
  Widget _buildCameraFrame() {
    final currentImage = _showBufferA ? _bufferA : _bufferB;

    if (currentImage != null) {
      return Image.memory(
        currentImage,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => Container(
          height: 240,
          color: Colors.grey.shade100,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image, size: 40, color: Colors.grey.shade400),
                const SizedBox(height: 8),
                Text('无法加载摄像头画面',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    }

    // 首帧尚未加载完成，显示 loading
    return Container(
      height: 240,
      color: Colors.grey.shade100,
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
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
        ref.read(farmStoreProvider)
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
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _buildCameraFrame(),
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
// 床板 AI 异物检测卡片
// ═══════════════════════════════════════════════════════════════

class _InspectionCard extends StatelessWidget {
  final BedInspectionResult? result;
  final bool isInspecting;
  final VoidCallback onRefresh;

  const _InspectionCard({
    this.result,
    required this.isInspecting,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    // 无结果且不在检测中 → 不显示
    if (result == null && !isInspecting) return const SizedBox.shrink();

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: _borderColor,
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(_statusIcon, size: 20, color: _statusColor),
                    const SizedBox(width: 6),
                    Text(
                      'AI 床板检测',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _statusColor,
                      ),
                    ),
                  ],
                ),
                // 刷新按钮
                InkWell(
                  onTap: isInspecting ? null : onRefresh,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: isInspecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.refresh, size: 18, color: Colors.grey.shade600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 内容区
            if (isInspecting && result == null) ...[
              _buildSkeleton(),
            ] else if (result != null) ...[
              _buildResult(result!),
            ],
          ],
        ),
      ),
    );
  }

  Color get _borderColor {
    if (isInspecting && result == null) return Colors.grey.shade300;
    if (result == null) return Colors.grey.shade300;
    if (result!.hasForeignObjects) return Colors.red.shade300;
    return Colors.green.shade300;
  }

  Color get _statusColor {
    if (isInspecting && result == null) return Colors.grey;
    if (result == null) return Colors.grey;
    if (result!.hasForeignObjects) return Colors.red;
    return Colors.green;
  }

  IconData get _statusIcon {
    if (isInspecting && result == null) return Icons.search;
    if (result == null) return Icons.help_outline;
    if (result!.hasForeignObjects) return Icons.warning_amber_rounded;
    if (result!.printReadiness.caution) return Icons.check_circle_outline;
    return Icons.check_circle;
  }

  Widget _buildSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 14,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 14,
          width: 200,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'AI 正在分析床板照片，检测是否有异物…',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildResult(BedInspectionResult r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 异物状态
        if (r.hasForeignObjects) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '⚠ 检测到异物',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade700,
                    fontSize: 14,
                  ),
                ),
                if (r.bedForeignObjects.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    r.bedForeignObjects.description,
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ] else ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
                const SizedBox(width: 6),
                Text(
                  r.printReadiness.caution ? '床板基本干净（注意）' : '床板干净',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],

        // 就绪判断
        const SizedBox(height: 8),
        Row(
          children: [
            _buildBadge(r.printReadiness.recommendedActionLabel),
            const SizedBox(width: 8),
            if (r.printReadiness.reason.isNotEmpty)
              Expanded(
                child: Tooltip(
                  message: r.printReadiness.reason,
                  child: Text(
                    r.printReadiness.reason,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.blue.shade700,
          fontSize: 12,
          fontWeight: FontWeight.w500,
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

  /// updateTelemetry 中已提取的键前缀集合（精确匹配或前缀匹配）
  static const _extractedPrefixes = {
    // 挤出机（extruder1/2/3 等）
    'extruder1.', 'extruder2.', 'extruder3.', 'extruder4.',
    'extruder.temperature', 'extruder.target',
    // 热床
    'heater_bed.temperature', 'heater_bed.target', 'heater_bed.power',
    // 打印状态
    'print_stats.state', 'print_stats.filename',
    'print_stats.total_duration', 'print_stats.filament_used',
    'print_stats.info.layer_num', 'print_stats.info.total_layer',
    'print_stats.info.current_layer',
    'print_stats.print_duration', 'print_stats.message',
    // 虚拟 SD 卡
    'virtual_sdcard.progress', 'virtual_sdcard.file_path',
    'virtual_sdcard.file_size', 'virtual_sdcard.file_position',
    'virtual_sdcard.is_active',
    // 风扇
    'fan.speed', 'fan.rpm',
    // 工具头
    'toolhead.position', 'toolhead.homed_axes',
    'toolhead.max_accel', 'toolhead.max_velocity',
    'toolhead.estimated_print_time',
    // 净化器
    'purifier.mode', 'purifier.power_det_value', 'purifier.power_detected',
    // Snapmaker 特有
    'display_status.progress',
    'extruder.power',
    'gcode_move.speed',
    'idle_timeout.printing_time',
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
            // ── 全量 JSON 区（可选择复制）──
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Text('全量 JSON', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _CopyButton(
                    label: '复制全部',
                    data: const JsonEncoder.withIndent('  ').convert(snapshot),
                  ),
                  const SizedBox(width: 6),
                  _CopyButton(
                    label: '复制额外',
                    data: const JsonEncoder.withIndent('  ').convert({for (final k in extra) k: snapshot[k]}),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 300),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(snapshot),
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Color(0xFFD4D4D4),
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            // ── 分类字段列表 ──
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
                    Row(
                      children: [
                        Text('额外字段（未在 updateTelemetry 中提取）',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.orange.shade700)),
                        const Spacer(),
                        _CopyButton(
                          label: '复制',
                          data: const JsonEncoder.withIndent('  ')
                              .convert({for (final k in extra) k: snapshot[k]}),
                        ),
                      ],
                    ),
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

// ═══════════════════════════════════════════════════════════════
// 复制按钮
// ═══════════════════════════════════════════════════════════════

class _CopyButton extends StatelessWidget {
  final String label;
  final String data;
  const _CopyButton({required this.label, required this.data});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: data));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("$label 已复制"), duration: const Duration(seconds: 1)),
        );
      },
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.copy, size: 12, color: Colors.grey.shade600),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
