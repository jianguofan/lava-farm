import 'package:flutter/material.dart';

import '../../../../domain/models/production_record.dart';

/// 投产结果汇总面板（完成时展示）。
class ResultPanel extends StatelessWidget {
  final ProductionRecord record;

  const ResultPanel({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    final allOk = record.isSuccess;
    return Card(
      color: allOk ? Colors.green.shade50 : Colors.orange.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: allOk ? Colors.green.shade300 : Colors.orange.shade300,
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  allOk ? Icons.check_circle : Icons.warning_amber_rounded,
                  color: allOk ? Colors.green.shade700 : Colors.orange.shade700,
                ),
                const SizedBox(width: 8),
                Text(
                  allOk ? '投产完成' : '投产完成（部分失败）',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: allOk ? Colors.green.shade800 : Colors.orange.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _ResultStat(
                    label: '产品',
                    value: record.productName.isEmpty ? record.fileName : record.productName),
                _ResultStat(label: '文件', value: record.fileName),
                _ResultStat(label: '成功', value: '${record.successCount} 台'),
                _ResultStat(label: '失败', value: '${record.failedCount} 台'),
                _ResultStat(label: '耗时', value: '${record.duration.inSeconds}s'),
                _ResultStat(label: '开始', value: _formatClock(record.startedAt)),
              ],
            ),
            if (record.failures.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('失败明细', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              ...record.failures.entries.map((e) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.key,
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace', color: Colors.red)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(e.value,
                              style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  String _formatClock(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}

/// 结果面板统计项。
class _ResultStat extends StatelessWidget {
  final String label;
  final String value;

  const _ResultStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
