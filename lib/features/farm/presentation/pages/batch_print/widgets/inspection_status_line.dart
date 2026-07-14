import 'package:flutter/material.dart';

import '../../../../domain/models/bed_inspection_result.dart';

/// 检测状态行（紧凑，用于卡片内嵌）。
class InspectionStatusLine extends StatelessWidget {
  final BedInspectionResult? result;

  const InspectionStatusLine({super.key, this.result});

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    if (result == null) {
      return Text('待检测', style: TextStyle(fontSize: 9, color: Colors.grey.shade400));
    }

    if (result.hasForeignObjects) {
      return Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 12, color: Colors.red),
          const SizedBox(width: 2),
          Expanded(
            child: Tooltip(
              message: result.bedForeignObjects.description,
              child: Text(
                result.bedForeignObjects.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9, color: Colors.red.shade700, height: 1.3),
              ),
            ),
          ),
        ],
      );
    }

    if (result.isReadyToPrint) {
      return Row(
        children: [
          Icon(Icons.check_circle, size: 12, color: Colors.green.shade600),
          const SizedBox(width: 2),
          Text(
            result.printReadiness.caution ? '可打印（注意）' : '床板干净',
            style: TextStyle(fontSize: 9, color: Colors.green.shade700),
          ),
        ],
      );
    }

    return Row(
      children: [
        Icon(Icons.info_outline, size: 12, color: Colors.orange.shade600),
        const SizedBox(width: 2),
        Expanded(
          child: Tooltip(
            message: result.printReadiness.reason,
            child: Text(
              result.printReadiness.reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: Colors.orange.shade700),
            ),
          ),
        ),
      ],
    );
  }
}
