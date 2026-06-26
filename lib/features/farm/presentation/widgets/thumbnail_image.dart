/// PrintThumbnail — 可复用的打印缩略图组件
///
/// 自动从 [ThumbnailService] 获取缩略图，支持:
/// - 缓存命中 → 直接显示
/// - 加载中 → 显示 spinner
/// - 加载成功 → Image.memory 显示
/// - 加载失败 → Image.asset(gcodeCover.png) → Icon 降级
///
/// 当 [filename] 或 [sn] 变化时自动重新获取。
///
/// 使用示例:
/// ```dart
/// PrintThumbnail(
///   sn: printer.sn,
///   filename: printer.currentFile?.value,
///   ip: printer.ip,
///   port: printer.port,
/// )
/// ```

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../data/thumbnail_service.dart';

class PrintThumbnail extends ConsumerStatefulWidget {
  final String sn;
  final String? filename;
  final String ip;
  final int port;
  final double width;
  final double height;
  final bool showLoadingIndicator;

  const PrintThumbnail({
    super.key,
    required this.sn,
    required this.filename,
    required this.ip,
    required this.port,
    this.width = 80,
    this.height = 80,
    this.showLoadingIndicator = true,
  });

  @override
  ConsumerState<PrintThumbnail> createState() => _PrintThumbnailState();
}

class _PrintThumbnailState extends ConsumerState<PrintThumbnail> {
  Uint8List? _imageBytes;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(PrintThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filename != oldWidget.filename || widget.sn != oldWidget.sn) {
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final filename = widget.filename;
    if (filename == null || filename.isEmpty) {
      if (mounted) setState(() { _imageBytes = null; _isLoading = false; });
      return;
    }

    final service = ref.read(thumbnailServiceProvider);
    if (service == null) return;

    setState(() => _isLoading = true);

    final result = await service.getThumbnail(
      sn: widget.sn,
      ip: widget.ip,
      port: widget.port,
      filename: filename,
    );

    if (!mounted) return;
    setState(() {
      _imageBytes = result.imageBytes;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    // 加载中
    if (_isLoading && widget.showLoadingIndicator) {
      return Center(
        child: SizedBox(
          width: widget.width * 0.4,
          height: widget.width * 0.4,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // 有图片数据
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        fit: BoxFit.cover,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
    }

    return _buildFallback();
  }

  Widget _buildFallback() {
    // 尝试 gcodeCover.png 资源
    return Image.asset(
      'assets/images/gcodeCover.png',
      fit: BoxFit.cover,
      width: widget.width,
      height: widget.height,
      errorBuilder: (_, __, ___) {
        // 资源也不存在 → 纯 Icon 降级
        final iconSize = widget.width * 0.35;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image, size: iconSize, color: Colors.grey.shade400),
            if (widget.height >= 60)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '预览',
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade400),
                ),
              ),
          ],
        );
      },
    );
  }
}
