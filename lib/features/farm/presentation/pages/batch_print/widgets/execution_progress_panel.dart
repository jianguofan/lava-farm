import 'package:flutter/material.dart';

import '../../../../application/services/batch_print_coordinator.dart';

/// 执行进度面板：进度条 + 统计 + 按阶段分组的打印机列表。
class ExecutionProgressPanel extends StatelessWidget {
  final BatchPrintProgress? progress;
  final bool isDone;
  final Map<String, BatchPrintPrinterState> printerStates;
  final List<BatchPrintPrinterUpdate> updateLog;
  final ValueChanged<String> onCancelUpload;

  const ExecutionProgressPanel({
    super.key,
    required this.progress,
    required this.isDone,
    required this.printerStates,
    required this.updateLog,
    required this.onCancelUpload,
  });

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    final groups = _buildPrinterGroups();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              const Icon(Icons.sync, size: 20),
              const SizedBox(width: 8),
              Text(
                isDone ? '执行完成' : '执行进度',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (isDone)
                Icon(
                  progress?.hasFailures == true ? Icons.warning_amber : Icons.check_circle,
                  color: progress?.hasFailures == true ? Colors.orange : Colors.green,
                  size: 20,
                ),
            ],
          ),
          const SizedBox(height: 12),

          // 进度条
          if (progress != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.isDone ? 1.0 : progress.progress,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
              ),
            ),
            const SizedBox(height: 8),
            _buildStatsRow(progress),
          ],

          const SizedBox(height: 12),

          // 阶段分组视图
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Text('等待开始...', style: TextStyle(color: Colors.grey.shade400)),
                  )
                : ListView(children: groups),
          ),
        ],
      ),
    );
  }

  /// 构建统计行
  Widget _buildStatsRow(BatchPrintProgress progress) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        _Stat(label: '排队', count: progress.queuedCount, color: Colors.grey),
        _Stat(label: '上传中', count: progress.uploadingCount, color: Colors.blue),
        _Stat(label: '启动中', count: progress.startingPrintCount, color: Colors.orange),
        _Stat(label: '成功', count: progress.successCount, color: Colors.green),
        _Stat(label: '失败', count: progress.failedCount, color: Colors.red),
        Text(
          '${progress.completedCount}/${progress.totalPrinters}',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  /// 按阶段分组打印机列表
  List<Widget> _buildPrinterGroups() {
    final stateMap = Map<String, BatchPrintPrinterState>.from(printerStates);

    final groupDefs = [
      _GroupDef(
        label: '排队中',
        icon: Icons.hourglass_empty,
        color: Colors.grey.shade600,
        bgColor: Colors.grey.shade50,
        states: {BatchPrintPrinterState.queued},
      ),
      _GroupDef(
        label: '上传文件',
        icon: Icons.cloud_upload_outlined,
        color: Colors.blue.shade700,
        bgColor: Colors.blue.shade50,
        states: {BatchPrintPrinterState.uploading},
      ),
      _GroupDef(
        label: '启动打印',
        icon: Icons.play_circle_outline,
        color: Colors.orange.shade700,
        bgColor: Colors.orange.shade50,
        states: {BatchPrintPrinterState.uploadDone, BatchPrintPrinterState.startingPrint},
      ),
      _GroupDef(
        label: '已完成',
        icon: Icons.check_circle,
        color: Colors.green.shade700,
        bgColor: Colors.green.shade50,
        states: {BatchPrintPrinterState.success},
        defaultExpanded: false,
      ),
      _GroupDef(
        label: '失败',
        icon: Icons.error_outline,
        color: Colors.red.shade700,
        bgColor: Colors.red.shade50,
        states: {BatchPrintPrinterState.uploadFailed, BatchPrintPrinterState.printFailed},
        defaultExpanded: true,
      ),
    ];

    final widgets = <Widget>[];
    for (final def_ in groupDefs) {
      final members = <MapEntry<String, BatchPrintPrinterState>>[];
      for (final entry in stateMap.entries) {
        if (def_.states.contains(entry.value)) {
          members.add(entry);
        }
      }

      if (members.isEmpty) continue;

      widgets.add(_buildGroup(def_, members));
      widgets.add(const SizedBox(height: 4));
    }

    return widgets;
  }

  /// 单个阶段分组
  Widget _buildGroup(
    _GroupDef def_,
    List<MapEntry<String, BatchPrintPrinterState>> members,
  ) {
    return Card(
      elevation: 0,
      color: def_.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: def_.color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分组标题
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(def_.icon, size: 16, color: def_.color),
                const SizedBox(width: 6),
                Text(
                  def_.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: def_.color,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: def_.color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${members.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: def_.color,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 分组内打印机列表
          ...members.map((entry) => _PrinterItem(
                sn: entry.key,
                state: entry.value,
                groupColor: def_.color,
                error: _getError(entry.key),
                elapsed: _getElapsed(entry.key),
                uploadProgress: _getUploadProgress(entry.key),
                onCancelUpload: onCancelUpload,
              )),
        ],
      ),
    );
  }

  String? _getError(String sn) {
    for (final update in updateLog.reversed) {
      if (update.sn == sn && update.error != null) {
        return update.error;
      }
    }
    return null;
  }

  Duration? _getElapsed(String sn) {
    for (final update in updateLog.reversed) {
      if (update.sn == sn && update.elapsed != null) {
        return update.elapsed;
      }
    }
    return null;
  }

  double? _getUploadProgress(String sn) {
    for (final update in updateLog.reversed) {
      if (update.sn == sn && update.uploadProgress != null) {
        return update.uploadProgress;
      }
    }
    return null;
  }
}

/// 阶段分组定义。
class _GroupDef {
  final String label;
  final IconData icon;
  final Color color;
  final Color bgColor;
  final Set<BatchPrintPrinterState> states;
  final bool defaultExpanded;

  const _GroupDef({
    required this.label,
    required this.icon,
    required this.color,
    required this.bgColor,
    required this.states,
    this.defaultExpanded = true,
  });
}

/// 统计数字。
class _Stat extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _Stat({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 4),
        Text('$label ', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Text('$count', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }
}

/// 分组内单台打印机条目。
class _PrinterItem extends StatelessWidget {
  final String sn;
  final BatchPrintPrinterState state;
  final Color groupColor;
  final String? error;
  final Duration? elapsed;
  final double? uploadProgress;
  final ValueChanged<String> onCancelUpload;

  const _PrinterItem({
    required this.sn,
    required this.state,
    required this.groupColor,
    required this.error,
    required this.elapsed,
    required this.uploadProgress,
    required this.onCancelUpload,
  });

  @override
  Widget build(BuildContext context) {
    final (statusIcon, statusLabel) = switch (state) {
      BatchPrintPrinterState.queued => (Icons.hourglass_empty, '等待中'),
      BatchPrintPrinterState.uploading => (
          Icons.cloud_upload_outlined,
          uploadProgress != null ? '${(uploadProgress! * 100).toStringAsFixed(0)}%' : '上传中',
        ),
      BatchPrintPrinterState.uploadDone => (Icons.cloud_done_outlined, '上传完成'),
      BatchPrintPrinterState.startingPrint => (Icons.play_circle_outline, '正在启动'),
      BatchPrintPrinterState.success => (Icons.check_circle, '打印已启动'),
      BatchPrintPrinterState.uploadFailed => (Icons.error_outline, '上传失败'),
      BatchPrintPrinterState.printFailed => (Icons.warning_amber, '打印启动失败'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: groupColor.withOpacity(0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, size: 14, color: groupColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  sn,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (error != null) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Tooltip(
                    message: error,
                    child: Text(
                      error!,
                      style: TextStyle(fontSize: 10, color: Colors.red.shade400),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              if (elapsed != null) ...[
                const SizedBox(width: 6),
                Text(
                  '${elapsed!.inSeconds}s',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ],
              const SizedBox(width: 6),
              Text(
                statusLabel,
                style: TextStyle(fontSize: 10, color: groupColor),
              ),
            ],
          ),
          // 上传进度条 + 取消按钮
          if (state == BatchPrintPrinterState.uploading && uploadProgress != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: uploadProgress!.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation(groupColor),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => onCancelUpload(sn),
                  child: Icon(Icons.close, size: 14, color: Colors.grey.shade500),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
