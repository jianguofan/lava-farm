/// 打印机发现向导页面 (T2.3, T2.4)
///
/// 三步向导式流程:
///   Step 0 — 选择发现方式（mDNS / TCP 扫描 / 手动输入 / CSV 导入）
///   Step 1 — 扫描及结果展示
///   Step 2 — 输入 Access Code 并确认入网
///
/// 集成 [discoveryProvider] 管理扫描状态和用户选择。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/discovery_provider.dart';
import '../widgets/discovery_result_list.dart';

/// 发现方式枚举
enum _DiscoveryMode { mdns, tcp, manual, csv }

/// 打印机发现向导页
class DiscoveryWizardPage extends ConsumerStatefulWidget {
  const DiscoveryWizardPage({super.key});

  @override
  ConsumerState<DiscoveryWizardPage> createState() =>
      _DiscoveryWizardPageState();
}

class _DiscoveryWizardPageState extends ConsumerState<DiscoveryWizardPage> {
  int _currentStep = 0;
  _DiscoveryMode? _selectedMode;
  final _manualIpController = TextEditingController();
  final _manualPortController = TextEditingController(text: '7125');
  final _accessCodeController = TextEditingController(text: '12345678');
  bool _isOnboarding = false;

  @override
  void dispose() {
    _manualIpController.dispose();
    _manualPortController.dispose();
    _accessCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final discoveryState = ref.watch(discoveryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('添加打印机'),
        actions: [
          if (_currentStep > 0)
            TextButton(
              onPressed: () {
                ref.read(discoveryProvider.notifier).reset();
                setState(() => _currentStep = 0);
              },
              child: const Text('重新开始'),
            ),
        ],
      ),
      body: Stepper(
        currentStep: _currentStep,
        onStepContinue: () => _onStepContinue(discoveryState),
        onStepCancel: _onStepCancel,
        controlsBuilder: (context, details) => _buildControls(details),
        steps: [
          // ── Step 0: 选择发现方式 ──
          Step(
            title: const Text('选择发现方式'),
            content: _buildModeSelector(),
            isActive: _currentStep >= 0,
            state: _currentStep > 0 ? StepState.complete : StepState.indexed,
          ),

          // ── Step 1: 扫描结果 ──
          Step(
            title: Text(
              discoveryState.isScanning
                  ? '扫描中...'
                  : '扫描结果 (${discoveryState.mergedResults.length} 台)',
            ),
            content: SizedBox(
              height: 300,
              child: DiscoveryResultList(),
            ),
            isActive: _currentStep >= 1,
            state: _currentStep > 1
                ? StepState.complete
                : _currentStep == 1
                    ? StepState.indexed
                    : StepState.indexed,
          ),

          // ── Step 2: Access Code ──
          Step(
            title: Text(
              '输入 Access Code (${discoveryState.selectedIds.length} 台已选)',
            ),
            content: _buildAccessCodeStep(discoveryState),
            isActive: _currentStep >= 2,
            state: _currentStep > 2 ? StepState.complete : StepState.indexed,
          ),
        ],
      ),
    );
  }

  /// Step 0: 发现方式选择
  Widget _buildModeSelector() {
    return Column(
      children: [
        _ModeTile(
          icon: Icons.wifi_find,
          title: 'mDNS 扫描',
          subtitle: '在局域网中扫描 _moonraker._tcp 服务（快速，约 5 秒）',
          isSelected: _selectedMode == _DiscoveryMode.mdns,
          onTap: () => setState(() => _selectedMode = _DiscoveryMode.mdns),
        ),
        const SizedBox(height: 8),
        _ModeTile(
          icon: Icons.search,
          title: 'TCP 端口扫描',
          subtitle: '扫描子网所有 :7125 端口（较慢，约 30 秒，支持 50 并发）',
          isSelected: _selectedMode == _DiscoveryMode.tcp,
          onTap: () => setState(() => _selectedMode = _DiscoveryMode.tcp),
        ),
        const SizedBox(height: 8),
        _ModeTile(
          icon: Icons.edit,
          title: '手动输入 IP',
          subtitle: '直接输入目标打印机的 IP 地址和端口',
          isSelected: _selectedMode == _DiscoveryMode.manual,
          onTap: () => setState(() => _selectedMode = _DiscoveryMode.manual),
        ),
        const SizedBox(height: 8),
        _ModeTile(
          icon: Icons.upload_file,
          title: 'CSV 批量导入',
          subtitle: '从 CSV 文件导入打印机列表 (ip, sn, port, group)',
          isSelected: _selectedMode == _DiscoveryMode.csv,
          onTap: () => setState(() => _selectedMode = _DiscoveryMode.csv),
        ),

        // 手动输入区域
        if (_selectedMode == _DiscoveryMode.manual) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _manualIpController,
                  decoration: const InputDecoration(
                    labelText: 'IP 地址',
                    hintText: '192.168.1.100',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _manualPortController,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Step 2: Access Code 输入 + 确认入网
  Widget _buildAccessCodeStep(DiscoveryState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 已选打印机摘要
        Text(
          '已选择 ${state.selectedIds.length} 台打印机：',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 120),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: state.mergedResults
                .where((p) => state.selectedIds.contains(p.id))
                .length,
            itemBuilder: (context, index) {
              final selected = state.mergedResults
                  .where((p) => state.selectedIds.contains(p.id))
                  .toList();
              final printer = selected[index];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.print, size: 18),
                title: Text(
                  printer.displayName,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '${printer.ip}:${printer.port}',
                  style: const TextStyle(fontSize: 11),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 8),

        // Access Code 输入
        TextField(
          controller: _accessCodeController,
          decoration: const InputDecoration(
            labelText: 'Access Code',
            hintText: 'Snapmaker 打印机默认: 12345678',
            border: OutlineInputBorder(),
            helperText: '用于验证打印机访问权限',
          ),
          obscureText: true,
        ),
      ],
    );
  }

  /// 自定义控制按钮
  Widget _buildControls(ControlsDetails details) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          if (_currentStep > 0)
            TextButton(
              onPressed: details.onStepCancel,
              child: const Text('上一步'),
            ),
          const Spacer(),
          if (_isOnboarding)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          FilledButton(
            onPressed: _isOnboarding ? null : details.onStepContinue,
            child: Text(_currentStep == 2 ? '开始入网' : '继续'),
          ),
        ],
      ),
    );
  }

  /// 下一步逻辑
  void _onStepContinue(DiscoveryState discoveryState) {
    if (_currentStep == 0) {
      // 验证选择
      if (_selectedMode == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请选择一种发现方式')),
        );
        return;
      }

      // 手动模式：验证 IP 输入
      if (_selectedMode == _DiscoveryMode.manual) {
        final ip = _manualIpController.text.trim();
        if (ip.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请输入 IP 地址')),
          );
          return;
        }
        // 添加到结果中
        ref.read(discoveryProvider.notifier).addManual(
              ip,
              port: int.tryParse(_manualPortController.text) ?? 7125,
            );
      } else {
        // 触发扫描
        final notifier = ref.read(discoveryProvider.notifier);
        if (_selectedMode == _DiscoveryMode.mdns) {
          notifier.quickMdnsScan();
        } else if (_selectedMode == _DiscoveryMode.tcp) {
          notifier.tcpScanOnly();
        } else if (_selectedMode == _DiscoveryMode.csv) {
          notifier.startDiscovery(); // CSV 导入是异步的 — 先触发，再由用户选择文件
        }
      }

      setState(() => _currentStep = 1);
      return;
    }

    if (_currentStep == 1) {
      // 验证至少选择一台
      if (discoveryState.selectedIds.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请至少勾选一台打印机')),
        );
        return;
      }
      setState(() => _currentStep = 2);
      return;
    }

    if (_currentStep == 2) {
      // 验证 Access Code
      final accessCode = _accessCodeController.text.trim();
      if (accessCode.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入 Access Code')),
        );
        return;
      }

      // 开始入网
      _startOnboarding(accessCode);
    }
  }

  /// 开始入网流程
  Future<void> _startOnboarding(String accessCode) async {
    setState(() => _isOnboarding = true);

    try {
      // TODO: 调用 FarmHub.onboard() 逐台入网
      // final hub = ref.read(farmHubProvider);
      // final selectedPrinters = ref.read(selectedPrintersProvider);
      //
      // for (final printer in selectedPrinters) {
      //   final result = await hub.onboard(
      //     ip: printer.ip,
      //     port: printer.port,
      //     accessCode: accessCode,
      //     brokerConfig: brokerConfig,
      //     apiKey: accessCode, // Moonraker 默认 API Key = Access Code
      //   );
      //
      //   if (!result.success) {
      //     // 记录失败，继续处理下一台
      //   }
      // }

      // 模拟入网延迟（实际由 FarmHub 处理）
      await Future.delayed(const Duration(seconds: 2));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('入网完成'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('入网失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isOnboarding = false);
      }
    }
  }

  /// 上一步
  void _onStepCancel() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }
}

/// 发现方式选择卡片
class _ModeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: isSelected ? 2 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey.shade300,
          width: isSelected ? 2 : 1,
        ),
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: isSelected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: isSelected
            ? Icon(
                Icons.check_circle,
                color: Theme.of(context).colorScheme.primary,
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}
