/// 打印机发现 Provider (T2.3)
///
/// 管理发现过程的状态: 扫描进度、结果列表、用户选择

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/printer_discovery.dart';

/// 发现状态
class DiscoveryState {
  /// 是否为首次启动（未保存任何打印机）
  final bool isFirstLaunch;

  /// 是否正在扫描
  final bool isScanning;

  /// 扫描进度 (0.0 ~ 1.0)
  final double scanProgress;

  /// 扫描阶段描述
  final String scanPhase;

  /// mDNS 发现结果
  final List<DiscoveredPrinter> mdnsResults;

  /// TCP 扫描结果
  final List<DiscoveredPrinter> tcpResults;

  /// 合并去重后的全部结果
  final List<DiscoveredPrinter> mergedResults;

  /// 用户选中的打印机 id 集合
  final Set<String> selectedIds;

  /// 错误信息
  final String? error;

  const DiscoveryState({
    this.isFirstLaunch = true,
    this.isScanning = false,
    this.scanProgress = 0.0,
    this.scanPhase = '',
    this.mdnsResults = const [],
    this.tcpResults = const [],
    this.mergedResults = const [],
    this.selectedIds = const {},
    this.error,
  });

  int get totalFound => mergedResults.length;
  int get selectedCount => selectedIds.length;

  DiscoveryState copyWith({
    bool? isFirstLaunch,
    bool? isScanning,
    double? scanProgress,
    String? scanPhase,
    List<DiscoveredPrinter>? mdnsResults,
    List<DiscoveredPrinter>? tcpResults,
    List<DiscoveredPrinter>? mergedResults,
    Set<String>? selectedIds,
    String? error,
  }) {
    return DiscoveryState(
      isFirstLaunch: isFirstLaunch ?? this.isFirstLaunch,
      isScanning: isScanning ?? this.isScanning,
      scanProgress: scanProgress ?? this.scanProgress,
      scanPhase: scanPhase ?? this.scanPhase,
      mdnsResults: mdnsResults ?? this.mdnsResults,
      tcpResults: tcpResults ?? this.tcpResults,
      mergedResults: mergedResults ?? this.mergedResults,
      selectedIds: selectedIds ?? this.selectedIds,
      error: error,
    );
  }
}

/// 发现状态 Notifier
class DiscoveryNotifier extends StateNotifier<DiscoveryState> {
  final PrinterDiscovery _discovery = PrinterDiscovery();

  DiscoveryNotifier() : super(const DiscoveryState());

  /// 开始完整发现流程: mDNS → TCP → 合并
  Future<void> startDiscovery() async {
    state = state.copyWith(
      isScanning: true,
      scanProgress: 0.0,
      scanPhase: '正在通过 mDNS 扫描...',
      error: null,
      mdnsResults: [],
      tcpResults: [],
      mergedResults: [],
    );

    try {
      // Phase 1: mDNS
      final mdnsResults = await _discovery.discoverMdns();
      state = state.copyWith(
        mdnsResults: mdnsResults,
        scanProgress: 0.5,
        scanPhase: 'mDNS 找到 ${mdnsResults.length} 台，开始 TCP 扫描...',
      );

      // Phase 2: TCP 扫描
      final subnet = await PrinterDiscovery.detectSubnet();
      List<DiscoveredPrinter> tcpResults = [];
      if (subnet != null) {
        tcpResults = await _discovery.discoverTcp(subnet: subnet);
      }

      // Phase 3: 合并去重
      final merged = PrinterDiscovery.merge(mdnsResults, tcpResults);

      state = state.copyWith(
        tcpResults: tcpResults,
        mergedResults: merged,
        scanProgress: 1.0,
        scanPhase: '发现完成: 共 ${merged.length} 台打印机',
        isScanning: false,
      );
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        error: '发现失败: $e',
      );
    }
  }

  /// 仅 mDNS 快速扫描
  Future<void> quickMdnsScan() async {
    state = state.copyWith(isScanning: true, scanPhase: 'mDNS 快速扫描...');
    final results = await _discovery.discoverMdns();
    state = state.copyWith(
      mdnsResults: results,
      mergedResults: results,
      isScanning: false,
      scanPhase: '找到 ${results.length} 台',
    );
  }

  /// 仅 TCP 扫描
  Future<void> tcpScanOnly() async {
    final subnet = await PrinterDiscovery.detectSubnet();
    if (subnet == null) {
      state = state.copyWith(error: '无法检测局域网子网');
      return;
    }

    state = state.copyWith(isScanning: true, scanPhase: 'TCP 端口扫描 $subnet.0/24...');
    final results = await _discovery.discoverTcp(subnet: subnet);
    state = state.copyWith(
      tcpResults: results,
      mergedResults: results,
      isScanning: false,
      scanPhase: '找到 ${results.length} 台',
    );
  }

  /// 手动添加打印机
  void addManual(String ip, {int port = 7125}) {
    final printer = DiscoveredPrinter(
      ip: ip,
      port: port,
      source: DiscoverySource.manual,
    );
    final updated = [...state.mergedResults, printer];
    state = state.copyWith(mergedResults: updated);
  }

  /// 切换打印机选中状态
  void toggleSelection(String printerId) {
    final selected = Set<String>.from(state.selectedIds);
    if (selected.contains(printerId)) {
      selected.remove(printerId);
    } else {
      selected.add(printerId);
    }
    state = state.copyWith(selectedIds: selected);
  }

  /// 全选/取消全选
  void toggleSelectAll() {
    if (state.selectedIds.length == state.mergedResults.length) {
      state = state.copyWith(selectedIds: {});
    } else {
      state = state.copyWith(selectedIds: state.mergedResults.map((p) => p.id).toSet());
    }
  }

  /// 清除错误
  void clearError() => state = state.copyWith(error: null);

  /// 重置
  void reset() => state = const DiscoveryState();
}

/// 发现 Provider
final discoveryProvider =
    StateNotifierProvider<DiscoveryNotifier, DiscoveryState>((ref) {
  return DiscoveryNotifier();
});

/// 派生: 选中的打印机列表
final selectedPrintersProvider = Provider<List<DiscoveredPrinter>>((ref) {
  final state = ref.watch(discoveryProvider);
  return state.mergedResults
      .where((p) => state.selectedIds.contains(p.id))
      .toList();
});
