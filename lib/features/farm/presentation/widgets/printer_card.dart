/// 打印机状态卡片 (T11.1)
///
/// 显示单台打印机的核心信息:
/// - 名称 + SN
/// - 通信模式 badge (MQTT / HTTP)
/// - 喷嘴/热床温度
/// - 打印进度条
/// - 在线状态颜色编码
///
/// 使用 Riverpod select() 精确重建——只有该打印机数据变化时才 rebuild。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/alert_provider.dart';
import '../../application/providers/broker_state_provider.dart';
import '../../data/farm_printer_state.dart';
import '../../data/printer_info.dart';
import 'thumbnail_image.dart';

/// 打印机卡片
///
/// 颜色编码:
///   绿   — 在线待机
///   蓝   — 打印中
///   黄   — 暂停
///   红   — 错误
///   灰   — 离线
class PrinterCard extends ConsumerWidget {
  final String sn;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const PrinterCard({
    super.key,
    required this.sn,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 监听版本号 + 从 FarmStore 读取该打印机状态
    // 100ms 批处理确保最多 10 次/秒重建
    ref.watch(farmStoreVersionProvider);
    final printer = ref.read(farmStoreProvider).getPrinter(sn);

    if (printer == null) {
      return const SizedBox.shrink();
    }

    final statusColor = _statusColor(printer);
    final hasAlert = ref.watch(printerHasAlertProvider(sn));
    final borderColor = isSelected
        ? Colors.blue
        : hasAlert
            ? Colors.red.withOpacity(0.6)
            : statusColor.withOpacity(0.3);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blue.withOpacity(0.05)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: borderColor,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: Colors.blue.withOpacity(0.15), blurRadius: 8)]
              : null,
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 顶部: 名称 + badges ──
            _CardHeader(printer: printer, statusColor: statusColor),
            const SizedBox(height: 8),

            // ── 中部: 温度 ──
            _TemperatureRow(printer: printer),
            const SizedBox(height: 6),

            // ── 底部: 状态 / 进度 ──
            if (printer.isPrinting && printer.progress != null)
              _ProgressSection(printer: printer)
            else
              _StatusLine(printer: printer),
          ],
        ),
      ),
    );
  }

  Color _statusColor(FarmPrinterState p) {
    if (!p.isOnline) return Colors.grey;
    if (p.printState?.value == 'error') return Colors.red;
    if (p.printState?.value == 'paused') return Colors.orange;
    if (p.isPrinting) return Colors.blue;
    return Colors.green;
  }
}

/// 卡片头部：名称 + 通信模式 badge
class _CardHeader extends StatelessWidget {
  final FarmPrinterState printer;
  final Color statusColor;

  const _CardHeader({required this.printer, required this.statusColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 在线状态圆点
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: statusColor,
          ),
        ),
        const SizedBox(width: 6),
        // 名称
        Expanded(
          child: Text(
            printer.displayName ?? printer.sn,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        // 通信模式 badge
        _SourceBadge(source: printer.source),
      ],
    );
  }
}

/// 通信模式标记
class _SourceBadge extends StatelessWidget {
  final Source source;

  const _SourceBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final isHttp = source == Source.http;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: isHttp ? Colors.orange.shade100 : Colors.purple.shade50,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        source.label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: isHttp ? Colors.orange.shade800 : Colors.purple.shade700,
        ),
      ),
    );
  }
}

/// 温度行（多挤出机 + 热床）
class _TemperatureRow extends StatelessWidget {
  final FarmPrinterState printer;

  const _TemperatureRow({required this.printer});

  @override
  Widget build(BuildContext context) {
    final extruders = printer.extruders;
    final bedTemp = printer.bedTemp;
    final bedTarget = printer.bedTarget;

    // 收集所有有数据的挤出机
    final activeExtruders = extruders.where((e) => e.temperature != null).toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // 挤出机温度（紧凑格式：E1 210° E2 25°）
          if (activeExtruders.isNotEmpty)
            ...activeExtruders.map((ext) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _TempDisplay(
                icon: Icons.whatshot,
                current: ext.currentTemp,
                target: ext.targetTemp,
                isStale: ext.isStale,
                unit: extruders.length == 1 ? '°C' : '°',
                label: extruders.length == 1 ? null : 'E${ext.index}',
              ),
            )),
          // 热床温度
          if (bedTemp != null)
            _TempDisplay(
              icon: Icons.heat_pump,
              current: bedTemp.value,
              target: bedTarget?.value,
              isStale: bedTemp.isStale,
              unit: '°C',
            ),
        ],
      ),
    );
  }
}

/// 单个温度显示
class _TempDisplay extends StatelessWidget {
  final IconData icon;
  final double? current;
  final double? target;
  final bool isStale;
  final String unit;
  final String? label;

  const _TempDisplay({
    required this.icon,
    this.current,
    this.target,
    this.isStale = false,
    required this.unit,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    if (current == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.grey.shade400),
          const SizedBox(width: 2),
          Text('--$unit', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
        ],
      );
    }

    final isHeating = target != null && (current! - target!).abs() > 1.0;
    final color = isStale
        ? Colors.grey
        : isHeating
            ? Colors.orange
            : Colors.green;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!, style: TextStyle(fontSize: 9, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
          const SizedBox(width: 2),
        ],
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 2),
        Text(
          '${current!.toStringAsFixed(0)}$unit',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isStale ? Colors.grey : null,
          ),
        ),
        if (target != null) ...[
          Text(
            '/${target!.toStringAsFixed(0)}',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
          ),
        ],
        if (isStale)
          Text(' (过期)', style: TextStyle(fontSize: 9, color: Colors.grey.shade400)),
      ],
    );
  }
}

/// 打印进度条
class _ProgressSection extends StatelessWidget {
  final FarmPrinterState printer;

  const _ProgressSection({required this.printer});

  @override
  Widget build(BuildContext context) {
    final progress = printer.progress?.value ?? 0.0;

    return Row(
      children: [
        // 缩略图
        PrintThumbnail(
          sn: printer.sn,
          filename: printer.currentFile?.value,
          ip: printer.ip,
          port: printer.port,
          width: 40,
          height: 40,
          showLoadingIndicator: false,
        ),
        const SizedBox(width: 8),
        // 进度区
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                printer.currentFile?.value ?? '打印中...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 3),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: Colors.grey.shade200,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${(progress * 100).toStringAsFixed(0)}%',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// 非打印状态行
class _StatusLine extends StatelessWidget {
  final FarmPrinterState printer;

  const _StatusLine({required this.printer});

  @override
  Widget build(BuildContext context) {
    String text;
    Color color;

    if (!printer.isOnline) {
      text = '离线';
      color = Colors.grey;
    } else {
      switch (printer.printState?.value) {
        case 'paused':
          text = '已暂停';
          color = Colors.orange;
          break;
        case 'complete':
          text = '已完成';
          color = Colors.green;
          break;
        case 'error':
          text = '错误';
          color = Colors.red;
          break;
        default:
          text = '待机';
          color = Colors.green;
      }
    }

    return Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color),
    );
  }
}
