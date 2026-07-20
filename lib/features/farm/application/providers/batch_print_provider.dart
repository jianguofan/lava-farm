/// 群控打印页面级状态 (Page-level state)
///
/// 把原本散落在 BatchPrintPage State 里的步骤/产品/材料/打印机选择/执行流程
/// 抽到一个 Riverpod StateNotifier，UI（步骤组件）只负责展示与触发动作。
///
/// 范式参考 DiscoveryNotifier / BedInspectionNotifier。
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parse_3mf/parse_3mf.dart';

import '../services/batch_print_coordinator.dart';
import 'broker_state_provider.dart';
import 'print_head_provider.dart';
import 'product_provider.dart';
import 'production_history_provider.dart';
import '../../data/farm_printer_state.dart';
import '../../domain/models/product_definition.dart';
import '../../domain/models/product_material.dart';
import '../../domain/models/production_record.dart';
import '../../domain/services/filament_matcher.dart';
import '../../domain/services/pre_print_gcode.dart';

/// copyWith 中表示「未传参」的哨兵值，用于区分「保持原值」与「显式置 null」。
const _unset = Object();

/// 向导步骤种类。多盘模式下「确认材料 + 选择设备」合并为一个 [multiConfig] 步。
enum StepKind { product, material, multiConfig, printers, execute }

/// 向导步骤描述：种类 + 显示标签。步骤列表随模式变化（见 [BatchPrintState.effectiveSteps]）。
class BatchStepDescriptor {
  final StepKind kind;
  final String label;
  const BatchStepDescriptor(this.kind, this.label);
}

/// 多盘同打：单盘的独立配置——绑定的打印机子集 + 该盘耗材→打印头映射。
class PlateAssignment {
  final int plateId;
  final String name;
  final Set<String> printerSns;
  final List<ProductMaterial> materials;
  final bool enabled;

  const PlateAssignment({
    required this.plateId,
    this.name = '',
    this.printerSns = const <String>{},
    this.materials = const [],
    this.enabled = true,
  });

  PlateAssignment copyWith({
    int? plateId,
    String? name,
    Set<String>? printerSns,
    List<ProductMaterial>? materials,
    bool? enabled,
  }) =>
      PlateAssignment(
        plateId: plateId ?? this.plateId,
        name: name ?? this.name,
        printerSns: printerSns ?? this.printerSns,
        materials: materials ?? this.materials,
        enabled: enabled ?? this.enabled,
      );
}

/// 页面入参（路由构造参数），作为 family 的 key。
class BatchPrintArgs {
  /// 从仪表盘传入的预选打印机 SN 集合
  final Set<String> initialSns;

  /// 从产品中心传入的产品 ID
  final String? productId;

  const BatchPrintArgs({this.initialSns = const {}, this.productId});

  @override
  bool operator ==(Object other) =>
      other is BatchPrintArgs &&
      other.productId == productId &&
      setEquals(other.initialSns, initialSns);

  @override
  int get hashCode =>
      Object.hash(productId, Object.hashAllUnordered(initialSns));
}

/// 群控打印页面状态（不可变值对象）
class BatchPrintState {
  /// 当前步骤 0..3
  final int currentStep;

  // ── Step1: 产品/文件 ──
  final ProductDefinition? selectedProduct;
  final String? filePath;
  final String? fileName;

  // ── Step1: 3MF 解析结果 ──
  final bool isParsing;
  final Metadata? parsed3mf;
  final Map<String, Uint8List> previewImages; // key = zip 内相对路径
  final String? parseError;

  // ── Step2: 材料 ──
  final List<ProductMaterial> materials;

  // ── Step3: 打印机/选项 ──
  final Set<String> selectedSns;
  final int printPlate;

  // ── 多盘同打（>1 盘时可选模式；各盘独立绑定打印机 + 耗材映射）──
  final bool multiPlateMode;
  final List<PlateAssignment> assignments;

  // ── 执行 ──
  final bool isExecuting;
  final bool isDone;
  final Map<String, BatchPrintPrinterState> printerStates;
  final BatchPrintProgress? progress;
  final List<BatchPrintPrinterUpdate> updateLog;
  final ProductionRecord? lastRecord;
  final DateTime? execStartTime;

  /// 一次性提示消息（页面 ref.listen 到非空就弹 SnackBar 并清空）
  final String? snackbarMessage;

  const BatchPrintState({
    this.currentStep = 0,
    this.selectedProduct,
    this.filePath,
    this.fileName,
    this.isParsing = false,
    this.parsed3mf,
    this.previewImages = const {},
    this.parseError,
    this.materials = const [],
    this.selectedSns = const {},
    this.printPlate = 1,
    this.multiPlateMode = false,
    this.assignments = const [],
    this.isExecuting = false,
    this.isDone = false,
    this.printerStates = const {},
    this.progress,
    this.updateLog = const [],
    this.lastRecord,
    this.execStartTime,
    this.snackbarMessage,
  });

  /// 是否存在失败项
  bool get hasFailures => printerStates.values.any(
        (s) =>
            s == BatchPrintPrinterState.uploadFailed ||
            s == BatchPrintPrinterState.printFailed,
      );

  /// 当前模式下的向导步骤列表。
  /// 单盘：选择文件 → 确认材料 → 选择设备 → 执行投产（4 步）。
  /// 多盘：选择文件 → 多盘配置 → 执行投产（3 步，耗材+设备合并）。
  /// [currentStep] 是该列表的索引。
  List<BatchStepDescriptor> get effectiveSteps => multiPlateMode
      ? const [
          BatchStepDescriptor(StepKind.product, '选择产品'),
          BatchStepDescriptor(StepKind.multiConfig, '多盘配置'),
          BatchStepDescriptor(StepKind.execute, '执行投产'),
        ]
      : const [
          BatchStepDescriptor(StepKind.product, '选择产品'),
          BatchStepDescriptor(StepKind.material, '确认材料'),
          BatchStepDescriptor(StepKind.printers, '选择设备'),
          BatchStepDescriptor(StepKind.execute, '执行投产'),
        ];

  /// 前进到 step 需满足的前置条件：进入 step 需其前一步（step-1）产出齐备。
  bool canAdvanceTo(int step) {
    if (step <= 0 || step >= effectiveSteps.length) return false;
    switch (effectiveSteps[step - 1].kind) {
      case StepKind.product:
        return filePath != null;
      case StepKind.material:
        return materials.isNotEmpty;
      case StepKind.multiConfig:
        final enabled = assignments.where((a) => a.enabled).toList();
        return enabled.isNotEmpty &&
            enabled.any((a) => a.printerSns.isNotEmpty);
      case StepKind.printers:
        return selectedSns.isNotEmpty;
      case StepKind.execute:
        return true;
    }
  }

  /// 是否允许跳转到 step（可回退到已完成步骤，或满足前置条件时前进）
  bool canGoTo(int step) {
    if (step < 0 || step >= effectiveSteps.length) return false;
    if (step <= currentStep) return true;
    for (var s = currentStep + 1; s <= step; s++) {
      if (!canAdvanceTo(s)) return false;
    }
    return true;
  }

  /// 深拷贝合并；可为 null 的引用类型字段用哨兵区分「不变」与「置 null」。
  BatchPrintState copyWith({
    int? currentStep,
    List<ProductMaterial>? materials,
    Set<String>? selectedSns,
    int? printPlate,
    bool? isExecuting,
    bool? isDone,
    Map<String, BatchPrintPrinterState>? printerStates,
    Object? progress = _unset,
    List<BatchPrintPrinterUpdate>? updateLog,
    Object? selectedProduct = _unset,
    Object? filePath = _unset,
    Object? fileName = _unset,
    Object? parsed3mf = _unset,
    Object? parseError = _unset,
    Object? lastRecord = _unset,
    Object? execStartTime = _unset,
    Object? snackbarMessage = _unset,
    bool? isParsing,
    Map<String, Uint8List>? previewImages,
    bool? multiPlateMode,
    List<PlateAssignment>? assignments,
  }) {
    return BatchPrintState(
      currentStep: currentStep ?? this.currentStep,
      materials: materials ?? this.materials,
      selectedSns: selectedSns ?? this.selectedSns,
      printPlate: printPlate ?? this.printPlate,
      multiPlateMode: multiPlateMode ?? this.multiPlateMode,
      assignments: assignments ?? this.assignments,
      isExecuting: isExecuting ?? this.isExecuting,
      isDone: isDone ?? this.isDone,
      printerStates: printerStates ?? this.printerStates,
      progress: identical(progress, _unset)
          ? this.progress
          : progress as BatchPrintProgress?,
      updateLog: updateLog ?? this.updateLog,
      selectedProduct: identical(selectedProduct, _unset)
          ? this.selectedProduct
          : selectedProduct as ProductDefinition?,
      filePath:
          identical(filePath, _unset) ? this.filePath : filePath as String?,
      fileName:
          identical(fileName, _unset) ? this.fileName : fileName as String?,
      parsed3mf: identical(parsed3mf, _unset)
          ? this.parsed3mf
          : parsed3mf as Metadata?,
      parseError: identical(parseError, _unset)
          ? this.parseError
          : parseError as String?,
      lastRecord: identical(lastRecord, _unset)
          ? this.lastRecord
          : lastRecord as ProductionRecord?,
      execStartTime: identical(execStartTime, _unset)
          ? this.execStartTime
          : execStartTime as DateTime?,
      snackbarMessage: identical(snackbarMessage, _unset)
          ? this.snackbarMessage
          : snackbarMessage as String?,
      isParsing: isParsing ?? this.isParsing,
      previewImages: previewImages ?? this.previewImages,
    );
  }
}

/// 群控打印 Notifier —— 承载页面全部状态与业务逻辑。
class BatchPrintNotifier extends StateNotifier<BatchPrintState> {
  final Ref _ref;

  StreamSubscription<BatchPrintPrinterUpdate>? _updateSub;
  StreamSubscription<BatchPrintProgress>? _progressSub;

  BatchPrintNotifier(this._ref, BatchPrintArgs args)
      : super(BatchPrintState(selectedSns: Set<String>.from(args.initialSns))) {
    if (args.productId != null) {
      // 延迟到构造完成后执行，与原 postFrame 行为一致。
      Future.microtask(() => initFromProduct(args.productId!));
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 导航
  // ═══════════════════════════════════════════════════════════

  void goToStep(int step) {
    if (!state.canGoTo(step)) return;
    state = state.copyWith(currentStep: step);
  }

  // ═══════════════════════════════════════════════════════════
  // Step1: 产品/文件
  // ═══════════════════════════════════════════════════════════

  Future<void> pickFile() async {
    try {
      const typeGroup = XTypeGroup(
        label: '3D 打印文件',
        extensions: ['gcode', '3mf', 'zip', 'g', 'gco'],
      );
      final xfile = await openFile(acceptedTypeGroups: [typeGroup]);
      if (xfile == null) return;
      if (!mounted) return;

      final is3mf = xfile.name.toLowerCase().endsWith('.3mf');
      state = state.copyWith(
        filePath: xfile.path,
        fileName: xfile.name,
        parsed3mf: null,
        previewImages: const {},
        parseError: null,
        isParsing: is3mf,
      );
      // 仅 .3mf 是 ZIP 结构，可解析出元数据与预览图；GCode 等保持原行为。
      if (is3mf) {
        await _parse3mf(xfile.path);
      }
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(snackbarMessage: '选择文件失败: $e');
    }
  }

  /// 后台解析 .3mf：结构化元数据 + 预览图字节，写入 state 供 UI 展示。
  /// 大文件（含 35MB+ 几何体）的同步 ZIP 读取放在 isolate 中，避免阻塞 UI。
  Future<void> _parse3mf(String path) async {
    try {
      final result = await compute(_parse3mfInIsolate, path);
      if (!mounted) return;
      // 解析完成默认选中第一盘，据此回填耗材并自动匹配打印头。
      final plates = result.meta.profiles.firstOrNull?.partitions ?? const [];
      final plateId = plates.isNotEmpty ? plates.first.id : state.printPlate;

      debugPrint('[BatchPrint] 3MF解析完成: ${plates.length}盘');
      for (final p in plates) {
        debugPrint('  盘${p.id}: ${p.name}, filaments=${p.filaments.length}');
      }
      debugPrint('[BatchPrint] 默认选中盘: $plateId');

      state = state.copyWith(
        parsed3mf: result.meta,
        previewImages: result.images,
        isParsing: false,
        parseError: null,
        printPlate: plateId,
        materials: _autoMatch(_materialsFromPlate(result.meta, plateId)),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isParsing: false, parseError: '3MF 解析失败: $e');
    }
  }

  /// 选择某个打印盘：更新 [printPlate]（决定实际下发打印的盘号），
  /// 以该盘 filaments 重建耗材（filament.id → extruderIndex）并自动匹配打印头。
  void selectPlate(int id) {
    state = state.copyWith(
      printPlate: id,
      materials: _autoMatch(_materialsFromPlate(state.parsed3mf, id)),
    );
  }

  /// 由解析结果中指定盘的 filaments 生成耗材列表。
  /// extruderIndex = slice filament id（1-based，下发 G-code 的 CONFIG_EXTRUDER）。
  /// 优先使用 partition.filaments；若为空则回退到 profile.filaments（全局耗材）。
  List<ProductMaterial> _materialsFromPlate(Metadata? meta, int plateId) {
    final profile = meta?.profiles.firstOrNull;
    if (profile == null) return const [];

    final partition = profile.partitions
        .where((p) => p.id == plateId)
        .firstOrNull;

    // 优先使用盘级耗材；若为空则回退到全局耗材
    final filaments = (partition != null && partition.filaments.isNotEmpty)
        ? partition.filaments
        : profile.filaments;

    debugPrint('[BatchPrint] 盘$plateId 耗材: ${filaments.length}种 '
        '(来源: ${partition?.filaments.isNotEmpty == true ? "盘级" : "全局"})');

    return [
      for (final f in filaments)
        ProductMaterial(
          colorName: (f.type == null || f.type!.isEmpty) ? '耗材' : f.type!,
          argb: _argbFromHex(f.color),
          grams: f.usedG ?? 0,
          extruderIndex: f.id,
        ),
    ];
  }

  /// 读取全局打印头预设 + 文件喷嘴，对耗材做自动匹配（[FilamentMatcher.assignHeads]）。
  List<ProductMaterial> _autoMatch(List<ProductMaterial> materials) {
    final heads = _ref.read(printHeadListProvider);
    final nozzle = state.parsed3mf?.profiles.firstOrNull?.nozzle.firstOrNull;
    return assignHeads(materials, heads, nozzle: nozzle);
  }

  /// 重新自动匹配当前耗材（UI「自动匹配」按钮）。
  void autoMatch() {
    state = state.copyWith(materials: _autoMatch(state.materials));
  }

  /// 手动给第 [materialIndex] 条耗材指定打印头 [head]（1-based）。
  void assignHead(int materialIndex, int head) {
    final list = List<ProductMaterial>.from(state.materials);
    if (materialIndex < 0 || materialIndex >= list.length) return;
    list[materialIndex] = list[materialIndex].copyWith(assignedHead: head);
    state = state.copyWith(materials: list);
  }

  /// 清除第 [materialIndex] 条耗材的打印头分配（置 null）。
  void clearHead(int materialIndex) {
    final list = List<ProductMaterial>.from(state.materials);
    if (materialIndex < 0 || materialIndex >= list.length) return;
    final m = list[materialIndex];
    list[materialIndex] = ProductMaterial(
      colorName: m.colorName,
      argb: m.argb,
      grams: m.grams,
      extruderIndex: m.extruderIndex,
      assignedHead: null,
    );
    state = state.copyWith(materials: list);
  }

  void clearFile() {
    state = state.copyWith(
      filePath: null,
      fileName: null,
      selectedProduct: null,
      parsed3mf: null,
      previewImages: const {},
      parseError: null,
      isParsing: false,
      printPlate: 1,
      materials: const [],
    );
  }

  /// 从产品 ID 加载产品并跳到 Step2
  void initFromProduct(String productId) {
    final products = _ref.read(productListProvider);
    final product = products.where((p) => p.id == productId).firstOrNull;
    if (product == null || !mounted) return;
    state = state.copyWith(
      selectedProduct: product,
      filePath: product.sourceFilePath,
      fileName: product.name,
      materials: List<ProductMaterial>.from(product.materials),
      currentStep: 1,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Step2: 材料
  // ═══════════════════════════════════════════════════════════

  void addMaterial() {
    final name = state.materials.isEmpty ? '默认' : '新增耗材';
    state = state.copyWith(materials: [
      ...state.materials,
      ProductMaterial(colorName: name, argb: 0xFF9E9E9E, grams: 0),
    ]);
  }

  void updateMaterial(int index, ProductMaterial material) {
    final list = List<ProductMaterial>.from(state.materials);
    if (index < 0 || index >= list.length) return;
    list[index] = material;
    state = state.copyWith(materials: list);
  }

  void removeMaterial(int index) {
    final list = List<ProductMaterial>.from(state.materials);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    state = state.copyWith(materials: list);
  }

  // ═══════════════════════════════════════════════════════════
  // Step3: 打印机/选项
  // ═══════════════════════════════════════════════════════════

  void togglePrinter(String sn) {
    final set = Set<String>.from(state.selectedSns);
    if (set.contains(sn)) {
      set.remove(sn);
    } else {
      set.add(sn);
    }
    state = state.copyWith(selectedSns: set);
  }

  void selectAllReady(List<FarmPrinterState> ready) {
    final set = Set<String>.from(state.selectedSns);
    for (final p in ready) {
      set.add(p.sn);
    }
    state = state.copyWith(selectedSns: set);
  }

  void clearSelection() {
    state = state.copyWith(selectedSns: const <String>{});
  }

  void setPrintPlate(int plate) {
    if (plate > 0) state = state.copyWith(printPlate: plate);
  }

  // ═══════════════════════════════════════════════════════════
  // 多盘同打
  // ═══════════════════════════════════════════════════════════

  /// 切换多盘同打模式。开启要求已解析出 >1 个盘；按各盘生成独立配置
  /// （耗材自动匹配、空打印机、全部启用），并钳制 currentStep。
  /// 关闭则清空配置、回单盘（重选第一盘）。
  void setMultiPlateMode(bool value) {
    if (value == state.multiPlateMode) return;
    if (value) {
      final partitions =
          state.parsed3mf?.profiles.firstOrNull?.partitions ?? const [];
      if (partitions.length <= 1) return;
      final assignments = [
        for (final p in partitions)
          PlateAssignment(
            plateId: p.id,
            name: p.name,
            materials: _autoMatch(_materialsFromPlate(state.parsed3mf, p.id)),
            printerSns: const <String>{},
            enabled: true,
          ),
      ];
      state = state.copyWith(
        multiPlateMode: true,
        assignments: assignments,
        currentStep: state.currentStep > 1 ? 1 : state.currentStep,
      );
    } else {
      final first = state.parsed3mf?.profiles.firstOrNull?.partitions.firstOrNull;
      final plateId = first?.id ?? state.printPlate;
      state = state.copyWith(
        multiPlateMode: false,
        assignments: const [],
        printPlate: plateId,
        materials: _autoMatch(_materialsFromPlate(state.parsed3mf, plateId)),
        currentStep: state.currentStep > 1 ? 1 : state.currentStep,
      );
    }
  }

  /// 给某盘切换绑定一台打印机（MOVE 语义：sn 已在其它盘则先移除，维持各盘互斥；
  /// 在目标盘则取消绑定并释放）。
  void togglePlatePrinter(int plateId, String sn) {
    final targetIdx = state.assignments.indexWhere((a) => a.plateId == plateId);
    if (targetIdx < 0) return;
    final wasInTarget = state.assignments[targetIdx].printerSns.contains(sn);
    final list = <PlateAssignment>[];
    for (final a in state.assignments) {
      final sns = Set<String>.from(a.printerSns)..remove(sn);
      if (a.plateId == plateId && !wasInTarget) sns.add(sn);
      list.add(a.copyWith(printerSns: sns));
    }
    state = state.copyWith(assignments: list);
  }

  /// 启用/禁用某盘。禁用时清空其绑定的打印机（释放给其它盘）。
  void togglePlateEnabled(int plateId) {
    final list = state.assignments.map((a) {
      if (a.plateId != plateId) return a;
      final nowEnabled = !a.enabled;
      return a.copyWith(
        enabled: nowEnabled,
        printerSns: nowEnabled ? a.printerSns : const <String>{},
      );
    }).toList();
    state = state.copyWith(assignments: list);
  }

  /// 给某盘第 [materialIndex] 条耗材指定打印头 [head]（1-based）。
  void assignPlateHead(int plateId, int materialIndex, int head) {
    state = state.copyWith(
        assignments:
            _withPlateMaterial(plateId, materialIndex, (m) => m.copyWith(assignedHead: head)));
  }

  /// 清除某盘第 [materialIndex] 条耗材的打印头分配。
  /// 注意：[ProductMaterial.copyWith] 无法把字段置回 null，这里必须重建对象。
  void clearPlateHead(int plateId, int materialIndex) {
    state = state.copyWith(
        assignments: _withPlateMaterial(plateId, materialIndex, (m) => ProductMaterial(
              colorName: m.colorName,
              argb: m.argb,
              grams: m.grams,
              extruderIndex: m.extruderIndex,
              assignedHead: null,
            )));
  }

  /// 对某盘耗材重新自动匹配打印头。
  void autoMatchPlate(int plateId) {
    final list = state.assignments
        .map((a) =>
            a.plateId == plateId ? a.copyWith(materials: _autoMatch(a.materials)) : a)
        .toList();
    state = state.copyWith(assignments: list);
  }

  /// 对所有盘耗材重新自动匹配打印头。
  void autoMatchAll() {
    final list = state.assignments
        .map((a) => a.copyWith(materials: _autoMatch(a.materials)))
        .toList();
    state = state.copyWith(assignments: list);
  }

  /// 重建 assignments，仅替换 [plateId] 盘第 [materialIndex] 条耗材（由 [transform] 映射）。
  List<PlateAssignment> _withPlateMaterial(
    int plateId,
    int materialIndex,
    ProductMaterial Function(ProductMaterial) transform,
  ) {
    return [
      for (final a in state.assignments)
        if (a.plateId != plateId)
          a
        else
          a.copyWith(materials: [
            for (var i = 0; i < a.materials.length; i++)
              i == materialIndex ? transform(a.materials[i]) : a.materials[i],
          ]),
    ];
  }

  // ═══════════════════════════════════════════════════════════
  // Step4: 执行
  // ═══════════════════════════════════════════════════════════

  Future<void> startPrint() async {
    if (state.multiPlateMode) {
      await _startMultiPlatePrint();
      return;
    }
    if (state.filePath == null || state.selectedSns.isEmpty) return;

    final store = _ref.read(farmStoreProvider);
    final connectionInfo = <String, (String ip, int port, String apiKey)>{};
    final validSns = <String>[];
    final skipped = <String>[];

    for (final sn in state.selectedSns) {
      final printer = store.getPrinter(sn);
      if (printer == null) continue;
      if (!printer.hasValidIp || !printer.isOnline) {
        skipped.add(printer.displayName ?? sn);
        continue;
      }
      connectionInfo[sn] = (printer.ip, printer.port, ''); // apiKey 暂空
      validSns.add(sn);
    }

    if (skipped.isNotEmpty) {
      state = state.copyWith(
          snackbarMessage: '${skipped.join("、")} 不可用（离线或 IP 未知）');
    }
    if (validSns.isEmpty) {
      if (state.snackbarMessage == null) {
        state = state.copyWith(snackbarMessage: '没有可用的打印机');
      }
      return;
    }

    final gateway = _ref.read(farmCommandGatewayProvider);
    if (gateway == null) {
      state = state.copyWith(snackbarMessage: 'MQTT 未连接，无法启动打印');
      return;
    }

    state = state.copyWith(
      isExecuting: true,
      isDone: false,
      printerStates: const {},
      progress: null,
      updateLog: const [],
      execStartTime: DateTime.now(),
      lastRecord: null,
      snackbarMessage: null,
    );

    final coordinator = _ref.read(batchPrintCoordinatorProvider);
    _subscribe(coordinator);

    await coordinator.execute(
      printerSns: validSns,
      connectionInfo: connectionInfo,
      localFilePath: state.filePath!,
      remoteFileName: state.fileName!,
      gateway: gateway,
      printPlate: state.printPlate,
      // 耗材→打印头映射 G-code：启动打印前下发（无映射则为 null，跳过）。
      prePrintGcode: buildExtruderMapGcode(state.materials),
    );

    await _persistRecord(validSns);
  }

  /// 多盘同打执行：每个 enabled 盘的打印机打各自绑定盘，耗材映射按盘独立。
  Future<void> _startMultiPlatePrint() async {
    if (state.filePath == null) return;
    final enabledPlates = state.assignments.where((a) => a.enabled).toList();
    if (enabledPlates.isEmpty) {
      state = state.copyWith(snackbarMessage: '没有启用的打印盘');
      return;
    }

    final store = _ref.read(farmStoreProvider);
    final connectionInfo = <String, (String ip, int port, String apiKey)>{};
    final plateBySn = <String, int>{};
    final gcodeBySn = <String, String?>{};
    final skipped = <String>[];

    for (final a in enabledPlates) {
      final gcode = buildExtruderMapGcode(a.materials);
      for (final sn in a.printerSns) {
        final printer = store.getPrinter(sn);
        if (printer == null) continue;
        if (!printer.hasValidIp || !printer.isOnline) {
          skipped.add(printer.displayName ?? sn);
          continue;
        }
        connectionInfo[sn] = (printer.ip, printer.port, '');
        plateBySn[sn] = a.plateId;
        gcodeBySn[sn] = gcode;
      }
    }

    // 每个 enabled 盘至少一台可用打印机
    for (final a in enabledPlates) {
      if (a.printerSns.every((sn) => !connectionInfo.containsKey(sn))) {
        state = state.copyWith(
            snackbarMessage: '盘 ${a.plateId}（${a.name}）没有可用的打印机');
        return;
      }
    }

    if (skipped.isNotEmpty) {
      state = state.copyWith(
          snackbarMessage: '${skipped.join("、")} 不可用（离线或 IP 未知）');
    }
    if (connectionInfo.isEmpty) {
      if (state.snackbarMessage == null) {
        state = state.copyWith(snackbarMessage: '没有可用的打印机');
      }
      return;
    }

    final gateway = _ref.read(farmCommandGatewayProvider);
    if (gateway == null) {
      state = state.copyWith(snackbarMessage: 'MQTT 未连接，无法启动打印');
      return;
    }

    state = state.copyWith(
      isExecuting: true,
      isDone: false,
      printerStates: const {},
      progress: null,
      updateLog: const [],
      execStartTime: DateTime.now(),
      lastRecord: null,
      snackbarMessage: null,
    );

    final coordinator = _ref.read(batchPrintCoordinatorProvider);
    _subscribe(coordinator);

    await coordinator.execute(
      printerSns: connectionInfo.keys.toList(),
      connectionInfo: connectionInfo,
      localFilePath: state.filePath!,
      remoteFileName: state.fileName!,
      gateway: gateway,
      // 以下两个兜底值仅在 plateBySn/gcodeBySn 未覆盖时生效；实际按打印机解析。
      printPlate: enabledPlates.first.plateId,
      prePrintGcode: null,
      plateBySn: plateBySn,
      gcodeBySn: gcodeBySn,
    );

    await _persistRecordMulti(enabledPlates, connectionInfo.keys.toList());
  }

  Future<void> retryFailed() async {
    final gateway = _ref.read(farmCommandGatewayProvider);
    if (gateway == null) {
      state = state.copyWith(snackbarMessage: 'MQTT 未连接，无法重试');
      return;
    }

    state = state.copyWith(isExecuting: true, isDone: false, progress: null);

    final coordinator = _ref.read(batchPrintCoordinatorProvider);
    if (state.multiPlateMode) {
      // 多盘重试：协调器用 execute 时缓存的 plateBySn/gcodeBySn，仍按各盘下发。
      await coordinator.retryFailed(gateway: gateway);
      if (!mounted) return;
      await _persistRecordMulti(
        state.assignments.where((a) => a.enabled).toList(),
        state.printerStates.keys.toList(),
      );
    } else {
      await coordinator.retryFailed(
          gateway: gateway, printPlate: state.printPlate);
      if (!mounted) return;
      await _persistRecord(state.printerStates.keys.toList());
    }
  }

  /// 订阅协调器两条流，把更新映射进 state
  void _subscribe(BatchPrintCoordinator coordinator) {
    _updateSub?.cancel();
    _progressSub?.cancel();

    _updateSub = coordinator.printerUpdateStream.listen((update) {
      if (!mounted) return;
      state = state.copyWith(
        printerStates: {...state.printerStates, update.sn: update.state},
        updateLog: [...state.updateLog, update],
      );
    });

    _progressSub = coordinator.progressStream.listen((progress) {
      if (!mounted) return;
      if (progress.isDone) {
        state = state.copyWith(
            progress: progress, isExecuting: false, isDone: true);
      } else {
        state = state.copyWith(progress: progress);
      }
    });
  }

  /// 从本次执行结果构建并持久化投产记录
  Future<void> _persistRecord(List<String> sns) async {
    final start = state.execStartTime;
    if (start == null) return;

    var success = 0;
    var failed = 0;
    final failures = <String, String>{};
    for (final sn in sns) {
      final st = state.printerStates[sn];
      if (st == BatchPrintPrinterState.success) {
        success++;
      } else if (st == BatchPrintPrinterState.uploadFailed ||
          st == BatchPrintPrinterState.printFailed) {
        failed++;
        for (final u in state.updateLog.reversed) {
          if (u.sn == sn && u.error != null) {
            failures[sn] = u.error!;
            break;
          }
        }
      }
    }

    final record = ProductionRecord(
      id: state.lastRecord?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
      productId: state.selectedProduct?.id ?? '',
      productName: state.selectedProduct?.displayName ?? state.fileName ?? '',
      fileName: state.fileName ?? '',
      printerSns: List<String>.unmodifiable(sns),
      successCount: success,
      failedCount: failed,
      failures: failures,
      printPlate: state.printPlate,
      startedAt: start,
      finishedAt: DateTime.now(),
    );

    await _ref.read(productionHistoryProvider.notifier).add(record);
    if (!mounted) return;
    state = state.copyWith(lastRecord: record);
  }

  /// 多盘同打：每个 enabled 盘沉淀一条投产记录（按各盘绑定打印机过滤成功/失败）。
  /// 不写 lastRecord（结果面板在多盘下走进度面板，见 execution_step）。
  Future<void> _persistRecordMulti(
      List<PlateAssignment> plates, List<String> validSns) async {
    final start = state.execStartTime;
    if (start == null) return;
    final baseName =
        state.selectedProduct?.displayName ?? state.fileName ?? '';
    final finishedAt = DateTime.now();

    for (final a in plates) {
      final sns = a.printerSns.where(validSns.contains).toList();
      if (sns.isEmpty) continue;

      var success = 0;
      var failed = 0;
      final failures = <String, String>{};
      for (final sn in sns) {
        final st = state.printerStates[sn];
        if (st == BatchPrintPrinterState.success) {
          success++;
        } else if (st == BatchPrintPrinterState.uploadFailed ||
            st == BatchPrintPrinterState.printFailed) {
          failed++;
          for (final u in state.updateLog.reversed) {
            if (u.sn == sn && u.error != null) {
              failures[sn] = u.error!;
              break;
            }
          }
        }
      }

      final record = ProductionRecord(
        id: '${finishedAt.microsecondsSinceEpoch}_${a.plateId}',
        productId: state.selectedProduct?.id ?? '',
        productName: '$baseName · 盘${a.plateId}',
        fileName: state.fileName ?? '',
        printerSns: List<String>.unmodifiable(sns),
        successCount: success,
        failedCount: failed,
        failures: failures,
        printPlate: a.plateId,
        startedAt: start,
        finishedAt: finishedAt,
      );

      await _ref.read(productionHistoryProvider.notifier).add(record);
      if (!mounted) return;
    }
  }

  void clearSnackbar() {
    if (state.snackbarMessage != null) {
      state = state.copyWith(snackbarMessage: null);
    }
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    _progressSub?.cancel();
    super.dispose();
  }
}

/// 页面级 Provider：autoDispose.family —— 路由参数作 key，页面 pop 后自动销毁，
/// 避免下次进入时残留上一次的状态。
final batchPrintProvider = StateNotifierProvider.autoDispose
    .family<BatchPrintNotifier, BatchPrintState, BatchPrintArgs>(
        (ref, args) => BatchPrintNotifier(ref, args));

/// 细粒度 selector：仅 currentStep 变化时 Stepper 才重建。
final batchPrintStepProvider = Provider.autoDispose.family<int, BatchPrintArgs>(
    (ref, args) => ref.watch(batchPrintProvider(args)).currentStep);

// --------------------------------------------------------------------------- //
// 3MF 解析（后台 isolate 执行）—— 顶层函数 + 纯数据结果类，可跨 isolate 传递。
// --------------------------------------------------------------------------- //

/// 解析结果载体：字段均为可跨 isolate 拷贝的纯数据。
class _Parsed3mf {
  const _Parsed3mf(this.meta, this.images);
  final Metadata meta;
  final Map<String, Uint8List>
      images; // key = zip 内相对路径（如 Metadata/plate_1.png）
}

/// 在后台 isolate 中解析 .3mf：返回结构化元数据与引用到的预览图字节。
/// 顶层函数，供 [compute] 调用。
Future<_Parsed3mf> _parse3mfInIsolate(String path) async {
  final src = openSource(path);
  // 切片器导出的 .3mf 自带 slice_info.config：同一归档同时作为 gcode 包传入，
  // 即可补齐各盘 used_g / weight / secs 与 per-plate filaments（耗材→打印头映射依据）。
  final gcode = src.has('Metadata/slice_info.config') ? src : null;
  final meta = buildMetadata(src, gcode);

  // 收集 profile / 各盘引用到的预览图，惰性解压取字节（单张都不大）。
  final wanted = <String>{};
  for (final prof in meta.profiles) {
    wanted.addAll(prof.pics);
    for (final pt in prof.partitions) {
      wanted.addAll(pt.pics);
    }
  }
  final images = <String, Uint8List>{};
  for (final rel in wanted) {
    if (!src.has(rel)) continue;
    try {
      images[rel] = Uint8List.fromList(src.read(rel));
    } catch (_) {
      // 单张图缺失不影响整体解析。
    }
  }
  return _Parsed3mf(meta, images);
}

/// #RRGGBB / #AARRGGBB → ARGB int，解析失败回退中性灰。
/// 对暗色进行亮度提升，确保显示为亮色。
int _argbFromHex(String? hex) {
  if (hex == null || hex.isEmpty) return 0xFF9E9E9E;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) {
    h = 'FF$h';
  } else if (h.length != 8) {
    return 0xFF9E9E9E;
  }
  final parsed = int.tryParse(h, radix: 16);
  if (parsed == null) return 0xFF9E9E9E;

  // 提取 ARGB 分量
  final a = (parsed >> 24) & 0xFF;
  var r = (parsed >> 16) & 0xFF;
  var g = (parsed >> 8) & 0xFF;
  var b = parsed & 0xFF;

  // 计算亮度 (使用感知亮度公式)
  final brightness = 0.299 * r + 0.587 * g + 0.114 * b;

  // 如果亮度低于阈值（暗色），则提升亮度
  if (brightness < 128) {
    final factor = 128 / brightness.clamp(1, 255);
    r = (r * factor).clamp(0, 255).toInt();
    g = (g * factor).clamp(0, 255).toInt();
    b = (b * factor).clamp(0, 255).toInt();
  }

  return (a << 24) | (r << 16) | (g << 8) | b;
}
