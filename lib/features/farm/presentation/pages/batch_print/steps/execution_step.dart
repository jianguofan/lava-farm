import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/providers/batch_print_provider.dart';
import '../../../../application/providers/broker_state_provider.dart';
import '../../../../application/providers/printer_list_provider.dart';
import '../../../../data/farm_printer_state.dart';
import '../widgets/execution_progress_panel.dart';
import '../widgets/result_panel.dart';

/// Step4：执行投产（操作按钮 + 结果面板 + 进度 + 完成栏）。
class ExecutionStep extends ConsumerWidget {
  final BatchPrintArgs args;

  const ExecutionStep({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batchPrintProvider(args));
    final notifier = ref.read(batchPrintProvider(args).notifier);
    final gateway = ref.watch(farmCommandGatewayProvider);

    final isExecuting = state.isExecuting;
    final isDone = state.isDone;
    final hasFailures = state.hasFailures;

    // 选中的打印机（按 selectedSns 顺序，解析为 FarmPrinterState 以展示名称/状态）
    final allPrinters = ref.watch(printerListProvider);
    final bySn = {for (final p in allPrinters) p.sn: p};

    return Column(
      children: [
        // 操作按钮
        _StartPrintButton(
          isExecuting: isExecuting,
          isDone: isDone,
          canStart: !isExecuting &&
              state.filePath != null &&
              state.selectedSns.isNotEmpty &&
              gateway != null,
          count: state.selectedSns.length,
          primaryColor: Theme.of(context).colorScheme.primary,
          onStart: notifier.startPrint,
        ),

        // 结果汇总面板（完成时）
        if (isDone && state.lastRecord != null) ResultPanel(record: state.lastRecord!),

        // 进度显示
        if (isExecuting || isDone)
          Expanded(
            child: ExecutionProgressPanel(
              progress: state.progress,
              isDone: isDone,
              printerStates: state.printerStates,
              updateLog: state.updateLog,
              onCancelUpload: (sn) =>
                  ref.read(batchPrintCoordinatorProvider).cancelUpload(sn),
            ),
          ),

        // 完成操作栏
        if (isDone)
          _DoneBar(
            hasFailures: hasFailures,
            onRetry: notifier.retryFailed,
            onBack: () => Navigator.pop(context),
          ),

        // 待执行：展示选中的打印机列表，供确认
        if (!isExecuting && !isDone)
          Expanded(
            child: _SelectedPrintersList(
              selectedSns: state.selectedSns,
              bySn: bySn,
            ),
          ),
      ],
    );
  }
}

/// 开始/执行中/已完成按钮。
class _StartPrintButton extends StatelessWidget {
  final bool isExecuting;
  final bool isDone;
  final bool canStart;
  final int count;
  final Color primaryColor;
  final VoidCallback onStart;

  const _StartPrintButton({
    required this.isExecuting,
    required this.isDone,
    required this.canStart,
    required this.count,
    required this.primaryColor,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final String buttonText;
    if (isExecuting) {
      buttonText = '执行中...';
    } else if (isDone) {
      buttonText = '已完成';
    } else {
      buttonText = '开始打印 ($count 台)';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: ElevatedButton.icon(
          icon: isExecuting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.print),
          label: Text(buttonText, style: const TextStyle(fontSize: 15)),
          onPressed: canStart ? onStart : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: isDone ? Colors.green : isExecuting ? Colors.grey : primaryColor,
            foregroundColor: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 完成操作栏（重试失败项 / 返回仪表盘）。
class _DoneBar extends StatelessWidget {
  final bool hasFailures;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  const _DoneBar({required this.hasFailures, required this.onRetry, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (hasFailures)
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试失败项'),
                onPressed: onRetry,
              ),
            ),
          if (hasFailures) const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回仪表盘'),
              onPressed: onBack,
            ),
          ),
        ],
      ),
    );
  }
}

/// 选中的打印机列表（投产前确认）。按 selectedSns 顺序展示名称/在线状态，
/// 离线或 IP 无效的会标注「将跳过」（startPrint 实际会跳过这些设备）。
class _SelectedPrintersList extends StatelessWidget {
  final Set<String> selectedSns;
  final Map<String, FarmPrinterState> bySn;

  const _SelectedPrintersList({required this.selectedSns, required this.bySn});

  @override
  Widget build(BuildContext context) {
    final sns = selectedSns.toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Icon(Icons.rocket_launch_outlined, size: 20, color: Colors.grey.shade400),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sns.isEmpty
                      ? '尚未选择打印机（请返回上一步选择设备）'
                      : '已选 ${sns.length} 台打印机，确认无误后点击下方按钮投产',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (sns.isEmpty)
          Expanded(
            child: Center(
              child: Text('无选中设备', style: TextStyle(color: Colors.grey.shade500)),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              itemCount: sns.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
              itemBuilder: (_, i) => _PrinterRow(sn: sns[i], printer: bySn[sns[i]]),
            ),
          ),
      ],
    );
  }
}

class _PrinterRow extends StatelessWidget {
  final String sn;
  final FarmPrinterState? printer;

  const _PrinterRow({required this.sn, required this.printer});

  @override
  Widget build(BuildContext context) {
    final online = printer?.isOnline ?? false;
    final willSkip = printer == null || !printer!.hasValidIp || !online;
    final name = printer?.displayName?.isNotEmpty == true ? printer!.displayName! : sn;

    return ListTile(
      dense: true,
      leading: Icon(
        Icons.fiber_manual_record,
        size: 12,
        color: online ? Colors.green : Colors.grey.shade400,
      ),
      title: Text(name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(sn, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      trailing: willSkip
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Text(
                printer == null ? '未找到' : '将跳过',
                style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
              ),
            )
          : Text(
              printer?.ip ?? '',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
    );
  }
}
