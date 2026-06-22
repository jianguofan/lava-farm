/// 批量文件上传进度 UI 组件 (P10 UI)
///
/// 显示上传进度条、各打印机上传状态、失败汇总。

import 'package:flutter/material.dart';

import '../../data/file_uploader.dart';

/// 批量上传进度 Widget
///
/// 使用示例:
/// ```dart
/// UploadProgressSheet(
///   printerCount: 10,
///   onStart: (controller) async {
///     final results = await uploader.batchUpload(
///       printerSns: sns,
///       connectionInfo: info,
///       localFilePath: path,
///       remoteFileName: name,
///       onProgress: (completed, total) {
///         controller.updateProgress(completed, total);
///       },
///     );
///     controller.complete(results);
///   },
/// )
/// ```
class UploadProgressSheet extends StatefulWidget {
  /// 打印机总数
  final int printerCount;

  /// 上传开始回调
  final Future<void> Function(_UploadProgressController controller) onStart;

  const UploadProgressSheet({
    super.key,
    required this.printerCount,
    required this.onStart,
  });

  /// 显示为模态 Bottom Sheet
  static Future<List<UploadResult>?> show(
    BuildContext context, {
    required int printerCount,
    required Future<void> Function(_UploadProgressController controller) onStart,
  }) {
    return showModalBottomSheet<List<UploadResult>>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => UploadProgressSheet(
        printerCount: printerCount,
        onStart: onStart,
      ),
    );
  }

  @override
  State<UploadProgressSheet> createState() => _UploadProgressSheetState();
}

class _UploadProgressSheetState extends State<UploadProgressSheet> {
  final _controller = _UploadProgressController();
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // 在下一帧启动上传（等 Sheet 动画完成）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_started) {
        _started = true;
        widget.onStart(_controller);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final isCompleted = _controller.isCompleted;
        final hasError = _controller.hasError;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题栏
              Row(
                children: [
                  Icon(
                    isCompleted
                        ? (hasError ? Icons.warning_amber : Icons.check_circle)
                        : Icons.cloud_upload,
                    color: isCompleted
                        ? (hasError ? Colors.orange : Colors.green)
                        : Colors.blue,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isCompleted ? '上传完成' : '正在上传文件...',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          isCompleted
                              ? _buildResultSummary()
                              : '${_controller.completed}/${_controller.total} 台',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isCompleted)
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(_controller.results),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              const SizedBox(height: 20),

              // 总体进度条
              LinearProgressIndicator(
                value: _controller.progress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                backgroundColor: Colors.grey.shade200,
                color: _controller.progress >= 1.0
                    ? (hasError ? Colors.orange : Colors.green)
                    : Colors.blue,
              ),
              const SizedBox(height: 8),

              // 百分比 + 速度
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${(_controller.progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (!isCompleted)
                    Text(
                      _controller.elapsed.inSeconds > 0
                          ? '${_controller.completed ~/ (_controller.elapsed.inSeconds.clamp(1, 999999))} 台/秒'
                          : '准备中...',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                ],
              ),
              const SizedBox(height: 20),

              // 各打印机状态列表（可滚动，显示成功/失败明细）
              if (_controller.results.isNotEmpty) ...[
                const Text('详情', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _controller.results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = _controller.results[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          result.success ? Icons.check_circle : Icons.error,
                          color: result.success ? Colors.green : Colors.red,
                          size: 20,
                        ),
                        title: Text(
                          result.printerSn,
                          style: const TextStyle(fontSize: 13),
                        ),
                        trailing: Text(
                          result.success
                              ? '${result.duration.inMilliseconds}ms'
                              : (result.error ?? '失败'),
                          style: TextStyle(
                            fontSize: 11,
                            color: result.success ? Colors.grey : Colors.red,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],

              // 错误提示
              if (isCompleted && hasError) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _buildErrorSummary(),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _buildResultSummary() {
    final total = _controller.total;
    final success = _controller.results.where((r) => r.success).length;
    final failed = total - success;
    if (failed == 0) return '$total 台全部成功';
    return '$success 成功, $failed 失败';
  }

  String _buildErrorSummary() {
    final failed = _controller.results.where((r) => !r.success).toList();
    if (failed.isEmpty) return '';
    final reasons = <String, int>{};
    for (final r in failed) {
      final key = r.error ?? '未知错误';
      reasons[key] = (reasons[key] ?? 0) + 1;
    }
    return reasons.entries.map((e) => '${e.value}台: ${e.key}').join('\n');
  }
}

/// 上传进度控制器
///
/// 由调用方在 onStart 回调中使用:
/// - updateProgress(completed, total) — 更新进度
/// - complete(results) — 标记完成
/// - error(message) — 标记错误
class _UploadProgressController extends ChangeNotifier {
  int completed = 0;
  int total = 0;
  double get progress => total > 0 ? completed / total : 0.0;

  bool isCompleted = false;
  bool hasError = false;
  String? errorMessage;
  List<UploadResult> results = [];
  DateTime startTime = DateTime.now();
  Duration get elapsed => DateTime.now().difference(startTime);

  void updateProgress(int completed, int total) {
    this.completed = completed;
    this.total = total;
    notifyListeners();
  }

  void complete(List<UploadResult> results) {
    this.results = results;
    isCompleted = true;
    hasError = results.any((r) => !r.success);
    completed = total;
    notifyListeners();
  }

  void error(String message) {
    isCompleted = true;
    hasError = true;
    errorMessage = message;
    notifyListeners();
  }
}
