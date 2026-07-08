/// 群控打印页面（四步投产流程）
///
/// Step1 - 选择产品: 从产品库选取或直接选文件
/// Step2 - 确认材料: 颜色、克重等耗材参数
/// Step3 - 选择设备: 过滤机型/状态，多选打印机 + 床板检测
/// Step4 - 执行投产: 批量上传 + 打印 + 结果汇总
///
/// 供用户选择多台打印机 + 3MF/GCode 文件，批量上传并发起打印。

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/bed_inspection_provider.dart';
import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/printer_list_provider.dart';
import '../../application/providers/product_provider.dart';
import '../../application/services/batch_print_coordinator.dart';
import '../../data/farm_printer_state.dart';
import '../../domain/models/bed_inspection_result.dart';
import '../../domain/models/product_definition.dart';
import '../../domain/models/product_material.dart';

/// 群控打印页面
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
  // ── 步骤状态 ──
  int _currentStep = 0;

  // ── Step1: 产品/文件选择 ──
  ProductDefinition? _selectedProduct;
  String? _filePath;
  String? _fileName;

  // ── Step2: 材料确认 ──
  List<ProductMaterial> _materials = [];

  // ── Step3: 打印机选择 ──
  final _selectedSns = <String>{};
  int _printPlate = 1;

  // ── 执行状态 ──
  bool _isExecuting = false;
  bool _isDone = false;
  final Map<String, BatchPrintPrinterState> _printerStates = {};
  BatchPrintProgress? _progress;
  final List<BatchPrintPrinterUpdate> _updateLog = [];

  // ── 检测状态 ──
  bool _isInspecting = false;

  BatchPrintCoordinator? _coordinator;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _selectedSns.addAll(widget.initialSns);

    // 如果从产品中心跳转，加载产品并跳到 Step2
    if (widget.productId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initFromProduct());
    }
  }

  Future<void> _initFromProduct() async {
    final products = ref.read(productListProvider);
    final product = products.where((p) => p.id == widget.productId).firstOrNull;
    if (product != null && mounted) {
      setState(() {
        _selectedProduct = product;
        _filePath = product.sourceFilePath;
        _fileName = product.name;
        _materials = List.from(product.materials);
        _currentStep = 1; // 跳到材料确认
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _coordinator?.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printerListProvider);
    final gateway = ref.watch(farmCommandGatewayProvider);

    // 监听检测状态
    _isInspecting = ref.watch(bedInspectionLoadingProvider);
    final inspectionResults = ref.watch(bedInspectionResultsMapProvider);

    // 筛选可用打印机（在线 + 有 IP 才可选）
    final readyPrinters = printers
        .where((p) => p.isOnline && p.ip != '—' && p.ip != 'MQTT')
        .toList();
    // MQTT 在线但 IP 待解析（显示但不给选）
    final pendingPrinters = printers
        .where((p) => p.isOnline && !p.hasValidIp)
        .toList();
    // 离线
    final offlinePrinters = printers.where((p) => !p.isOnline).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('群控打印'),
        actions: [
          if (_isDone)
            TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('重试失败项'),
              onPressed: _hasFailures ? _retryFailed : null,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── 四步 Stepper ──
          _buildStepper(),

          const Divider(height: 1),

          // ── 当前步骤内容 ──
          Expanded(child: _buildStepContent(
            readyPrinters, pendingPrinters, offlinePrinters, inspectionResults, gateway)),
        ],
      ),
    );
  }

  /// 构建步骤指示器
  Widget _buildStepper() {
    final steps = ['选择产品', '确认材料', '选择设备', '执行投产'];
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
                  color: i <= _currentStep
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade300,
                ),
              ),
              const SizedBox(width: 4),
            ],
            _StepCircle(
              step: i + 1,
              label: steps[i],
              isActive: i == _currentStep,
              isDone: i < _currentStep,
              enabled: i <= _currentStep || (i == _currentStep + 1 && _canAdvanceTo(i)),
            ),
          ],
        ],
      ),
    );
  }

  bool _canAdvanceTo(int step) {
    switch (step) {
      case 1: return _filePath != null;
      case 2: return _materials.isNotEmpty;
      case 3: return _selectedSns.isNotEmpty;
      default: return false;
    }
  }

  /// 构建当前步骤内容
  Widget _buildStepContent(
    List<FarmPrinterState> readyPrinters,
    List<FarmPrinterState> pendingPrinters,
    List<FarmPrinterState> offlinePrinters,
    Map<String, BedInspectionResult> inspectionResults,
    dynamic gateway,
  ) {
    switch (_currentStep) {
      case 0:
        return _buildProductStep();
      case 1:
        return _buildMaterialStep();
      case 2:
        return _buildPrinterStep(readyPrinters, pendingPrinters, offlinePrinters, inspectionResults, gateway);
      case 3:
        return _buildExecutionStep(gateway, readyPrinters);
      default:
        return const SizedBox.shrink();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // Step 1: 产品选择
  // ═══════════════════════════════════════════════════════════

  Widget _buildProductStep() {
    final productsAsync = ref.watch(productProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 文件选择
          Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 20),
              const SizedBox(width: 8),
              const Text('选择文件', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: _fileName != null
                    ? Chip(
                        avatar: const Icon(Icons.check_circle, size: 18, color: Colors.green),
                        label: Text(_fileName!, style: const TextStyle(fontSize: 13)),
                        onDeleted: _isExecuting ? null : () => setState(() {
                          _filePath = null;
                          _fileName = null;
                          _selectedProduct = null;
                        }),
                      )
                    : OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('选择 3MF / GCode 文件'),
                        onPressed: _isExecuting ? null : _pickFile,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('或从产品库中选择', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 8),
          // 产品库网格
          Expanded(
            child: productsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('加载失败: $e'),
              data: (products) {
                if (products.isEmpty) {
                  return Center(
                    child: Text('暂无产品，请先导入', style: TextStyle(color: Colors.grey.shade500)),
                  );
                }
                return GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    mainAxisExtent: 120,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: products.length,
                  itemBuilder: (context, index) {
                    final product = products[index];
                    final isSelected = _selectedProduct?.id == product.id;
                    return Card(
                      elevation: isSelected ? 3 : 1,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: isSelected ? Colors.blue : Colors.transparent,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: InkWell(
                        onTap: () => setState(() {
                          _selectedProduct = product;
                          _filePath = product.sourceFilePath;
                          _fileName = product.name;
                          _materials = List.from(product.materials);
                        }),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      product.displayName,
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isSelected)
                                    const Icon(Icons.check_circle, size: 18, color: Colors.blue),
                                ],
                              ),
                              const Spacer(),
                              Text(product.machineModel,
                                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                              Text('${product.totalFilamentGrams.toStringAsFixed(1)}g · ${product.plateQuantity}盘',
                                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                              if (product.materials.isNotEmpty)
                                Row(
                                  children: product.materials.take(3).map((m) => Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Color(m.argb),
                                        border: Border.all(color: Colors.grey.shade300),
                                      ),
                                    ),
                                  )).toList(),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Step 2: 材料确认
  // ═══════════════════════════════════════════════════════════

  Widget _buildMaterialStep() {
    if (_materials.isEmpty && _selectedProduct != null) {
      _materials = List.from(_selectedProduct!.materials);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.palette_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                '确认耗材配置${_selectedProduct != null ? " — ${_selectedProduct!.displayName}" : ""}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_materials.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inventory_outlined, size: 48, color: Colors.grey.shade300),
                    const SizedBox(height: 8),
                    const Text('未检测到耗材信息'),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('添加耗材'),
                      onPressed: () => setState(() => _materials.add(
                        ProductMaterial(colorName: '默认', argb: 0xFF9E9E9E, grams: 0),
                      )),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < _materials.length; i++)
                    _MaterialRow(
                      material: _materials[i],
                      index: i,
                      onChanged: (m) => setState(() => _materials[i] = m),
                      onDelete: () => setState(() => _materials.removeAt(i)),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加耗材'),
                    onPressed: () => setState(() => _materials.add(
                      ProductMaterial(colorName: '新增耗材', argb: 0xFF9E9E9E, grams: 0),
                    )),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Step 3: 打印机选择
  // ═══════════════════════════════════════════════════════════

  Widget _buildPrinterStep(
    List<FarmPrinterState> readyPrinters,
    List<FarmPrinterState> pendingPrinters,
    List<FarmPrinterState> offlinePrinters,
    Map<String, BedInspectionResult> inspectionResults,
    dynamic gateway,
  ) {
    return Column(
      children: [
        // 打印机选择区域
        _buildPrinterSection(readyPrinters, pendingPrinters, offlinePrinters, inspectionResults),

        const Divider(height: 1),

        // 打印选项
        _buildOptionsSection(),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Step 4: 执行投产
  // ═══════════════════════════════════════════════════════════

  Widget _buildExecutionStep(dynamic gateway, List<FarmPrinterState> readyPrinters) {
    return Column(
      children: [
        // 操作按钮
        _buildActionButton(gateway != null, readyPrinters),

        // 进度显示
        if (_isExecuting || _isDone) Expanded(child: _buildProgressSection()),

        // 完成操作栏
        if (_isDone) _buildDoneBar(),

        // 待执行状态提示
        if (!_isExecuting && !_isDone)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.rocket_launch_outlined, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 12),
                  const Text('确认无误后，点击下方按钮开始投产'),
                  const SizedBox(height: 4),
                  Text(
                    '将对 ${_selectedSns.length} 台设备批量上传并启动打印',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 打印机选择
  // ═══════════════════════════════════════════════════════════

  Widget _buildPrinterSection(
    List<FarmPrinterState> readyPrinters,
    List<FarmPrinterState> pendingPrinters,
    List<FarmPrinterState> offlinePrinters,
    Map<String, BedInspectionResult> inspectionResults,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          Row(
            children: [
              const Icon(Icons.print_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                '选择打印机  ${_selectedSns.length}/${readyPrinters.length + pendingPrinters.length} 台在线',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              // 床板检测按钮
              _InspectButton(
                isInspecting: _isInspecting,
                onTap: _isInspecting
                    ? null
                    : () {
                        ref
                            .read(bedInspectionResultsProvider.notifier)
                            .inspectAll();
                      },
              ),
              const SizedBox(width: 4),
              if (!_isExecuting) ...[
                _QuickAction(
                  label: '全选就绪',
                  onTap: () => setState(() {
                    for (final p in readyPrinters) {
                      _selectedSns.add(p.sn);
                    }
                  }),
                ),
                const SizedBox(width: 8),
                _QuickAction(
                  label: '取消全选',
                  onTap: () => setState(() => _selectedSns.clear()),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // 就绪打印机网格
          if (readyPrinters.isEmpty && pendingPrinters.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '没有可用的在线打印机',
                  style: TextStyle(color: Colors.grey.shade500),
                ),
              ),
            )
          else
            SizedBox(
              height: 180,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: readyPrinters.length + pendingPrinters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  if (index < readyPrinters.length) {
                    final printer = readyPrinters[index];
                    final isSelected = _selectedSns.contains(printer.sn);
                    final inspectionResult = inspectionResults[printer.sn];
                    return _buildSelectablePrinterCard(printer, isSelected,
                        inspectionResult: inspectionResult);
                  } else {
                    final printer = pendingPrinters[index - readyPrinters.length];
                    final inspectionResult = inspectionResults[printer.sn];
                    return _buildPendingPrinterCard(printer,
                        inspectionResult: inspectionResult);
                  }
                },
              ),
            ),

          // 离线打印机
          if (offlinePrinters.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${offlinePrinters.length} 台离线',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ],
      ),
    );
  }

  /// IP 待解析的打印机（在线但无 IP，不可选）
  Widget _buildPendingPrinterCard(FarmPrinterState printer,
      {BedInspectionResult? inspectionResult}) {
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
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      printer.displayName ?? printer.sn,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(printer.sn,
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('IP 解析中...',
                  style: TextStyle(fontSize: 9, color: Colors.orange.shade600)),
              const SizedBox(height: 4),
              // 检测结果（仅显示文字状态，无图因为 IP 未知）
              _buildInspectionStatusLine(inspectionResult),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectablePrinterCard(FarmPrinterState printer, bool isSelected,
      {BedInspectionResult? inspectionResult}) {
    final isOnline = printer.isOnline && printer.ip != '—';
    final frameUrl =
        'http://${printer.ip}:${printer.port}/server/files/camera/monitor.jpg';

    return GestureDetector(
      onTap: _isExecuting
          ? null
          : () => setState(() {
                if (isSelected) {
                  _selectedSns.remove(printer.sn);
                } else if (isOnline) {
                  _selectedSns.add(printer.sn);
                }
              }),
      child: SizedBox(
        width: 160,
        child: Card(
          elevation: isSelected ? 3 : 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: isSelected
                  ? Colors.blue
                  : inspectionResult?.hasForeignObjects == true
                      ? Colors.red.shade300
                      : Colors.transparent,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // 选中框
                    Icon(
                      isSelected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: isOnline ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    // 状态点
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOnline ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        printer.displayName ?? printer.sn,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isOnline ? null : Colors.grey,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  printer.sn,
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${printer.ip}:${printer.port}',
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // 摄像头快照
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: double.infinity,
                    height: 64,
                    child: _isInspecting && inspectionResult == null
                        ? Container(
                            color: Colors.grey.shade100,
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.blue.shade300),
                              ),
                            ),
                          )
                        : Image.network(
                            frameUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.shade100,
                              child: Icon(Icons.videocam_off,
                                  size: 20, color: Colors.grey.shade300),
                            ),
                            loadingBuilder: (_, child, progress) {
                              if (progress == null) return child;
                              return Container(
                                color: Colors.grey.shade100,
                                child: Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.grey.shade300),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                // 检测结果
                _buildInspectionStatusLine(inspectionResult),
                const Spacer(),
                // 执行状态指示
                if (_isExecuting || _isDone)
                  _buildPrinterStateIcon(printer.sn),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrinterStateIcon(String sn) {
    final state = _printerStates[sn];
    if (state == null) return const SizedBox.shrink();

    IconData icon;
    Color color;
    String label;

    switch (state) {
      case BatchPrintPrinterState.queued:
        return Icon(Icons.hourglass_empty, size: 14, color: Colors.grey.shade400);
      case BatchPrintPrinterState.uploading:
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        );
      case BatchPrintPrinterState.uploadDone:
        icon = Icons.cloud_done_outlined;
        color = Colors.blue;
        label = '上传完成';
      case BatchPrintPrinterState.startingPrint:
        icon = Icons.play_circle_outline;
        color = Colors.orange;
        label = '启动中';
      case BatchPrintPrinterState.success:
        icon = Icons.check_circle;
        color = Colors.green;
        label = '成功';
      case BatchPrintPrinterState.uploadFailed:
        icon = Icons.error_outline;
        color = Colors.red;
        label = '上传失败';
      case BatchPrintPrinterState.printFailed:
        icon = Icons.warning_amber;
        color = Colors.orange;
        label = '打印失败';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 9, color: color)),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 打印选项
  // ═══════════════════════════════════════════════════════════

  Widget _buildOptionsSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 20),
          const SizedBox(width: 8),
          const Text('打印选项', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 24),
          const Text('Plate ID:'),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: TextField(
              controller: TextEditingController(text: '$_printPlate'),
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              enabled: !_isExecuting,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0) _printPlate = n;
              },
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '(3MF 多盘文件选择打印盘)',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 操作按钮
  // ═══════════════════════════════════════════════════════════

  Widget _buildActionButton(bool mqttAvailable, List<FarmPrinterState> online) {
    final canStart = !_isExecuting &&
        _filePath != null &&
        _selectedSns.isNotEmpty &&
        mqttAvailable;

    String buttonText;
    if (_isExecuting) {
      buttonText = '执行中...';
    } else if (_isDone) {
      buttonText = '已完成';
    } else {
      buttonText = '开始打印 (${_selectedSns.length} 台)';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: ElevatedButton.icon(
          icon: _isExecuting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.print),
          label: Text(buttonText, style: const TextStyle(fontSize: 15)),
          onPressed: canStart ? _startPrint : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: _isDone
                ? Colors.green
                : _isExecuting
                    ? Colors.grey
                    : Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 进度显示
  // ═══════════════════════════════════════════════════════════

  Widget _buildProgressSection() {
    final progress = _progress;

    // 按阶段分组打印机
    final groups = _buildPrinterGroups();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              const Icon(Icons.sync, size: 20),
              const SizedBox(width: 8),
              Text(
                _isDone ? '执行完成' : '执行进度',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (_isDone)
                Icon(
                  progress?.hasFailures == true
                      ? Icons.warning_amber
                      : Icons.check_circle,
                  color:
                      progress?.hasFailures == true ? Colors.orange : Colors.green,
                  size: 20,
                ),
            ],
          ),

          const SizedBox(height: 12),

          // 进度条
          if (progress != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.isDone ? 1.0 : progress.progress,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
              ),
            ),
            const SizedBox(height: 8),

            // 统计
            _buildStatsRow(progress),
          ],

          const SizedBox(height: 12),

          // 阶段分组视图
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Text(
                      '等待开始...',
                      style: TextStyle(color: Colors.grey.shade400),
                    ),
                  )
                : ListView(
                    children: groups,
                  ),
          ),
        ],
      ),
    );
  }

  /// 构建统计行
  Widget _buildStatsRow(BatchPrintProgress? progress) {
    if (progress == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        _Stat(label: '排队', count: progress.queuedCount, color: Colors.grey),
        _Stat(label: '上传中', count: progress.uploadingCount, color: Colors.blue),
        _Stat(label: '启动中', count: progress.startingPrintCount, color: Colors.orange),
        _Stat(label: '成功', count: progress.successCount, color: Colors.green),
        _Stat(label: '失败', count: progress.failedCount, color: Colors.red),
        Text(
          '${progress.completedCount}/${progress.totalPrinters}',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  /// 按阶段分组打印机列表
  List<Widget> _buildPrinterGroups() {
    final stateMap = Map<String, BatchPrintPrinterState>.from(_printerStates);

    // 定义分组（按流程顺序）
    final groupDefs = [
      _GroupDef(
        label: '排队中',
        icon: Icons.hourglass_empty,
        color: Colors.grey.shade600,
        bgColor: Colors.grey.shade50,
        states: {BatchPrintPrinterState.queued},
      ),
      _GroupDef(
        label: '上传文件',
        icon: Icons.cloud_upload_outlined,
        color: Colors.blue.shade700,
        bgColor: Colors.blue.shade50,
        states: {BatchPrintPrinterState.uploading},
      ),
      _GroupDef(
        label: '启动打印',
        icon: Icons.play_circle_outline,
        color: Colors.orange.shade700,
        bgColor: Colors.orange.shade50,
        states: {BatchPrintPrinterState.uploadDone, BatchPrintPrinterState.startingPrint},
      ),
      _GroupDef(
        label: '已完成',
        icon: Icons.check_circle,
        color: Colors.green.shade700,
        bgColor: Colors.green.shade50,
        states: {BatchPrintPrinterState.success},
        defaultExpanded: false,
      ),
      _GroupDef(
        label: '失败',
        icon: Icons.error_outline,
        color: Colors.red.shade700,
        bgColor: Colors.red.shade50,
        states: {BatchPrintPrinterState.uploadFailed, BatchPrintPrinterState.printFailed},
        defaultExpanded: true,
      ),
    ];

    final widgets = <Widget>[];
    for (final def_ in groupDefs) {
      final members = <MapEntry<String, BatchPrintPrinterState>>[];
      for (final entry in stateMap.entries) {
        if (def_.states.contains(entry.value)) {
          members.add(entry);
        }
      }

      if (members.isEmpty) continue;

      widgets.add(_buildGroup(def_, members));
      widgets.add(const SizedBox(height: 4));
    }

    return widgets;
  }

  /// 单个阶段分组
  Widget _buildGroup(
    _GroupDef def_,
    List<MapEntry<String, BatchPrintPrinterState>> members,
  ) {
    return Card(
      elevation: 0,
      color: def_.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: def_.color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分组标题
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(def_.icon, size: 16, color: def_.color),
                const SizedBox(width: 6),
                Text(
                  def_.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: def_.color,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: def_.color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${members.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: def_.color,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 分组内打印机列表
          ...members.map((entry) => _buildPrinterItem(entry.key, entry.value, def_.color)),
        ],
      ),
    );
  }

  /// 分组内单台打印机条目
  Widget _buildPrinterItem(String sn, BatchPrintPrinterState state, Color groupColor) {
    final error = _getError(sn);
    final elapsed = _getElapsed(sn);
    final uploadProgress = _getUploadProgress(sn);

    final (statusIcon, statusLabel) = switch (state) {
      BatchPrintPrinterState.queued => (
          Icons.hourglass_empty,
          '等待中',
        ),
      BatchPrintPrinterState.uploading => (
          Icons.cloud_upload_outlined,
          uploadProgress != null
              ? '${(uploadProgress * 100).toStringAsFixed(0)}%'
              : '上传中',
        ),
      BatchPrintPrinterState.uploadDone => (
          Icons.cloud_done_outlined,
          '上传完成',
        ),
      BatchPrintPrinterState.startingPrint => (
          Icons.play_circle_outline,
          '正在启动',
        ),
      BatchPrintPrinterState.success => (
          Icons.check_circle,
          '打印已启动',
        ),
      BatchPrintPrinterState.uploadFailed => (
          Icons.error_outline,
          '上传失败',
        ),
      BatchPrintPrinterState.printFailed => (
          Icons.warning_amber,
          '打印启动失败',
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: groupColor.withOpacity(0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, size: 14, color: groupColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  sn,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (error != null) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Tooltip(
                    message: error,
                    child: Text(
                      error,
                      style: TextStyle(fontSize: 10, color: Colors.red.shade400),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              if (elapsed != null) ...[
                const SizedBox(width: 6),
                Text(
                  '${elapsed.inSeconds}s',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ],
              const SizedBox(width: 6),
              Text(
                statusLabel,
                style: TextStyle(fontSize: 10, color: groupColor),
              ),
            ],
          ),
          // 上传进度条 + 取消按钮
          if (state == BatchPrintPrinterState.uploading && uploadProgress != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: uploadProgress.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation(groupColor),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _coordinator?.cancelUpload(sn),
                  child: Icon(Icons.close, size: 14, color: Colors.grey.shade500),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String? _getError(String sn) {
    // 从最近更新日志中查找错误信息
    for (final update in _updateLog.reversed) {
      if (update.sn == sn && update.error != null) {
        return update.error;
      }
    }
    return null;
  }

  Duration? _getElapsed(String sn) {
    for (final update in _updateLog.reversed) {
      if (update.sn == sn && update.elapsed != null) {
        return update.elapsed;
      }
    }
    return null;
  }

  double? _getUploadProgress(String sn) {
    for (final update in _updateLog.reversed) {
      if (update.sn == sn && update.uploadProgress != null) {
        return update.uploadProgress;
      }
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════
  // 完成操作栏
  // ═══════════════════════════════════════════════════════════

  Widget _buildDoneBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (_hasFailures)
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试失败项'),
                onPressed: _retryFailed,
              ),
            ),
          if (_hasFailures) const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回仪表盘'),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 操作逻辑
  // ═══════════════════════════════════════════════════════════

  Future<void> _pickFile() async {
    try {
      const typeGroup = XTypeGroup(
        label: '3D 打印文件',
        extensions: ['gcode', '3mf', 'zip', 'g', 'gco'],
      );
      final xfile = await openFile(acceptedTypeGroups: [typeGroup]);
      if (xfile == null) return;

      if (!_disposed) {
        setState(() {
          _filePath = xfile.path;
          _fileName = xfile.name;
        });
      }
    } catch (e) {
      if (_disposed || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择文件失败: $e')),
      );
    }
  }

  Future<void> _startPrint() async {
    if (_filePath == null || _selectedSns.isEmpty) return;

    // 构建连接信息
    final store = ref.read(farmStoreProvider);
    final connectionInfo = <String, (String ip, int port, String apiKey)>{};

    final validSns = <String>[];
    for (final sn in _selectedSns) {
      final printer = store.getPrinter(sn);
      if (printer == null) continue;
      if (!printer.hasValidIp || !printer.isOnline) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${printer.displayName ?? sn} 不可用（离线或 IP 未知）'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        continue;
      }
      connectionInfo[sn] = (printer.ip, printer.port, ''); // apiKey 暂空
      validSns.add(sn);
    }

    if (validSns.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可用的打印机')),
        );
      }
      return;
    }

    // 创建协调器并监听
    final gateway = ref.read(farmCommandGatewayProvider);
    if (gateway == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MQTT 未连接，无法启动打印')),
        );
      }
      return;
    }

    setState(() {
      _isExecuting = true;
      _isDone = false;
      _printerStates.clear();
      _progress = null;
      _updateLog.clear();
    });

    _coordinator = BatchPrintCoordinator();

    // 订阅流
    _coordinator!.printerUpdateStream.listen((update) {
      if (_disposed || !mounted) return;
      setState(() {
        _printerStates[update.sn] = update.state;
        _updateLog.add(update);
      });
    });

    _coordinator!.progressStream.listen((progress) {
      if (_disposed || !mounted) return;
      setState(() {
        _progress = progress;
        if (progress.isDone) {
          _isExecuting = false;
          _isDone = true;
        }
      });
    });

    await _coordinator!.execute(
      printerSns: validSns,
      connectionInfo: connectionInfo,
      localFilePath: _filePath!,
      remoteFileName: _fileName!,
      gateway: gateway,
      printPlate: _printPlate,
    );
  }

  Future<void> _retryFailed() async {
    if (_coordinator == null) return;

    final gateway = ref.read(farmCommandGatewayProvider);
    if (gateway == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MQTT 未连接，无法重试')),
        );
      }
      return;
    }

    setState(() {
      _isExecuting = true;
      _isDone = false;
      _progress = null;
    });

    await _coordinator!.retryFailed(
      gateway: gateway,
      printPlate: _printPlate,
    );
  }

  bool get _hasFailures {
    return _printerStates.values.any(
      (s) =>
          s == BatchPrintPrinterState.uploadFailed ||
          s == BatchPrintPrinterState.printFailed,
    );
  }
}

/// 床板检测按钮
class _InspectButton extends StatelessWidget {
  final bool isInspecting;
  final VoidCallback? onTap;

  const _InspectButton({required this.isInspecting, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isInspecting)
              const SizedBox(
                width: 14,
                height: 14,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
              )
            else
              Icon(Icons.search, size: 14, color: Colors.blue.shade700),
            const SizedBox(width: 2),
            Text(
              isInspecting ? '检测中' : '床板检测',
              style: TextStyle(
                fontSize: 11,
                color: onTap == null ? Colors.grey : Colors.blue.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 检测状态行（紧凑，用于卡片内嵌）
Widget _buildInspectionStatusLine(BedInspectionResult? result) {
  if (result == null) {
    return Text('待检测',
        style: TextStyle(fontSize: 9, color: Colors.grey.shade400));
  }

  if (result.hasForeignObjects) {
    return Row(
      children: [
        const Icon(Icons.warning_amber_rounded, size: 12, color: Colors.red),
        const SizedBox(width: 2),
        Expanded(
          child: Tooltip(
            message: result.bedForeignObjects.description,
            child: Text(
              result.bedForeignObjects.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: Colors.red.shade700, height: 1.3),
            ),
          ),
        ),
      ],
    );
  }

  if (result.isReadyToPrint) {
    return Row(
      children: [
        Icon(Icons.check_circle, size: 12, color: Colors.green.shade600),
        const SizedBox(width: 2),
        Text(
          result.printReadiness.caution ? '可打印（注意）' : '床板干净',
          style: TextStyle(fontSize: 9, color: Colors.green.shade700),
        ),
      ],
    );
  }

  return Row(
    children: [
      Icon(Icons.info_outline, size: 12, color: Colors.orange.shade600),
      const SizedBox(width: 2),
      Expanded(
        child: Tooltip(
          message: result.printReadiness.reason,
          child: Text(
            result.printReadiness.reason,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9, color: Colors.orange.shade700),
          ),
        ),
      ),
    ],
  );
}

/// 快速操作按钮
class _QuickAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
        ),
      ),
    );
  }
}

/// 阶段分组定义
class _GroupDef {
  final String label;
  final IconData icon;
  final Color color;
  final Color bgColor;
  final Set<BatchPrintPrinterState> states;
  final bool defaultExpanded;

  const _GroupDef({
    required this.label,
    required this.icon,
    required this.color,
    required this.bgColor,
    required this.states,
    this.defaultExpanded = true,
  });
}

/// 统计数字
class _Stat extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _Stat({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 4),
        Text('$label ', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Text('$count', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }
}

/// 步骤圆圈指示器
class _StepCircle extends StatelessWidget {
  final int step;
  final String label;
  final bool isActive;
  final bool isDone;
  final bool enabled;

  const _StepCircle({
    required this.step,
    required this.label,
    required this.isActive,
    required this.isDone,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive || isDone
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade400;

    return Opacity(
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
    );
  }
}

/// 材料编辑行
class _MaterialRow extends StatelessWidget {
  final ProductMaterial material;
  final int index;
  final ValueChanged<ProductMaterial> onChanged;
  final VoidCallback onDelete;

  const _MaterialRow({
    required this.material,
    required this.index,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // 颜色圆点
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(material.argb),
                border: Border.all(color: Colors.grey.shade300),
              ),
            ),
            const SizedBox(width: 8),
            // 挤出机编号
            Text('E${index + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            // 颜色名
            SizedBox(
              width: 100,
              child: TextField(
                controller: TextEditingController(text: material.colorName),
                decoration: const InputDecoration(
                  labelText: '颜色',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => onChanged(material.copyWith(colorName: v)),
              ),
            ),
            const SizedBox(width: 12),
            // 克重
            SizedBox(
              width: 80,
              child: TextField(
                controller: TextEditingController(text: material.grams.toStringAsFixed(1)),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '克重',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final g = double.tryParse(v);
                  if (g != null) onChanged(material.copyWith(grams: g));
                },
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: onDelete,
              color: Colors.red.shade400,
              tooltip: '删除',
            ),
          ],
        ),
      ),
    );
  }
}
