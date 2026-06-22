/// Broker 状态指示器 Widget
///
/// 显示 Broker 连接状态的视觉指示器:
///   🟢 已连接  /  🟡 连接中  /  🔴 断开  /  ⚠️ 降级  /  ❌ 错误

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../data/broker_connection_manager.dart';

/// Broker 状态指示器
class BrokerStatusIndicator extends ConsumerWidget {
  final VoidCallback? onTap;

  const BrokerStatusIndicator({super.key, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(brokerStateProvider);
    final state = stateAsync.valueOrNull ?? BrokerConnState.disconnected;

    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: state.label,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _statusColor(state).withOpacity(0.15),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _statusColor(state).withOpacity(0.5),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusDot(color: _statusColor(state), state: state),
              const SizedBox(width: 6),
              Text(
                _statusLabel(state),
                style: TextStyle(
                  color: _statusColor(state),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(BrokerConnState state) => switch (state) {
    BrokerConnState.connected    => Colors.green,
    BrokerConnState.connecting   => Colors.orange,
    BrokerConnState.degraded     => Colors.amber.shade700,
    BrokerConnState.error        => Colors.red,
    BrokerConnState.disconnected => Colors.grey,
  };

  String _statusLabel(BrokerConnState state) => switch (state) {
    BrokerConnState.connected    => 'MQTT · 已连接',
    BrokerConnState.connecting   => '连接中...',
    BrokerConnState.degraded     => 'MQTT · 降级',
    BrokerConnState.error        => '认证失败',
    BrokerConnState.disconnected => 'MQTT · 断开',
  };
}

class _StatusDot extends StatelessWidget {
  final Color color;
  final BrokerConnState state;
  const _StatusDot({required this.color, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state == BrokerConnState.connecting) {
      return SizedBox(
        width: 10, height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
      );
    }

    if (state == BrokerConnState.degraded) {
      return _PulsingDot(color: color);
    }

    return Container(
      width: 10, height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) => Container(
        width: 10, height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withOpacity(0.4 + (_controller.value * 0.6)),
        ),
      ),
    );
  }
}
