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
const String _inspectionPrompt = "你正在检查的打印机序列号是：__PRINTER_SN__。必须在输出中返回这个序列号。";

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
          streaming: false,
          baseUrl:
              'http://agent-platform.s.com/api/sap/v1/run/agent/agt_9ddb7f58',
          completionsPath: '',
          temperature: 0.3,
          timeout: const Duration(seconds: 120),
        );

  /// 检测单台打印机
  ///
  /// 返回 [BedInspectionResult] 或 null（摄像头不可用、LLM 调用失败等）。
  Future<BedInspectionResult?> inspectPrinter(FarmPrinterState printer) async {
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
        const Duration(seconds: 30),
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
      if (result != null) {
        debugPrint('[BedInspection] $sn: === 检测结果 ===');
        debugPrint(
            '[BedInspection] $sn: statusSummary=${result.statusSummary}');
        debugPrint(
            '[BedInspection] $sn: 异物: ${result.bedForeignObjects.description}');
        debugPrint(
            '[BedInspection] $sn: 建议: ${result.printReadiness.recommendedActionLabel}');
        debugPrint('[BedInspection] $sn: 原因: ${result.printReadiness.reason}');
      }
      return result;
    } catch (e, stack) {
      debugPrint('[BedInspection] $sn: 检测失败 — $e');
      debugPrint('$stack');
      return null;
    }
  }

  /// 批量检测
  ///
  /// 流程：
  ///   1. 并发启动所有摄像头（MQTT fire-and-forget）
  ///   2. 统一等待一次（确保摄像头启动完毕）
  ///   3. 并发下载+LLM 分析（semaphore=2，避免单台超时阻塞全部）
  Future<Map<String, BedInspectionResult>> inspectAll(
    List<FarmPrinterState> printers,
  ) async {
    final results = <String, BedInspectionResult>{};
    final onlinePrinters =
        printers.where((p) => p.isOnline && p.hasValidIp).toList();

    if (onlinePrinters.isEmpty) return results;

    debugPrint(
        '[BedInspection] 开始检测 ${onlinePrinters.length}/${printers.length} 台在线设备');

    // Phase 1: 并发启动所有摄像头
    debugPrint('[BedInspection] Phase 1: 并发启动 ${onlinePrinters.length} 台摄像头…');
    await Future.wait(
      onlinePrinters.map((p) => _startCamera(p.sn)),
    );
    // 统一等待一次，确保所有摄像头都就绪
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // Phase 2: 并发下载+分析（semaphore=2，单台超时不阻塞其他）
    debugPrint(
        '[BedInspection] Phase 2: 并发下载+分析 ${onlinePrinters.length} 台 (并发=2)…');
    final semaphore = _Semaphore(2);
    await Future.wait(
      onlinePrinters.map((printer) async {
        await semaphore.acquire();
        try {
          debugPrint('[BedInspection] ▶ ${printer.sn} 开始');
          final result = await _downloadAndAnalyze(printer);
          if (result != null && result.sn.isNotEmpty) {
            results[result.sn] = result;
          }
          debugPrint(
              '[BedInspection] ◀ ${printer.sn} ${result != null ? "✅" : "❌"}');
        } finally {
          semaphore.release();
        }
      }),
    );

    debugPrint(
        '[BedInspection] 检测完成: ${results.length}/${onlinePrinters.length} 成功');
    return results;
  }

  /// 下载快照 + LLM 分析（不含摄像头启动）
  Future<BedInspectionResult?> _downloadAndAnalyze(
      FarmPrinterState printer) async {
    final sn = printer.sn;
    final ip = printer.ip;
    final port = printer.port;

    try {
      // 下载摄像头快照
      final frameUrl = 'http://$ip:$port/server/files/camera/monitor.jpg';
      debugPrint('[BedInspection] $sn: 下载快照…');
      final imageBytes = await _downloadImage(frameUrl).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('[BedInspection] $sn: 下载快照超时');
          return null;
        },
      );

      if (imageBytes == null || imageBytes.length < 100) {
        debugPrint('[BedInspection] $sn: 快照为空或过小，跳过');
        return null;
      }

      // 压缩图片
      debugPrint(
          '[BedInspection] $sn: 原始图片 ${(imageBytes.length / 1024).toStringAsFixed(1)}KB');
      final compressedBytes = _compressImage(imageBytes);
      debugPrint(
          '[BedInspection] $sn: 压缩后 ${(compressedBytes.length / 1024).toStringAsFixed(1)}KB');

      // 调用 LLM
      final result = await _callLLM(compressedBytes, sn);
      if (result != null) {
        debugPrint(
            '[BedInspection] $sn: statusSummary=${result.statusSummary}');
        debugPrint(
            '[BedInspection] $sn: 建议: ${result.printReadiness.recommendedActionLabel}');
      }
      return result;
    } catch (e, stack) {
      debugPrint('[BedInspection] $sn: 下载/分析失败 — $e');
      debugPrint('$stack');
      return null;
    }
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
  /// 策略：多级缩放 + 递减质量，确保产出 ≤100KB。
  ///   1. 若原图已 ≤100KB，直接返回
  ///   2. 逐级缩小尺寸（最长边: 1024 → 800 → 640 → 480）
  ///   3. 每级遍历质量 [80, 65, 50, 38]，命中 ≤100KB 立即返回
  ///   4. 最终兜底：480px + quality=25
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

      // 多级缩放 → 递减质量（外层尺寸优先，内层质量优先）
      const dimensions = [1024, 800, 640, 480];
      const qualities = [80, 65, 50, 38];

      for (final maxDim in dimensions) {
        // 仅在需要时缩放
        img.Image candidate = decoded;
        if (originalWidth > maxDim || originalHeight > maxDim) {
          candidate = img.copyResize(decoded,
              width: originalWidth > originalHeight ? maxDim : null,
              height: originalHeight > originalWidth ? maxDim : null,
              interpolation: img.Interpolation.average);
        }

        for (final quality in qualities) {
          final encoded = img.encodeJpg(candidate, quality: quality);
          if (encoded.length <= 100 * 1024) {
            debugPrint(
                '[BedInspection] 压缩完成: ${originalWidth}x$originalHeight → '
                '${candidate.width}x${candidate.height} quality=$quality '
                '${(encoded.length / 1024).toStringAsFixed(1)}KB');
            return Uint8List.fromList(encoded);
          }
        }
      }

      // 最终兜底：最小尺寸 + 最低质量
      final finalImg = img.copyResize(decoded,
          width: originalWidth > originalHeight ? 480 : null,
          height: originalHeight > originalWidth ? 480 : null,
          interpolation: img.Interpolation.average);
      final encoded = img.encodeJpg(finalImg, quality: 25);
      debugPrint(
          '[BedInspection] 兜底压缩: ${finalImg.width}x${finalImg.height} quality=25 '
          '${(encoded.length / 1024).toStringAsFixed(1)}KB');
      return Uint8List.fromList(encoded);
    } catch (e) {
      debugPrint('[BedInspection] 图片压缩失败: $e');
      return bytes; // 返回原图，让 LLM 自己处理
    }
  }

  /// 调用 LLM API 分析图片
  Future<BedInspectionResult?> _callLLM(Uint8List imageBytes, String sn) async {
    try {
      final base64Data = base64Encode(imageBytes);
      final imagePart = ContentPart.imageBase64(
        base64Data,
        mimeType: 'image/jpeg',
        detail: 'auto',
      );

      // 注入真实的打印机 SN 到 prompt 中
      final promptWithSn = _inspectionPrompt.replaceAll('__PRINTER_SN__', sn);

      final messages = [
        {
          'role': 'user',
          'content': [
            ContentPart.text(promptWithSn),
            imagePart,
          ],
        },
      ];

      debugPrint('[BedInspection] $sn: 调用 LLM…');

      final events = await _llmProvider.chat(
          messages: messages,
          tools: const []).timeout(const Duration(seconds: 120));

      debugPrint('[BedInspection] $sn: 收到 ${events.length} 个事件');

      // 从 events 中提取文本 + 诊断所有事件类型
      final textBuffer = StringBuffer();
      for (final event in events) {
        if (event is TextDelta) {
          textBuffer.write(event.text);
        } else if (event is StreamError) {
          debugPrint('[BedInspection] $sn: ⚠️ StreamError: ${event.message}');
        } else if (event is ReasoningDelta) {
          debugPrint(
              '[BedInspection] $sn: 💭 Reasoning: ${event.text.substring(0, event.text.length.clamp(0, 100))}');
        } else {
          debugPrint('[BedInspection] $sn: 📋 ${event.runtimeType}: $event');
        }
      }

      final fullText = textBuffer.toString();
      debugPrint('[BedInspection] $sn: LLM 原始响应:\n$fullText');

      final result = _parseResponse(fullText, sn);
      if (result != null) {
        debugPrint('[BedInspection] $sn: 解析成功 — '
            'hasForeignObjects=${result.hasForeignObjects}, '
            'isReady=${result.printReadiness.isReady}, '
            'action=${result.printReadiness.recommendedActionLabel}');
      }
      return result;
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
        debugPrint(
            '[BedInspection] 原始响应: ${text.substring(0, text.length.clamp(0, 500))}');
        return null;
      }
    }
  }

  void dispose() {
    _httpClient.close();
    _llmProvider.dispose();
  }
}

/// 简单信号量（避免跨文件导入）
class _Semaphore {
  int _permits;
  final List<Completer<void>> _waiters = [];

  _Semaphore(int maxPermits) : _permits = maxPermits;

  Future<void> acquire() async {
    if (_permits > 0) {
      _permits--;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
    _permits--;
  }

  void release() {
    _permits++;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}
