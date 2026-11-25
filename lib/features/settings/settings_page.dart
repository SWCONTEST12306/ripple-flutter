import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../notifications/notification_inbox.dart';
import '../notifications/notification_inbox_page.dart';
import '../notifications/notification_model.dart';
import '../notifications/notification_model_page.dart';
import '../notifications/notification_sources.dart';
import 'debug_settings.dart';
import 'logs_page.dart';
import 'notification_sources_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.onViewPlan});

  final ValueChanged<DateTime> onViewPlan;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<dynamic> _changes;
  NotificationSources? _sources;
  NotificationInbox? _inbox;
  NotificationModel? _model;
  bool _blockApi = false;
  bool _savingDebug = false;
  int _debugVersion = 0;
  int _version = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    _changes = NotificationInbox.changes.listen(
      (_) => _load(),
      onError: (Object _) => _load(),
    );
    _load();
  }

  @override
  void dispose() {
    _changes.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final version = ++_version;
    final debugVersion = _debugVersion;
    try {
      final sources = await NotificationSources.read();
      final inbox = await NotificationInbox.read();
      final model = await _readModel();
      final blockApi = await _readDebugBlockApi();
      if (!mounted || version != _version) return;
      setState(() {
        _sources = sources;
        _inbox = inbox;
        _model = model;
        if (debugVersion == _debugVersion) _blockApi = blockApi;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || version != _version) return;
      setState(() {
        _loading = false;
        _error = '设置读取失败，请重试。';
      });
    }
  }

  Future<NotificationModel?> _readModel() async {
    try {
      return await NotificationModel.read();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _readDebugBlockApi() async {
    try {
      return await DebugSettings.readBlockApi();
    } catch (_) {
      return false;
    }
  }

  Future<void> _setBlockApi(bool value) async {
    if (_savingDebug) return;
    final previous = _blockApi;
    setState(() {
      _blockApi = value;
      _savingDebug = true;
      _debugVersion++;
    });
    try {
      await DebugSettings.saveBlockApi(value);
      if (!mounted) return;
      if (value) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.bug_report_outlined),
            title: const Text('调试功能已开启'),
            content: const Text(
              '从现在起，通知解析和图片识别只会生成包含提示词和参数的本地日志，'
              '不再发送模型请求，避免消耗 token。'
              '已排队但尚未发送的请求也会被拦下；'
              '关闭开关后，新收到的通知和新发起的图片识别恢复发送，已拦下的记录不会自动补发。',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _blockApi = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('调试设置保存失败，请重试。')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingDebug = false);
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => page));
    if (mounted) _load();
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

  String get _appsSummary {
    final sources = _sources;
    if (sources == null) return '读取设置不可用';
    if (_inbox?.authorized != true) return '通知读取权限未开启';
    if (!sources.master) return '已关闭';
    if (sources.apps.isEmpty) return '未选择应用';
    return '已开启 ${sources.apps.length} 个应用';
  }

  String get _modelSummary {
    final model = _model;
    if (model == null) return '未配置，填写服务地址和 API 密钥';
    return '${model.model} · ${model.baseUrl.host}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: '正在读取设置'),
      );
    }
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            key: const PageStorageKey('settings'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              if (_error case final error?) ...[
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
                const SizedBox(height: 8),
              ],
              if (_inbox?.authorized != true) ...[
                Card.filled(
                  child: ListTile(
                    leading: const Icon(Icons.notifications_off_outlined),
                    title: const Text('通知读取权限未开启'),
                    subtitle: const Text('开启后，涟漪才能读取应用通知并自动解析。'),
                    trailing: TextButton(
                      onPressed: _openSystemSettings,
                      child: const Text('去开启'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              _section(theme, '通知'),
              Card.filled(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.apps),
                      title: const Text('允许读取通知的应用'),
                      subtitle: Text(_appsSummary),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _push(const NotificationSourcesPage()),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('查看最近通知'),
                      subtitle: Text(
                        '最近 7 天 · ${_inbox?.entries.length ?? 0} 条',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _push(
                        NotificationInboxPage(onViewPlan: widget.onViewPlan),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.verified_user_outlined),
                      title: const Text('系统通知读取权限'),
                      subtitle: Text(
                        _inbox?.authorized == true ? '已开启' : '未开启',
                      ),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: _openSystemSettings,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _section(theme, 'AI 解析'),
              Card.filled(
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('AI 模型设置'),
                  subtitle: Text(_modelSummary),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(const NotificationModelPage()),
                ),
              ),
              const SizedBox(height: 16),
              _section(theme, '开发'),
              Card.filled(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      secondary: Icon(
                        _blockApi ? Icons.block : Icons.send_outlined,
                      ),
                      title: const Text('阻断 API 发送'),
                      subtitle: Text(
                        _blockApi
                            ? '已开启：只生成请求日志，不发送模型请求'
                            : '开启后只记录提示词和参数，不发送模型请求',
                      ),
                      value: _blockApi,
                      onChanged: _savingDebug ? null : _setBlockApi,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: const Text('日志'),
                      subtitle: const Text('模型请求的提示词、参数和返回结果，只保存在本机'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _push(const LogsPage()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
    ),
  );
}
