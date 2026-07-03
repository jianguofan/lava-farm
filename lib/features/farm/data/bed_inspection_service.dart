/// 床板异物检测服务
///
/// 通过获取打印机摄像头快照，调用 LLM 视觉模型分析床板上是否有异物，
/// 返回结构化检测结果供 UI 展示。
///
/// 流程：
///   1. MQTT camera.start_monitor 启动摄像头
///   2. HTTP GET 摄像头快照
///   3. 图片压缩（确保 ≤100KB，满足千问 proxy 限制）
///   4. Base64 编码 → LLM API 调用
///   5. 解析 JSON → BedInspectionResult
library bed_inspection_service;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../domain/models/bed_inspection_result.dart';
import 'farm_mqtt_router.dart';
import 'farm_printer_state.dart';

/// LLM 视觉检测 prompt
const String _inspectionPrompt = '''### 角色

你是3D打印机内部视觉检测器。分析照片，输出JSON判断床板是否有异物、能否立即打印。

### 异物定义

**是异物**：未取下的打印模型/底座/裙边、耗材废料（炒面、支撑碎片、擦料残余、断丝）、遗落的工具零件（铲刀、扳手、螺丝）、大面积液体/胶水残留（>5cm²）

**不是异物**：床板夹具、调平螺丝、PEI纹理、Logo、网格线、投影、反光、划痕、氧化变色

**粒度**：≥3mm才报告；散落碎片群视为一个异物。

### 输出JSON Schema（严格遵守，仅输出JSON）

{
  "inspection": {
    "timestamp": "ISO8601",
    "components": {
      "print_bed":  {"detected": bool, "confidence": 0.0},
      "print_head": {"detected": bool, "confidence": 0.0},
      "casing":     {"detected": bool, "confidence": 0.0}
    },
    "bed_foreign_objects": {
      "has_objects": false,
      "description": "对异物的中文描述，包含数量、类型、颜色、形状、位置、大致高度。无异物时为空字符串"
    },
    "print_readiness": {
      "is_ready": false,
      "caution": false,
      "reason": "判断依据",
      "recommended_action": "proceed|clean_and_proceed|remove_objects_and_proceed|manual_inspection_required"
    }
  }
}

### 打印就绪判断

| is_ready | caution | 条件                                                         |
| -------- | ------- | ------------------------------------------------------------ |
| true     | false   | 床面干净                                                     |
| true     | true    | 仅有极薄擦料线（高度≈0，<5cm²），不影响首层                  |
| false    | false   | 有高度≥1mm异物在打印区 / 液体>5cm² / 硬质杂物 / 异物在调平探测区 |

不确定时返回 is_ready=false。

### 边界处理

- 遮挡/反光/过暗 → 在 reason 中说明，降低 confidence
- 异物堆叠 → 报告最上层高度，注明"下方可能有其他物体"
- 置信度<0.75 → recommended_action="manual_inspection_required"

### 输出规则

仅输出JSON，禁止markdown围栏、解释文字、无null值，枚举值精确匹配，整数不引号，浮点保留2位。''';

/// 床板异物检测服务
class BedInspectionService {
  final FarmMqttRouter _router;
  final LLMProvider _llmProvider;
  final HttpClient _httpClient = HttpClient();

  BedInspectionService({
    required FarmMqttRouter router,
  })  : _router = router,
        _llmProvider = LLMAdapter(
          apiKey: 'sk-df3d817d7c83417b',
          model: '',
          baseUrl:
              'http://agent-platform.s.com/api/sap/v1/run/llm/mdl_ac771085',
          completionsPath: '',
          temperature: 0.7,
          timeout: const Duration(seconds: 30),
        );

  /// 检测单台打印机
  ///
  /// 返回 [BedInspectionResult] 或 null（摄像头不可用、LLM 调用失败等）。
  Future<BedInspectionResult?> inspectPrinter(
      FarmPrinterState printer) async {
    final sn = printer.sn;
    final ip = printer.ip;
    final port = printer.port;

    if (!printer.hasValidIp) {
      debugPrint('[BedInspection] $sn: 无有效 IP，跳过');
      return null;
    }

    try {
      // 1. 启动摄像头
      debugPrint('[BedInspection] $sn: 启动摄像头…');
      await _startCamera(sn);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // 2. 下载摄像头快照
      final frameUrl = 'http://$ip:$port/server/files/camera/monitor.jpg';
      debugPrint('[BedInspection] $sn: 下载快照 $frameUrl');
      final imageBytes = await _downloadImage(frameUrl).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[BedInspection] $sn: 下载快照超时');
          return null;
        },
      );

      if (imageBytes == null || imageBytes.length < 100) {
        debugPrint('[BedInspection] $sn: 快照为空或过小，跳过');
        return null;
      }

      // 3. 压缩图片
      debugPrint(
          '[BedInspection] $sn: 原始图片 ${(imageBytes.length / 1024).toStringAsFixed(1)}KB');
      final compressedBytes = _compressImage(imageBytes);
      debugPrint(
          '[BedInspection] $sn: 压缩后 ${(compressedBytes.length / 1024).toStringAsFixed(1)}KB');

      // 4. 调用 LLM
      final result = await _callLLM(compressedBytes, sn);
      return result;
    } catch (e, stack) {
      debugPrint('[BedInspection] $sn: 检测失败 — $e');
      debugPrint('$stack');
      return null;
    }
  }

  /// 批量检测（限制并发数）
  Future<Map<String, BedInspectionResult>> inspectAll(
    List<FarmPrinterState> printers, {
    int concurrency = 3,
  }) async {
    final results = <String, BedInspectionResult>{};
    final onlinePrinters =
        printers.where((p) => p.isOnline && p.hasValidIp).toList();

    debugPrint(
        '[BedInspection] 开始检测 ${onlinePrinters.length}/${printers.length} 台在线设备');

    // 并发控制：按 concurrency 分批
    for (var i = 0; i < onlinePrinters.length; i += concurrency) {
      final batch = onlinePrinters.skip(i).take(concurrency);
      final batchResults = await Future.wait(
        batch.map((p) => inspectPrinter(p)),
      );
      for (var j = 0; j < batch.length; j++) {
        final printer = batch.elementAt(j);
        final result = batchResults[j];
        if (result != null) {
          results[printer.sn] = result;
        }
      }
    }

    debugPrint(
        '[BedInspection] 检测完成: ${results.length}/${onlinePrinters.length} 成功');
    return results;
  }

  /// MQTT 启动摄像头（fire-and-forget）
  Future<void> _startCamera(String sn) async {
    try {
      await _router.sendCommand(
        sn,
        'camera.start_monitor',
        {
          'domain': 'lan',
          'interval': 0,
          'expect_pw': false,
          'clientid': 'lava-farm-inspect-$sn',
        },
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      // camera 命令可能无响应，忽略超时
    }
  }

  /// HTTP 下载图片
  Future<Uint8List?> _downloadImage(String url) async {
    final uri = Uri.parse(url);
    final request = await _httpClient.getUrl(uri);
    request.headers.set('Accept', 'image/jpeg, image/png, image/*');
    final response = await request.close();

    if (response.statusCode != 200) {
      debugPrint('[BedInspection] HTTP ${response.statusCode} for $url');
      return null;
    }

    final bytes = await response.fold<List<int>>(
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
    return Uint8List.fromList(bytes);
  }

  /// 图片压缩
  ///
  /// 千问 proxy 限制约 118KB，目标 ≤100KB。
  /// 缩放策略：最长边 ≤1024px，JPEG quality 从 85 递减至 40。
  Uint8List _compressImage(Uint8List bytes) {
    // 如果已经足够小，直接返回
    if (bytes.length <= 100 * 1024) return bytes;

    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;

      final originalWidth = decoded.width;
      final originalHeight = decoded.height;

      // 检查尺寸合法性（千问要求 >10px）
      if (originalWidth <= 10 || originalHeight <= 10) return bytes;

      // 缩放
      img.Image resized = decoded;
      const maxDimension = 1024;
      if (originalWidth > maxDimension || originalHeight > maxDimension) {
        resized = img.copyResize(decoded,
            width: originalWidth > originalHeight ? maxDimension : null,
            height: originalHeight > originalWidth ? maxDimension : null,
            interpolation: img.Interpolation.average);
      }

      // 递减质量编码
      for (final quality in [85, 70, 55, 40]) {
        final encoded = img.encodeJpg(resized, quality: quality);
        if (encoded.length <= 100 * 1024) {
          return Uint8List.fromList(encoded);
        }
      }

      // 最后尝试最低质量
      final encoded = img.encodeJpg(resized, quality: 30);
      return Uint8List.fromList(encoded);
    } catch (e) {
      debugPrint('[BedInspection] 图片压缩失败: $e');
      return bytes; // 返回原图，让 LLM 自己处理
    }
  }

  /// 调用 LLM API 分析图片
  Future<BedInspectionResult?> _callLLM(
      Uint8List imageBytes, String sn) async {
    try {
      final base64Data = base64Encode(imageBytes);
      final imagePart = ContentPart.imageBase64(
        base64Data,
        mimeType: 'image/jpeg',
        detail: 'auto',
      );

      final messages = [
        {
          'role': 'user',
          'content': [
            ContentPart.text(_inspectionPrompt),
            imagePart,
          ],
        },
      ];

      debugPrint('[BedInspection] $sn: 调用 LLM…');
      final events = await _llmProvider
          .chat(messages: messages, tools: const [])
          .timeout(const Duration(seconds: 25));

      // 从 events 中提取文本
      final textBuffer = StringBuffer();
      for (final event in events) {
        if (event is TextDelta) {
          textBuffer.write(event.text);
        }
      }

      final fullText = textBuffer.toString();
      debugPrint(
          '[BedInspection] $sn: LLM 响应 ${fullText.length} 字符');

      return _parseResponse(fullText, sn);
    } catch (e, stack) {
      debugPrint('[BedInspection] $sn: LLM 调用失败 — $e');
      debugPrint('$stack');
      return null;
    }
  }

  /// 解析 LLM 返回的 JSON
  BedInspectionResult? _parseResponse(String text, String sn) {
    try {
      // 尝试直接解析
      final json = jsonDecode(text) as Map<String, dynamic>;
      return BedInspectionResult.fromJson(json);
    } catch (_) {
      // 尝试去除 markdown 围栏后解析
      try {
        final cleaned = text
            .replaceAll(RegExp(r'^```(?:json)?\s*', multiLine: true), '')
            .replaceAll(RegExp(r'```\s*$', multiLine: true), '')
            .trim();
        final json = jsonDecode(cleaned) as Map<String, dynamic>;
        return BedInspectionResult.fromJson(json);
      } catch (e) {
        debugPrint('[BedInspection] $sn: JSON 解析失败 — $e');
        debugPrint('[BedInspection] 原始响应: ${text.substring(0, text.length.clamp(0, 500))}');
        return null;
      }
    }
  }

  void dispose() {
    _httpClient.close();
    _llmProvider.dispose();
  }
}
