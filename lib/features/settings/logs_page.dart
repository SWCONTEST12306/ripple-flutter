import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'diagnostic_log.dart';

/// 全屏日志页：查看模型请求的提示词、参数和模型返回结果。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  late final AppLifecycleListener _lifecycle;
  final _expanded = <int>{};
  List<DiagnosticLogEntry>? _entries;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    try {
      final entries = await DiagnosticLog.read();
      if (!mounted) return;
      final firstLoad = _entries == null;
      setState(() {
        _entries = entries;
        if (firstLoad && entries.isNotEmpty) _expanded.add(entries.last.seq);
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _supported ? '日志读取失败，请重试。' : '日志只在 Android 版可用。';
      });
    } finally {
      _busy = false;
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('清空后无法恢复，不影响已保存的行程。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _busy = true;
    try {
      await DiagnosticLog.clear();
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _expanded.clear();
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清空日志失败，请重试。')));
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _copy(DiagnosticLogEntry entry) async {
    await Clipboard.setData(
      ClipboardData(
        text: '${_stamp(entry.localTime)} ${entry.tag} ${entry.title}\n${entry.body}',
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制这条日志')));
  }

  String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '清空日志',
            onPressed: _busy || (_entries?.isEmpty ?? true) ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(child: _body(theme)),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: '正在读取日志'),
      );
    }
    if (_error case final error?) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Card.filled(
            child: ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(error),
              trailing: TextButton(
                onPressed: _load,
                child: const Text('重试'),
              ),
            ),
          ),
        ],
      );
    }
    final entries = _entries ?? const <DiagnosticLogEntry>[];
    if (entries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [
          SizedBox(height: 24),
          Center(
            child: Text(
              '还没有日志。\n读取到通知并调用模型后，这里会记录提示词和返回结果。',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Text(
            '本机保存最近 ${entries.length} 条，重启后仍可查看。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[entries.length - index - 1];
                return _entryCard(theme, entry);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _entryCard(ThemeData theme, DiagnosticLogEntry entry) {
    final expanded = _expanded.contains(entry.seq);
    final accent = entry.tag == '模型请求'
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    return Card.filled(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(entry.seq);
              } else {
                _expanded.add(entry.seq);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_stamp(entry.localTime)} · ${entry.tag}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '复制这条日志',
                    onPressed: () => _copy(entry),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                entry.body,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
