/// 单打印机详情页 (T11.4)
///
/// 显示内容:
/// - 实时温度曲线（模拟）
/// - 打印进度条 + 预估剩余时间
/// - 快照历史时间线
/// - 手动控制面板（归零 / 移动轴 / 设置温度 / 发送 GCode）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/printer_list_provider.dart';
import '../../data/farm_printer_state.dart';
import '../../data/printer_info.dart';

/// 打印机详情页
class PrinterDetailPage extends ConsumerWidget {
  final String sn;

  const PrinterDetailPage({super.key, required this.sn});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printer = ref.watch(
      printerRegistryProvider.select((state) => state[sn]),
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
          // 连接状态指示
          _ConnectionChip(printer: printer),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 区块 1: 基本信息 ──
            _InfoSection(printer: printer),
            const SizedBox(height: 20),

            // ── 区块 2: 温度仪表 ──
            _TemperatureSection(printer: printer),
            const SizedBox(height: 20),

            // ── 区块 3: 打印进度 ──
            if (printer.isPrinting) ...[
              _PrintProgressSection(printer: printer),
              const SizedBox(height: 20),
            ],

            // ── 区块 4: 手动控制 ──
            _ManualControlSection(sn: sn),
            const SizedBox(height: 20),

            // ── 区块 5: 快照历史 ──
            _SnapshotTimeline(printer: printer),
          ],
        ),
      ),
    );
  }
}

/// 连接状态 Chip
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

/// 基本信息区块
class _InfoSection extends StatelessWidget {
  final FarmPrinterState printer;
  const _InfoSection({required this.printer});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('设备信息', style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),
            _InfoRow('序列号', printer.sn),
            _InfoRow('IP 地址', '${printer.ip}:${printer.port}'),
            _InfoRow('型号', printer.model ?? '未知'),
            _InfoRow('固件', printer.firmwareVersion ?? '未知'),
            _InfoRow('分组', printer.group ?? '未分组'),
            _InfoRow('通信方式', printer.source.label),
            _InfoRow('状态', printer.connectionState.label),
          ],
        ),
      ),
    );
  }
}

/// 温度仪表区块
class _TemperatureSection extends StatelessWidget {
  final FarmPrinterState printer;
  const _TemperatureSection({required this.printer});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('温度', style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _TemperatureGauge(
                  label: '喷嘴',
                  current: printer.nozzleTemp?.value ?? 0,
                  target: printer.nozzleTarget?.value,
                  isStale: printer.nozzleTemp?.isStale ?? false,
                  color: Colors.red,
                ),
                _TemperatureGauge(
                  label: '热床',
                  current: printer.bedTemp?.value ?? 0,
                  target: printer.bedTarget?.value,
                  isStale: printer.bedTemp?.isStale ?? false,
                  color: Colors.orange,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 温度仪表盘（简化为数字显示 + 进度环）
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

/// 打印进度区块
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
            _InfoRow('文件', file),
            if (layers != null) _InfoRow('层数', layers),
            if (eta != null)
              _InfoRow('预估剩余', '${eta.toStringAsFixed(0)} 秒'),
            if (printer.totalDuration != null)
              _InfoRow('已用时间', '${(printer.totalDuration! / 60).toStringAsFixed(1)} 分钟'),
          ],
        ),
      ),
    );
  }
}

/// 手动控制面板
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

  @override
  void dispose() {
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
                  // TODO: 调用 BatchOperator.batchEmergencyStop
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
                  onPressed: _isSending ? null : () {
                    // TODO: 调用 batchSetNozzleTemp
                  },
                  icon: const Icon(Icons.whatshot, size: 18),
                  label: const Text('设置喷嘴'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isSending ? null : () {
                    // TODO: 调用 batchSetBedTemp
                  },
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
                          // TODO: 调用 batchGcode
                          Future.delayed(const Duration(seconds: 1), () {
                            if (mounted) setState(() => _isSending = false);
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

/// GCode 快捷芯片按钮
class _GcodeChip extends StatelessWidget {
  final String gcode;
  final String label;
  const _GcodeChip(this.gcode, this.label);

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: () {
        // TODO: 调用 batchGcode
      },
      visualDensity: VisualDensity.compact,
    );
  }
}

/// 快照历史时间线
class _SnapshotTimeline extends StatelessWidget {
  final FarmPrinterState printer;
  const _SnapshotTimeline({required this.printer});

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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('事件历史', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  '最近 ${snapshots.length} 条',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
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
              ...snapshots.reversed.take(10).map((snapshot) => ListTile(
                    dense: true,
                    leading: _snapshotIcon(snapshot.reason),
                    title: Text(
                      snapshot.reason,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      _formatTime(snapshot.timestamp),
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: snapshot.context != null
                        ? Text(
                            snapshot.context!,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          )
                        : null,
                  )),
          ],
        ),
      ),
    );
  }

  Widget _snapshotIcon(String reason) {
    if (reason.contains('offline')) return const Icon(Icons.wifi_off, size: 18, color: Colors.red);
    if (reason.contains('failed')) return const Icon(Icons.error, size: 18, color: Colors.red);
    if (reason.contains('batch')) return const Icon(Icons.sync, size: 18, color: Colors.orange);
    return const Icon(Icons.circle, size: 18, color: Colors.grey);
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}

/// 信息行
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
