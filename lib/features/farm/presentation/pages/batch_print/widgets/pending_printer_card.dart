import 'package:flutter/material.dart';

import '../../../../data/farm_printer_state.dart';
import '../../../../domain/models/bed_inspection_result.dart';
import 'inspection_status_line.dart';

/// IP 待解析的打印机（在线但无 IP，不可选）。
class PendingPrinterCard extends StatelessWidget {
  final FarmPrinterState printer;
  final BedInspectionResult? inspectionResult;

  const PendingPrinterCard({
    super.key,
    required this.printer,
    this.inspectionResult,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Card(
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Colors.orange.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.hourglass_empty, size: 16, color: Colors.orange.shade600),
                  const SizedBox(width: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      printer.displayLabel,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('IP 解析中...', style: TextStyle(fontSize: 9, color: Colors.orange.shade600)),
              const SizedBox(height: 4),
              // 检测结果（仅显示文字状态，无图因为 IP 未知）
              InspectionStatusLine(result: inspectionResult),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
