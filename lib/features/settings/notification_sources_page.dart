import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../notifications/notification_inbox.dart';
import '../notifications/notification_sources.dart';

/// Mirrors the system notification settings: one switch for the whole feature
/// and one switch per application.
class NotificationSourcesPage extends StatefulWidget {
  const NotificationSourcesPage({super.key});

  @override
  State<NotificationSourcesPage> createState() =>
      _NotificationSourcesPageState();
}

class _NotificationSourcesPageState extends State<NotificationSourcesPage> {
  final _search = TextEditingController();
  final _icons = <String, Future<Uint8List?>>{};
  late final AppLifecycleListener _lifecycle;
  List<InstalledApp> _apps = const [];
  NotificationSources? _sources;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sources = await NotificationSources.read();
      final installed = await NotificationSources.installedApps();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _apps = _merge(installed, sources.apps);
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '读取应用列表失败，请重试。');
    }
  }

  /// Keeps applications that are no longer launchable but were selected before.
  List<InstalledApp> _merge(List<InstalledApp> installed, Map<String, String> selected) {
    final apps = [...installed];
    final known = {for (final app in installed) app.packageName};
    for (final entry in selected.entries) {
      if (known.add(entry.key)) apps.add(InstalledApp(entry.key, entry.value));
    }
    return apps;
  }

  Future<void> _apply({bool? master, Map<String, String>? apps}) async {
    final current = _sources;
    if (current == null || _busy) return;
    final next = NotificationSources(
      master ?? current.master,
      apps ?? current.apps,
      authorized: current.authorized,
    );
    setState(() {
      _sources = next;
      _busy = true;
    });
    try {
      await next.save();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sources = current;
        _error = '保存失败，请重试。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(InstalledApp app, bool enabled) {
    final current = _sources;
    if (current == null) return;
    final apps = Map<String, String>.of(current.apps);
    if (enabled) {
      apps[app.packageName] = app.label;
    } else {
      apps.remove(app.packageName);
    }
    _apply(apps: apps);
  }

  Future<void> _openSystemSettings() async {
    try {
      await NotificationInbox.openSettings();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开系统的通知读取设置。')));
      }
    }
  }

  List<InstalledApp> get _visible {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _apps;
    return [
      for (final app in _apps)
        if (app.label.toLowerCase().contains(query) ||
            app.packageName.toLowerCase().contains(query))
          app,
    ];
  }

  Future<Uint8List?> _iconFor(String packageName) => _icons.putIfAbsent(
    packageName,
    () => NotificationSources.icon(packageName),
  );

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(title: const Text('允许读取通知')),
      body: SafeArea(
        child: sources == null
            ? _placeholder()
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        sliver: SliverToBoxAdapter(
                          child: _header(context, sources),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => _appTile(visible[index]),
                            childCount: visible.length,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _placeholder() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error == null) const CircularProgressIndicator(),
        if (_error case final error?) ...[
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      ],
    ),
  );

  Widget _header(BuildContext context, NotificationSources sources) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error case final error?) ...[
          Card.filled(
            child: ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(error),
              trailing: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (!sources.authorized) ...[
          Card.filled(
            child: ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('尚未开启系统通知读取权限'),
              subtitle: const Text('授权后，涟漪才能读取所选应用的通知。'),
              trailing: TextButton(
                onPressed: _openSystemSettings,
                child: const Text('去开启'),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Card.filled(
          child: SwitchListTile(
            title: const Text('允许读取应用通知'),
            subtitle: const Text('开启后，所选应用收到新通知会立即解析。'),
            value: sources.master,
            onChanged: _busy ? null : (value) => _apply(master: value),
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('应用', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text(
            '打开开关即可读取该应用的通知。列表来自手机中可打开的应用。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (_apps.length > 10)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: '搜索应用',
              ),
            ),
          ),
        if (_visible.isEmpty)
          const ListTile(
            leading: Icon(Icons.search_off),
            title: Text('没有可显示的应用'),
            subtitle: Text('换个名称搜索，或确认手机中已安装可打开的应用。'),
          ),
      ],
    );
  }

  Widget _appTile(InstalledApp app) {
    final enabled = _sources?.apps.containsKey(app.packageName) ?? false;
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      secondary: _AppIcon(label: app.label, icon: _iconFor(app.packageName)),
      title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        app.packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      value: enabled,
      onChanged: _busy ? null : (value) => _toggle(app, value),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.label, required this.icon});

  final String label;
  final Future<Uint8List?> icon;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: icon,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return CircleAvatar(
          child: Text(label.isEmpty ? '?' : label.substring(0, 1)),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, width: 40, height: 40, gaplessPlayback: true),
      );
    },
  );
}
