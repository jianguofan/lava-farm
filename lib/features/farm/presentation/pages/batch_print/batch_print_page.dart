/// 群控打印页面（四步投产流程）
///
/// Step1 - 选择产品: 从产品库选取或直接选文件
/// Step2 - 确认材料: 颜色、克重等耗材参数
/// Step3 - 选择设备: 过滤机型/状态，多选打印机 + 床板检测
/// Step4 - 执行投产: 批量上传 + 打印 + 结果汇总
///
/// 页面状态与逻辑见 [BatchPrintNotifier]；本文件仅是瘦壳：
/// 步骤指示器 + 当前步骤路由 + 上一步/下一步导航栏。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/batch_print_provider.dart';
import '../../../application/providers/bed_inspection_provider.dart';
import 'steps/execution_step.dart';
import 'steps/material_step.dart';
import 'steps/multi_config_step.dart';
import 'steps/printer_step.dart';
import 'steps/product_step.dart';
import 'widgets/batch_stepper.dart';

/// 群控打印页面（四步投产流程）
class BatchPrintPage extends ConsumerStatefulWidget {
  /// 从仪表盘传入的预选打印机 SN 列表（可选）
  final Set<String> initialSns;

  /// 从产品中心传入的产品 ID（可选）
  final String? productId;

  const BatchPrintPage({super.key, this.initialSns = const {}, this.productId});

  @override
  ConsumerState<BatchPrintPage> createState() => _BatchPrintPageState();
}

class _BatchPrintPageState extends ConsumerState<BatchPrintPage> {
  /// 防止 initState 的自动检测重复触发。
  bool _autoInspected = false;

  BatchPrintArgs get _args => BatchPrintArgs(
      initialSns: widget.initialSns, productId: widget.productId);

  @override
  void initState() {
    super.initState();
    // 进入页面即后台自动床板检测（仅当尚无结果时）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoInspected) return;
      _autoInspected = true;
      final s = ref.read(bedInspectionResultsProvider);
      if (s.results.isEmpty && !s.isLoading) {
        ref.read(bedInspectionResultsProvider.notifier).inspectAll();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final args = _args;

    // 一次性提示消息 → SnackBar（listen 不触发重建）
    ref.listen<BatchPrintState>(batchPrintProvider(args), (prev, next) {
      final msg = next.snackbarMessage;
      if (msg != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
        ref.read(batchPrintProvider(args).notifier).clearSnackbar();
      }
    });

    // 只 watch 步骤 + 完成态：执行期间的高频刷新不会重建本壳。
    final step = ref.watch(batchPrintStepProvider(args));
    final isDone = ref.watch(batchPrintProvider(args).select((s) => s.isDone));
    final hasFailures =
        ref.watch(batchPrintProvider(args).select((s) => s.hasFailures));

    return Scaffold(
      appBar: AppBar(
        title: const Text('群控打印'),
        actions: [
          if (isDone)
            TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('重试失败项'),
              onPressed: hasFailures
                  ? () =>
                      ref.read(batchPrintProvider(args).notifier).retryFailed()
                  : null,
            ),
        ],
      ),
      body: Column(
        children: [
          BatchStepper(args: args),
          const Divider(height: 1),
          Expanded(child: _buildStepContent(step, args)),
        ],
      ),
    );
  }

  /// 构建当前步骤内容；按当前模式的 [effectiveSteps] 分派。
  /// 执行步自带操作按钮不附加导航栏，其余步附加上一步/下一步栏。
  Widget _buildStepContent(int step, BatchPrintArgs args) {
    final steps = ref.read(batchPrintProvider(args)).effectiveSteps;
    final kind = (step >= 0 && step < steps.length) ? steps[step].kind : null;
    Widget content;
    switch (kind) {
      case StepKind.product:
        content = ProductStep(args: args);
      case StepKind.material:
        content = MaterialStep(args: args);
      case StepKind.multiConfig:
        content = MultiConfigStep(args: args);
      case StepKind.printers:
        content = PrinterStep(args: args);
      case StepKind.execute:
        return ExecutionStep(args: args);
      default:
        return const SizedBox.shrink();
    }
    return Column(
      children: [
        Expanded(child: content),
        _StepNavBar(args: args, step: step),
      ],
    );
  }
}

/// 上一步 / 下一步导航栏。
class _StepNavBar extends ConsumerWidget {
  final BatchPrintArgs args;
  final int step;

  const _StepNavBar({required this.args, required this.step});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch 整个 state：选文件/改材料/选打印机会改变「下一步」可用性，
    // 必须订阅才能让按钮重新计算。
    final state = ref.watch(batchPrintProvider(args));
    final notifier = ref.read(batchPrintProvider(args).notifier);
    final steps = state.effectiveSteps;
    final nextStep = step + 1;
    final hasNext = nextStep < steps.length;
    final canNext = hasNext && state.canGoTo(nextStep);
    final nextLabel = hasNext ? steps[nextStep].label : '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (step > 0)
            OutlinedButton.icon(
              onPressed: () => notifier.goToStep(step - 1),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('上一步'),
            ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: canNext ? () => notifier.goToStep(nextStep) : null,
            icon: const Icon(Icons.arrow_forward, size: 18),
            label: Text('下一步：$nextLabel'),
          ),
        ],
      ),
    );
  }
}
