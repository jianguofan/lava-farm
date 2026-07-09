/// 投产历史记录
///
/// 一次"批量投产"执行后沉淀的记录：投产对象（产品 / 文件）、
/// 参与设备、成功/失败统计、失败明细与时间。
/// 用于结果面板与历史回溯。
class ProductionRecord {
  final String id;
  final String productId;
  final String productName;
  final String fileName;
  final List<String> printerSns;
  final int successCount;
  final int failedCount;
  final Map<String, String> failures;
  final int printPlate;
  final DateTime startedAt;
  final DateTime finishedAt;

  const ProductionRecord({
    required this.id,
    required this.productId,
    required this.productName,
    required this.fileName,
    required this.printerSns,
    required this.successCount,
    required this.failedCount,
    required this.failures,
    required this.printPlate,
    required this.startedAt,
    required this.finishedAt,
  });

  int get total => successCount + failedCount;

  bool get isSuccess => failedCount == 0;

  Duration get duration => finishedAt.difference(startedAt);

  factory ProductionRecord.fromJson(Map<String, dynamic> json) {
    return ProductionRecord(
      id: json['id'] as String,
      productId: json['productId'] as String? ?? '',
      productName: json['productName'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      printerSns: (json['printerSns'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      successCount: (json['successCount'] as num?)?.toInt() ?? 0,
      failedCount: (json['failedCount'] as num?)?.toInt() ?? 0,
      failures: Map<String, String>.from(
        (json['failures'] as Map? ?? const {}).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
      ),
      printPlate: (json['printPlate'] as num?)?.toInt() ?? 1,
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
      finishedAt:
          DateTime.tryParse(json['finishedAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'productName': productName,
        'fileName': fileName,
        'printerSns': printerSns,
        'successCount': successCount,
        'failedCount': failedCount,
        'failures': failures,
        'printPlate': printPlate,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
      };
}
