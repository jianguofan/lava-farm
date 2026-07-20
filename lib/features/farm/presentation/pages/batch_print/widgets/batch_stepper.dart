import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/providers/batch_print_provider.dart';

/// 四步流程指示器。
class BatchStepper extends ConsumerWidget {
  final BatchPrintArgs args;

  const BatchStepper({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batchPrintProvider(args));
    final notifier = ref.read(batchPrintProvider(args).notifier);
    final currentStep = state.currentStep;
    final steps = state.effectiveSteps;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(width: 4),
              Expanded(
                child: Container(
                  height: 2,
                  color: i <= currentStep
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade300,
                ),
              ),
              const SizedBox(width: 4),
            ],
            _StepCircle(
              step: i + 1,
              label: steps[i].label,
              isActive: i == currentStep,
              isDone: i < currentStep,
              enabled: state.canGoTo(i),
              onTap: state.canGoTo(i) ? () => notifier.goToStep(i) : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// 步骤圆圈指示器。
class _StepCircle extends StatelessWidget {
  final int step;
  final String label;
  final bool isActive;
  final bool isDone;
  final bool enabled;
  final VoidCallback? onTap;

  const _StepCircle({
    required this.step,
    required this.label,
    required this.isActive,
    required this.isDone,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive || isDone
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade400;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? color
                    : isDone
                        ? color.withOpacity(0.15)
                        : Colors.grey.shade200,
                border: Border.all(color: color, width: 2),
              ),
              child: Center(
                child: isDone
                    ? Icon(Icons.check, size: 16, color: color)
                    : Text(
                        '$step',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isActive ? Colors.white : color,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
                color: isActive ? color : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
