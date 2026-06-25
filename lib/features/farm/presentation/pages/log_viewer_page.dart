/// 日志查看页面
///
/// 读取 ~/.lava-farm/logs/ 下的 JSONL 日志文件，
/// 支持按日期、SN、方向、类别筛选。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  // ── 日志目录 ──
  late Directory _logDir;

  // ── 数据 ──
  List<String> _logFiles = [];            // 按日期排序的文件名列表
  String? _selectedFile;                  // 当前选中的文件
  List<Map<String, dynamic>> _entries = []; // 已加载的日志条目
  bool _isLoading = false;
  String? _error;

  // ── 筛选 ──
  String _filterSn = '';
  String _filterDir = '';     // 'in' / 'out' / ''
  String _filterCat = '';     // category name / ''
  String _searchText = '';

  // ── 分页 ──
  static const int _pageSize = 500;
  int _displayCount = 0;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    _logDir = Directory('$home/.lava-farm/logs');
    _scanFiles();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 文件扫描
  // ═══════════════════════════════════════════════════════════

  void _scanFiles() {
    try {
      if (!_logDir.existsSync()) {
        setState(() => _error = '日志目录不存在: ${_logDir.path}');
        return;
      }
      final files = _logDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .toList()
        ..sort((a, b) => b.compareTo(a)); // 最新在前

      setState(() {
        _logFiles = files;
        if (files.isNotEmpty && _selectedFile == null) {
          _selectedFile = files.first;
          _loadFile();
        }
      });
    } catch (e) {
      setState(() => _error = '扫描日志目录失败: $e');
    }
  }

  Future<void> _loadFile() async {
    if (_selectedFile == null) return;
    setState(() { _isLoading = true; _error = null; _entries = []; _displayCount = 0; });

    try {
      final file = File('${_logDir.path}/$_selectedFile');
      if (!await file.exists()) {
        setState(() { _error = '文件不存在'; _isLoading = false; });
        return;
      }

      // 逐行读取（倒序，最新在前）
      final lines = await file.readAsLines();
      final all = <Map<String, dynamic>>[];
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) continue;
        try {
          all.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (_) {}
      }

      setState(() {
        _entries = all;
        _displayCount = (_pageSize < all.length) ? _pageSize : all.length;
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = '读取日志失败: $e'; _isLoading = false; });
    }
  }

  void _loadMore() {
    if (_displayCount < _filteredEntries.length) {
      setState(() {
        _displayCount = (_displayCount + _pageSize > _filteredEntries.length)
            ? _filteredEntries.length
            : _displayCount + _pageSize;
      });
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 筛选
  // ═══════════════════════════════════════════════════════════

  List<Map<String, dynamic>> get _filteredEntries {
    return _entries.where((e) {
      if (_filterSn.isNotEmpty &&
          (e['sn'] as String?)?.toLowerCase().contains(_filterSn.toLowerCase()) != true) {
        return false;
      }
      if (_filterDir.isNotEmpty && e['dir'] != _filterDir) return false;
      if (_filterCat.isNotEmpty && e['cat'] != _filterCat) return false;
      if (_searchText.isNotEmpty) {
        final s = _searchText.toLowerCase();
        final matches = (e['sn']?.toString().toLowerCase().contains(s) == true) ||
            (e['method']?.toString().toLowerCase().contains(s) == true) ||
            (e['summary']?.toString().toLowerCase().contains(s) == true) ||
            (e['event']?.toString().toLowerCase().contains(s) == true) ||
            (e['params']?.toString().toLowerCase().contains(s) == true) ||
            (e['cat']?.toString().toLowerCase().contains(s) == true);
        if (!matches) return false;
      }
      return true;
    }).toList();
  }

  int get _totalFiltered => _filteredEntries.length;

  // ═══════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志查看'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _isLoading ? null : () { _scanFiles(); if (_selectedFile != null) _loadFile(); },
          ),
        ],
      ),
      body: Column(
        children: [
          // ── 文件选择 + 筛选 ──
          _buildToolbar(),
          // ── 统计 ──
          _buildStats(),
          const Divider(height: 1),
          // ── 日志列表 ──
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          // 文件选择器
          Row(
            children: [
              const Text('日期: ', style: TextStyle(fontSize: 13)),
              Expanded(
                child: _logFiles.isEmpty
                    ? Text('无日志文件', style: TextStyle(color: Colors.grey.shade500, fontSize: 13))
                    : DropdownButton<String>(
                        value: _selectedFile,
                        isExpanded: true,
                        underline: const SizedBox(),
                        style: const TextStyle(fontSize: 13, color: Colors.black87),
                        items: _logFiles.map((f) {
                          final date = f.replaceFirst('farm_', '').replaceFirst('.jsonl', '');
                          return DropdownMenuItem(value: f, child: Text(date, style: const TextStyle(fontSize: 13)));
                        }).toList(),
                        onChanged: (v) {
                          if (v != null) { _selectedFile = v; _loadFile(); }
                        },
                      ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 筛选条件
          Row(
            children: [
              SizedBox(
                width: 120,
                height: 32,
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'SN 筛选', isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => setState(() { _filterSn = v; _displayCount = _pageSize; }),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 80,
                child: DropdownButtonFormField<String>(
                  value: _filterDir.isEmpty ? null : _filterDir,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4), border: OutlineInputBorder()),
                  style: const TextStyle(fontSize: 12),
                  hint: const Text('方向', style: TextStyle(fontSize: 12)),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'in', child: Text('📥 收', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'out', child: Text('📤 发', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() { _filterDir = v ?? ''; _displayCount = _pageSize; }),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 110,
                child: DropdownButtonFormField<String>(
                  value: _filterCat.isEmpty ? null : _filterCat,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4), border: OutlineInputBorder()),
                  style: const TextStyle(fontSize: 12),
                  hint: const Text('类别', style: TextStyle(fontSize: 12)),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'command_sent', child: Text('命令', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'command_response', child: Text('响应', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'status_received', child: Text('状态', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'notification_received', child: Text('通知', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() { _filterCat = v ?? ''; _displayCount = _pageSize; }),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '搜索...', isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (v) => setState(() { _searchText = v; _displayCount = _pageSize; }),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStats() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text('共 ${_entries.length} 条 ', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          if (_filterSn.isNotEmpty || _filterDir.isNotEmpty || _filterCat.isNotEmpty || _searchText.isNotEmpty)
            Text('筛选出 $_totalFiltered 条 ', style: TextStyle(fontSize: 11, color: Colors.blue.shade700)),
          Text('显示 $_displayCount 条', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          const Spacer(),
          InkWell(
            onTap: () { _filterSn = ''; _filterDir = ''; _filterCat = ''; _searchText = ''; _displayCount = _pageSize; setState(() {}); },
            child: Text('清除筛选', style: TextStyle(fontSize: 11, color: Colors.blue.shade600)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Colors.grey.shade500)),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: () { _scanFiles(); if (_selectedFile != null) _loadFile(); }, child: const Text('重试')),
        ],
      ));
    }

    if (_logFiles.isEmpty) {
      return Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 8),
          Text('还没有日志文件', style: TextStyle(color: Colors.grey.shade500)),
          const SizedBox(height: 4),
          Text(_logDir.path, style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
        ],
      ));
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final display = _filteredEntries.take(_displayCount).toList();

    return RefreshIndicator(
      onRefresh: _loadFile,
      child: ListView.separated(
        controller: _scrollController,
        itemCount: display.length + (_displayCount < _totalFiltered ? 1 : 0),
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 4, endIndent: 4),
        itemBuilder: (context, index) {
          if (index >= display.length) {
            return const Center(child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ));
          }
          return _buildLogEntry(display[index]);
        },
      ),
    );
  }

  Widget _buildLogEntry(Map<String, dynamic> entry) {
    final dir = entry['dir'] as String? ?? '?';
    final cat = entry['cat'] as String? ?? '?';
    final ts = entry['ts'] as String? ?? '';
    final sn = entry['sn'] as String? ?? '?';
    final method = entry['method'] as String?;

    // 颜色 + 图标
    Color? color;
    IconData icon;
    String catLabel;

    switch (cat) {
      case 'command_sent':
        color = Colors.blue.shade50;
        icon = Icons.upload;
        catLabel = '发送';
        break;
      case 'command_response':
        color = Colors.green.shade50;
        icon = Icons.download;
        catLabel = '响应';
        break;
      case 'status_received':
        color = null;
        icon = Icons.sensors;
        catLabel = '状态';
        break;
      case 'notification_received':
        color = Colors.orange.shade50;
        icon = Icons.notifications;
        catLabel = '通知';
        break;
      default:
        color = null;
        icon = Icons.help_outline;
        catLabel = cat;
    }

    final isOut = dir == 'out';

    // 摘要（不同类型不同字段）
    String summary = '';
    if (cat == 'command_sent') {
      summary = method ?? '';
      final params = entry['params'] as String?;
      if (params != null && params != '{}') summary += ' $params';
    } else if (cat == 'status_received') {
      summary = entry['summary'] as String? ?? '';
    } else if (cat == 'command_response') {
      summary = entry['has_error'] == true ? '❌ 错误' : '✅ 成功';
      final id = entry['id'];
      if (id != null) summary += ' id=$id';
    } else if (cat == 'notification_received') {
      summary = entry['event']?.toString() ?? '';
    }

    return Container(
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 时间
          SizedBox(
            width: 80,
            child: Text(
              ts.length >= 19 ? ts.substring(11, 19) : ts,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontFamily: 'monospace'),
            ),
          ),
          // 方向图标
          Icon(isOut ? Icons.arrow_upward : Icons.arrow_downward, size: 12,
              color: isOut ? Colors.blue : Colors.green),
          const SizedBox(width: 2),
          // 类别
          Icon(icon, size: 14, color: Colors.grey.shade700),
          const SizedBox(width: 4),
          // SN
          SizedBox(
            width: 120,
            child: Text(sn, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 4),
          // 摘要
          Expanded(
            child: Text(summary, style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis, maxLines: 1),
          ),
        ],
      ),
    );
  }
}
