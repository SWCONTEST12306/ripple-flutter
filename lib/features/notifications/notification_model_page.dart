import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'notification_inbox.dart';
import 'notification_model.dart';

class NotificationModelPage extends StatefulWidget {
  const NotificationModelPage({super.key});

  @override
  State<NotificationModelPage> createState() => _NotificationModelPageState();
}

class _NotificationModelPageState extends State<NotificationModelPage> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController(text: NotificationModel.defaultUrl);
  final _model = TextEditingController(text: NotificationModel.defaultModel);
  final _credential = TextEditingController();
  final _selected = <String, String>{};
  Map<String, String> _available = {};
  late final StreamSubscription<dynamic> _changes;
  late final AppLifecycleListener _lifecycle;
  NotificationModel? _saved;
  bool _loading = true;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _changes = NotificationInbox.changes.listen((_) => _refreshSources());
    _lifecycle = AppLifecycleListener(onResume: _refreshSources);
    _load();
    _refreshSources();
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _credential.dispose();
    _changes.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final saved = await NotificationModel.read();
      if (!mounted) return;
      _saved = saved;
      if (saved != null) {
        _url.text = saved.baseUrl.toString();
        _model.text = saved.model;
        _selected.addAll(saved.sources);
      }
    } catch (_) {
      if (mounted) _error = '读取模型配置失败，可重新填写密钥后保存。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshSources() async {
    try {
      final inbox = await NotificationInbox.read();
      if (!mounted) return;
      setState(
        () => _available = {
          for (final notice in inbox.entries.reversed)
            if (notice.packageName.isNotEmpty)
              notice.packageName: notice.source,
        },
      );
    } catch (_) {
      // Stored source selections remain available when the inbox is unavailable.
    }
  }

  Future<void> _change(Future<void> Function() operation) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await operation();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is PlatformException && error.code == 'credential_required'
              ? '请填写模型服务的 API 密钥。'
              : '模型配置写入失败，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final config = NotificationModel(
      NotificationModel.parseUrl(_url.text)!,
      _model.text.trim(),
      sources: Map.of(_selected),
    );
    final credential = _credential.text.trim();
    _change(() => config.save(credential.isEmpty ? null : credential));
  }

  String? _validateCredential(String? value) {
    final credential = value?.trim() ?? '';
    if (credential.isEmpty &&
        NotificationModel.parseUrl(_url.text) != _saved?.baseUrl) {
      return '请输入该服务的 API 密钥';
    }
    if (RegExp(r'[^\x21-\x7e]').hasMatch(credential) ||
        credential.length > 2048) {
      return '请检查 API 密钥格式';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: Scaffold(
      appBar: AppBar(title: const Text('AI 模型设置')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Form(
                    key: _form,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text('手机联网后可直接调用模型服务。API 密钥加密保存在本机。'),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _url,
                          enabled: !_working,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: '模型服务地址',
                          ),
                          validator: (value) =>
                              NotificationModel.parseUrl(value ?? '') == null
                              ? '请输入有效的 HTTPS 地址'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _model,
                          enabled: !_working,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: '模型名称',
                            helperText: '使用支持 JSON 输出的 Chat Completions 模型。',
                            helperMaxLines: 2,
                          ),
                          validator: (value) =>
                              value == null ||
                                  value.trim().isEmpty ||
                                  value.length > 200
                              ? '请输入有效的模型名称'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _credential,
                          enabled: !_working,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'API 密钥',
                            helperText: _saved == null
                                ? null
                                : '地址相同时，留空可保留已保存的密钥。',
                            helperMaxLines: 2,
                          ),
                          validator: _validateCredential,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '自动提取来源',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text('选中的应用发来新通知时，涟漪会将通知内容发送到上方模型服务。'),
                        if (_available.isEmpty && _selected.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('开启通知读取权限并收到通知后，可在这里选择应用。'),
                          ),
                        for (final source in {
                          ..._selected,
                          ..._available,
                        }.entries)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(source.value),
                            subtitle: source.key == source.value
                                ? null
                                : Text(source.key),
                            value: _selected.containsKey(source.key),
                            onChanged: _working
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected[source.key] = source.value;
                                    } else {
                                      _selected.remove(source.key);
                                    }
                                  }),
                          ),
                        if (_error case final error?) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              error,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _working ? null : _save,
                          child: Text(_working ? '正在保存…' : '保存模型配置'),
                        ),
                        if (_saved != null)
                          TextButton(
                            onPressed: _working
                                ? null
                                : () => _change(NotificationModel.remove),
                            child: const Text('移除模型配置'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    ),
  );
}
