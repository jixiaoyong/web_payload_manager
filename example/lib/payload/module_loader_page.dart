import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

import '../app_restart.dart';
import '../config/app_config.dart';
import '../host/web_view_port.dart';
import '../host/web_host_controller.dart';
import '../host/web_host_widget.dart';
import 'module_runtime_detail.dart';
import 'payload_module_controller.dart';
import 'status_presentation.dart';

/// 资源状态面板：展示远程检测、自动下载、离线兜底与统一本地服务消费能力。
class ModuleLoaderPage extends StatefulWidget {
  const ModuleLoaderPage({
    super.key,
    this.controllerFactory,
    this.autoResolveOnStart = true,
  });

  final PayloadModuleController Function(String moduleKey)? controllerFactory;

  /// 进入页面后是否自动解析默认模块的本地 URL。
  final bool autoResolveOnStart;

  @override
  State<ModuleLoaderPage> createState() => _ModuleLoaderPageState();
}

class _ModuleLoaderPageState extends State<ModuleLoaderPage> {
  final TextEditingController _updateUrlController = TextEditingController(
    text: AppConfig.defaultUpdateUrl,
  );

  PayloadModuleController? _controller;
  String _selectedModuleKey = AppConfig.defaultModuleKey;
  WebViewEngine _selectedEngine = WebViewEngine.inAppWebView;
  String _effectiveUpdateUrl = AppConfig.defaultUpdateUrl;

  VersionJsonBean? _defaultVersionInfo;
  VersionJsonBean? _activeVersionInfo;
  WebVersionInfoBean? _remoteVersionInfo;
  String _activeSource = 'default';
  String? _remoteVersionError;
  PayloadSyncState _payloadSyncState = const PayloadSyncState.idle();
  StreamSubscription<PayloadSyncState>? _payloadSyncSubscription;
  bool _isVersionActionBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    unawaited(_payloadSyncSubscription?.cancel());
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _updateUrlController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(AppConfig.cachedUpdateUrlKey);
    final nextUrl = cached?.trim();
    if (nextUrl != null && nextUrl.isNotEmpty) {
      _updateUrlController.text = nextUrl;
      _effectiveUpdateUrl = nextUrl;
    }
    _listenPayloadSyncState();
    if (widget.autoResolveOnStart) {
      await _resolveModuleUrl(_selectedModuleKey);
    }
    unawaited(_refreshVersionInfo());
    unawaited(_refreshRemoteVersionInfo());
    if (mounted) {
      setState(() {});
    }
  }

  void _listenPayloadSyncState() {
    try {
      final manager = WebPayloadManager.getInstance();
      _payloadSyncState = manager.payloadSyncState;
      _payloadSyncSubscription?.cancel();
      _payloadSyncSubscription = manager.payloadSyncStateStream.listen(
        (next) {
          if (!mounted) {
            return;
          }
          setState(() => _payloadSyncState = next);
          if (next is SyncCompleted || next is SyncUpToDate) {
            unawaited(_refreshVersionInfo());
          }
        },
      );
    } catch (_) {
      // 测试环境或未初始化时可忽略。
    }
  }

  Future<void> _checkRemoteVersion() async {
    if (_isVersionActionBusy) {
      return;
    }
    setState(() => _isVersionActionBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _refreshVersionInfo();
      await _refreshRemoteVersionInfo();
      if (!mounted) {
        return;
      }
      final active = _activeVersionInfo?.effectiveVersionStr;
      final remote = _remoteVersionInfo?.effectiveVersionStr;
      final updateUrl = _effectiveUpdateUrl.trim();
      final isConfigured = AppConfig.isRemoteUpdateConfigured(updateUrl);
      final hasUpdate = VersionComparator.needsUpdate(
        localVersion: active,
        remoteVersion: remote,
      );
      final String message;
      if (!isConfigured) {
        message = '当前为默认占位地址（未配置有效远程服务）。请先修改为实际更新地址或本地 Mock 地址后再检查。';
      } else if (_remoteVersionError != null) {
        message = '远程版本检查失败：$_remoteVersionError';
      } else if (active != null && remote != null) {
        message = hasUpdate ? '发现新版本 $remote（当前 $active）' : '已是最新版本 $active';
      } else {
        message = '远程版本检查完成，当前无可用新版本';
      }
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() => _isVersionActionBusy = false);
      }
    }
  }

  Future<void> _syncPayloadNow() async {
    if (_isVersionActionBusy) {
      return;
    }
    setState(() => _isVersionActionBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await WebPayloadManager.getInstance().reLoad();
      await _refreshVersionInfo();
      await _refreshRemoteVersionInfo();
      await _resolveModuleUrl(_selectedModuleKey);
      if (!mounted) {
        return;
      }
      final message = switch (_payloadSyncState) {
        SyncCompleted() => '资源包已同步',
        SyncUpToDate() => '本地已是最新，无需下载',
        SyncFailed(:final message) => '同步失败：$message',
        SyncDownloading() => '同步进行中，请稍候',
        _ => '同步流程已结束',
      };
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('同步失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isVersionActionBusy = false);
      }
    }
  }

  /// 向插件查询 moduleKey 对应的本地服务 URL（registerModuleRoot + entryHtml）。
  Future<void> _resolveModuleUrl(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    final next = widget.controllerFactory?.call(trimmed) ??
        PayloadModuleController(trimmed);
    next.addListener(_onControllerChanged);
    setState(() {
      _controller = next;
      _selectedModuleKey = trimmed;
    });
    await next.start();
  }

  Future<void> _saveUpdateUrl() async {
    final nextUrl = _updateUrlController.text.trim();
    if (nextUrl.isEmpty) {
      return;
    }
    if (nextUrl == _effectiveUpdateUrl) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址未变更')),
      );
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfig.cachedUpdateUrlKey, nextUrl);
      if (!mounted) {
        return;
      }
      final shouldRestart = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('需要重启 App'),
          content: Text(
            '更新地址已保存：\n$nextUrl\n\n需重启后才会使用新地址检查更新。是否立即重启？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('立即重启'),
            ),
          ],
        ),
      );
      if (!mounted || shouldRestart != true) {
        return;
      }
      final restart = AppRestartScope.maybeOf(context);
      if (restart == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法重启，请手动关闭并重新打开 App')),
        );
        return;
      }
      await restart();
      if (!mounted) {
        return;
      }
      setState(() => _effectiveUpdateUrl = nextUrl);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('App 已重启，新地址已生效')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
  }

  Future<void> _refreshVersionInfo() async {
    try {
      final currentInfo =
          await FilePathUtility.getLocalVersionInfo(dirType: 'current');
      final defaultInfo =
          await FilePathUtility.getLocalVersionInfo(dirType: 'default');

      VersionJsonBean? activeInfo;
      String activeSource = 'default';
      if (currentInfo != null && defaultInfo != null) {
        final defaultIsNewer = VersionComparator.needsUpdate(
          localVersion: currentInfo.effectiveVersionStr,
          remoteVersion: defaultInfo.effectiveVersionStr,
        );
        if (defaultIsNewer) {
          activeInfo = defaultInfo;
          activeSource = 'default';
        } else {
          activeInfo = currentInfo;
          activeSource = 'current';
        }
      } else if (currentInfo != null) {
        activeInfo = currentInfo;
        activeSource = 'current';
      } else {
        activeInfo = defaultInfo;
        activeSource = 'default';
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _defaultVersionInfo = defaultInfo;
        _activeVersionInfo = activeInfo;
        _activeSource = activeSource;
      });
    } catch (_) {
      // 测试环境或未初始化时可忽略。
    }
  }

  Future<void> _refreshRemoteVersionInfo() async {
    final updateUrl = _effectiveUpdateUrl.trim();
    if (!AppConfig.isRemoteUpdateConfigured(updateUrl)) {
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteVersionInfo = null;
        _remoteVersionError = null;
      });
      return;
    }

    try {
      final remote =
          await VersionCheckService(updateUrl: updateUrl).getLatestModule();
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteVersionInfo = remote;
        _remoteVersionError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteVersionInfo = null;
        _remoteVersionError = error.toString();
      });
    }
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller?.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Web 资源更新面板'),
        actions: [
          IconButton(
            tooltip: '查看能力说明',
            onPressed: () => _showCapabilityInfo(context),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _buildUpdateUrlCard(),
          const SizedBox(height: 12),
          _buildVersionStatusCard(),
          const SizedBox(height: 12),
          _buildUsageCard(state),
        ],
      ),
    );
  }

  Widget _buildUpdateUrlCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '远程更新检测地址',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              '用于配置 App 去哪里检查远程最新版本与下载信息，不是网页加载地址。'
              '默认占位地址仅使用内置资源；联调 mock 服务时请填写开发机局域网地址（如 http://192.168.x.x:8080/check-update），'
              '保存后需重启 App 生效。',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _updateUrlController,
              decoration: const InputDecoration(
                labelText: '检查更新地址',
                hintText: 'http://192.168.x.x:8080/check-update',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _saveUpdateUrl(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.computer, size: 16),
                  label: const Text('填入本地 Mock (127.0.0.1:8080)'),
                  onPressed: () {
                    _updateUrlController.text =
                        'http://127.0.0.1:8080/version.json';
                  },
                ),
                ActionChip(
                  avatar: const Icon(Icons.refresh, size: 16),
                  label: const Text('恢复占位地址'),
                  onPressed: () {
                    _updateUrlController.text = AppConfig.defaultUpdateUrl;
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '当前生效：$_effectiveUpdateUrl',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                ElevatedButton(
                  onPressed: _saveUpdateUrl,
                  child: const Text('保存地址'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _isVersionActionBusy ? null : _checkRemoteVersion,
                    child: const Text('检查版本'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isVersionActionBusy ? null : _syncPayloadNow,
                    child: const Text('立即同步'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionStatusCard() {
    final activeVersion = _activeVersionInfo?.version;
    final remoteVersion = _remoteVersionInfo?.version;
    final needsUpdate = activeVersion != null && remoteVersion != null
        ? remoteVersion > activeVersion
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '版本状态',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            _buildVersionGroup(
              title: '内置资源（default）',
              version: _defaultVersionInfo?.version,
              buildLabel: _defaultVersionInfo?.buildLabel,
            ),
            const Divider(),
            _buildVersionGroup(
              title: '当前离线资源（active）',
              version: _activeVersionInfo?.version,
              buildLabel: _activeVersionInfo?.buildLabel,
              extra: '当前使用来源：$_activeSource',
            ),
            const Divider(),
            _buildVersionGroup(
              title: '远程最新资源',
              version: _remoteVersionInfo?.version,
              buildLabel: _remoteVersionInfo?.buildLabel,
              extra: !_isRemoteUpdateConfigured
                  ? '未配置远程地址（使用内置资源）'
                  : (_remoteVersionError == null
                      ? (needsUpdate == null
                          ? '是否可更新：待检测'
                          : (needsUpdate ? '是否可更新：是' : '是否可更新：否'))
                      : '获取失败：$_remoteVersionError（仍可使用内置/离线资源）'),
            ),
            const SizedBox(height: 12),
            _buildPayloadSyncStatus(),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionGroup({
    required String title,
    required int? version,
    required String? buildLabel,
    String? extra,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('版本：${version?.toString() ?? '—'}'),
        Text('构建时间：${buildLabel ?? '—'}'),
        if (extra != null) Text(extra),
      ],
    );
  }

  Widget _buildPayloadSyncStatus() {
    final presentation = StatusPresentation.forPayloadSync(
      state: _payloadSyncState,
      hasPendingRemoteUpdate: _hasPendingRemoteUpdate,
      activeVersion: _activeVersionInfo?.version,
      remoteVersion: _remoteVersionInfo?.version,
    );
    final progress = _payloadSyncState is SyncDownloading
        ? (_payloadSyncState as SyncDownloading).progress
        : null;
    final currentBytes = _payloadSyncState is SyncDownloading
        ? (_payloadSyncState as SyncDownloading).currentBytes
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '资源包同步',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '同步状态：${presentation.label}',
          style: TextStyle(
            color: presentation.color,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (progress != null) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 4),
          Text('下载进度：${(progress * 100).toStringAsFixed(0)}%'),
        ],
        if (currentBytes != null) Text('已下载：${_formatBytes(currentBytes)}'),
        if (_payloadSyncState is SyncDownloading) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _isVersionActionBusy ? null : _cancelPayloadDownload,
            child: const Text('取消下载'),
          ),
        ],
      ],
    );
  }

  Future<void> _cancelPayloadDownload() async {
    if (_isVersionActionBusy) {
      return;
    }
    setState(() => _isVersionActionBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await WebPayloadManager.getInstance().cancelAllDownloads();
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('已请求取消下载')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('取消失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isVersionActionBusy = false);
      }
    }
  }

  Widget _buildUsageCard(ResourceState? state) {
    final localUrl = state is Data ? state.data : '—';
    final authUserAgent = WebHostController.buildMergedUserAgent(
      _safeAuthUserAgent(),
    );
    final canOpen = state is Data;
    final selectedLabel = AppConfig.moduleOptions
        .firstWhere((option) => option.key == _selectedModuleKey)
        .label;
    final resolvePresentation = StatusPresentation.forResourceState(state);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '本地模块访问',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              '插件初始化后本地 HTTP 服务已就绪。选择模块会自动解析该 moduleKey 在 version.json 中对应的 entryHtml 本地 URL；'
              '下方「打开模块页面」即在 WebView 中加载该地址。',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _selectedModuleKey,
              decoration: const InputDecoration(
                labelText: '选择模块',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: AppConfig.moduleOptions
                  .map(
                    (option) => DropdownMenuItem<String>(
                      value: option.key,
                      child: Text(option.label),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                unawaited(_resolveModuleUrl(value));
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<WebViewEngine>(
              initialValue: _selectedEngine,
              decoration: const InputDecoration(
                  labelText: 'WebView 引擎',
                  border: OutlineInputBorder(),
                  isDense: true),
              items: WebViewEngine.values
                  .map((engine) => DropdownMenuItem(
                        value: engine,
                        child: Text(engine.label),
                      ))
                  .toList(),
              onChanged: (engine) {
                if (engine != null) setState(() => _selectedEngine = engine);
              },
            ),
            const SizedBox(height: 12),
            _InfoRow(label: '当前模块', value: selectedLabel),
            _InfoRow(label: '模块 Key', value: _selectedModuleKey),
            _InfoRow(
              label: '地址解析',
              value: resolvePresentation.label,
              valueColor: resolvePresentation.color,
            ),
            if (state is Loading && state.currentBytes != null)
              _InfoRow(
                label: '解析进度',
                value: _formatBytes(state.currentBytes!),
              ),
            _InfoRow(label: '本地服务地址', value: localUrl),
            _InfoRow(label: '鉴权 UA', value: authUserAgent),
            const SizedBox(height: 12),
            TextButton(
              onPressed: canOpen
                  ? () => _openMinimalWebView(
                        ModuleRuntimeDetail(
                          moduleKey: _selectedModuleKey,
                          moduleLabel: selectedLabel,
                          localUrl: localUrl,
                          authUserAgent: authUserAgent,
                          updateUrl: _effectiveUpdateUrl,
                          resolveStatusLabel: resolvePresentation.label,
                          activeVersion: _activeVersionInfo?.version,
                          activeBuildLabel: _activeVersionInfo?.buildLabel,
                          activeSource: _activeSource,
                          remoteVersion: _remoteVersionInfo?.version,
                          remoteBuildLabel: _remoteVersionInfo?.buildLabel,
                          payloadSyncStatusLabel:
                              StatusPresentation.forPayloadSync(
                            state: _payloadSyncState,
                            hasPendingRemoteUpdate: _hasPendingRemoteUpdate,
                            activeVersion: _activeVersionInfo?.version,
                            remoteVersion: _remoteVersionInfo?.version,
                          ).label,
                        ),
                      )
                  : null,
              child: const Text('打开模块页面'),
            ),
          ],
        ),
      ),
    );
  }

  bool get _isRemoteUpdateConfigured =>
      AppConfig.isRemoteUpdateConfigured(_effectiveUpdateUrl);

  bool get _hasPendingRemoteUpdate {
    if (_remoteVersionError != null) {
      return false;
    }
    final active = _activeVersionInfo?.version;
    final remote = _remoteVersionInfo?.version;
    return active != null && remote != null && remote > active;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String? _safeAuthUserAgent() {
    try {
      return WebPayloadManager.getInstance().getAuthUserAgent();
    } catch (_) {
      return null;
    }
  }

  Future<void> _openMinimalWebView(ModuleRuntimeDetail detail) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            MinimalWebViewPage(detail: detail, engine: _selectedEngine),
      ),
    );
  }

  void _showCapabilityInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('插件能力说明'),
        content: const Text(
          '当前示例重点展示：\n\n'
          '1. 自动检测远程更新（需配置真实 UPDATE_URL）\n'
          '2. 自动下载完整离线资源包，支持取消下载\n'
          '3. 远程失败或未配置时回退到 App 内置资源\n'
          '4. 对 App 统一暴露本地服务地址 + 鉴权 UA\n'
          '5. module_one 提供 JS Bridge 按钮演示（Echo / HostInfo / Toast）\n\n'
          '验证回退：停止 mock server 后仍可打开模块页面；'
          '「检查版本」失败时本地 URL 仍可用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final valueStyle = valueColor == null
        ? null
        : TextStyle(
            color: valueColor,
            fontWeight: FontWeight.w500,
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 2),
          SelectableText(
            value.isEmpty ? '—' : value,
            style: valueStyle,
          ),
        ],
      ),
    );
  }
}

class MinimalWebViewPage extends StatefulWidget {
  const MinimalWebViewPage({
    super.key,
    required this.detail,
    this.engine = WebViewEngine.inAppWebView,
  });

  final ModuleRuntimeDetail detail;
  final WebViewEngine engine;

  @override
  State<MinimalWebViewPage> createState() => _MinimalWebViewPageState();
}

class _MinimalWebViewPageState extends State<MinimalWebViewPage>
    with WidgetsBindingObserver {
  late final WebHostController _controller;
  bool _showInspector = true;
  StreamSubscription<ResourceState>? _moduleSubscription;
  String _authUserAgent = '';

  String? _safeAuthUserAgent() {
    try {
      return WebPayloadManager.getInstance().getAuthUserAgent();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _showExternalCashierDialog({
    required String payType,
    required String orderId,
    required String amount,
  }) async {
    final isWechat = payType == 'wechat';
    final themeColor =
        isWechat ? const Color(0xFF07C160) : const Color(0xFF1677FF);
    final appName = isWechat ? '微信支付' : '支付宝';
    final iconData = isWechat ? Icons.wechat : Icons.account_balance_wallet;

    return await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: EdgeInsets.zero,
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: themeColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(iconData, color: Colors.white, size: 24),
                const SizedBox(width: 8),
                Text(
                  '$appName (外部仿真收银台)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '【真实系统跳转仿真】\n此弹窗模拟拉起外部独立 App 收银台。请选择要向宿主 App 回传的支付结果：',
                style: TextStyle(fontSize: 13, color: Colors.black87),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('商户: 开源混合开发离线平台',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('订单号: $orderId',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(
                      '支付金额: ¥$amount',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: themeColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: themeColor),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('模拟支付成功'),
                  onPressed: () {
                    final timestamp = DateTime.now().millisecondsSinceEpoch;
                    Navigator.of(dialogCtx).pop({
                      'status': 'success',
                      'payType': payType,
                      'orderId': orderId,
                      'amount': amount,
                      'tradeNo': '${isWechat ? "wx" : "ali"}_$timestamp',
                      'transactionId': '${isWechat ? "wx" : "ali"}_$timestamp',
                      'resultStatus': '9000',
                      'errCode': 0,
                    });
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('模拟放弃付款 (用户主动取消)'),
                  onPressed: () {
                    Navigator.of(dialogCtx).pop({
                      'status': 'cancelled',
                      'payType': payType,
                      'orderId': orderId,
                      'resultStatus': '6001',
                      'errCode': -2,
                      'memo': '用户取消支付',
                    });
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  icon: const Icon(Icons.error_outline),
                  label: const Text('模拟系统故障 / 支付超时失败'),
                  onPressed: () {
                    Navigator.of(dialogCtx).pop({
                      'status': 'failed',
                      'payType': payType,
                      'orderId': orderId,
                      'resultStatus': '4000',
                      'errCode': -1,
                      'memo': '支付失败或网络超时',
                    });
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = WebHostController(
      onClosePage: () {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
      onToast: (message) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
      onShowNativeModal: (title, content) async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('我知道了'),
              ),
            ],
          ),
        );
      },
      onPayment: (payType, orderId, amount) async {
        if (!mounted) {
          return {'status': 'failed', 'message': 'Page unmounted'};
        }

        switch (payType) {
          case 'apple_pay':
            // 模式 1: Apple Pay (应用内原生半屏授权层，直接返回结果)
            final confirmed = await showModalBottomSheet<bool>(
              context: context,
              backgroundColor: Colors.white,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              builder: (ctx) => SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.apple, size: 28),
                          SizedBox(width: 8),
                          Text(
                            'Apple Pay 支付授权',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      ListTile(
                        title: const Text('收款方：开源混合开发离线平台'),
                        subtitle: Text('订单号: $orderId'),
                        trailing: Text(
                          '¥$amount',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('双击侧边按钮 / 确认支付'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );

            if (confirmed != true) {
              return {
                'status': 'cancelled',
                'payType': 'apple_pay',
                'orderId': orderId,
              };
            }

            final result = {
              'status': 'success',
              'payType': 'apple_pay',
              'orderId': orderId,
              'amount': amount,
              'transactionId': 'ap_${DateTime.now().millisecondsSinceEpoch}',
            };

            if (mounted) await _controller.emitEvent('PAY_RESULT', result);
            return result;

          case 'alipay':
            // 模式 2: 支付宝 (外部仿真收银台，MethodChannel 异步直回 + ensureAlive 探活)
            final aliResult = await _showExternalCashierDialog(
              payType: 'alipay',
              orderId: orderId,
              amount: amount,
            );
            await _controller.ensureAlive();
            return aliResult ??
                {
                  'status': 'cancelled',
                  'payType': 'alipay',
                  'orderId': orderId,
                  'resultStatus': '6001',
                  'memo': '用户取消',
                };

          case 'wechat':
            // 模式 3: 微信支付 (外部仿真收银台，Bridge 立即返回 launched，真正支付结果通过全局 Delegate 异步事件流派发)
            unawaited(
              _showExternalCashierDialog(
                payType: 'wechat',
                orderId: orderId,
                amount: amount,
              ).then((wxResult) async {
                await _controller.ensureAlive();
                if (mounted && wxResult != null) {
                  await Future<void>.delayed(const Duration(milliseconds: 300));
                  if (mounted) {
                    await _controller.emitEvent('PAY_RESULT', wxResult);
                  }
                }
              }),
            );

            return {
              'status': 'launched',
              'payType': 'wechat',
              'orderId': orderId,
              'message': '微信客户端已唤起，最终支付结果将通过异步事件派发',
            };

          default:
            return {'status': 'failed', 'message': '未知支付类型: $payType'};
        }
      },
    );
    _authUserAgent =
        WebHostController.buildMergedUserAgent(_safeAuthUserAgent());
    _controller.initUrl(widget.detail.localUrl);
    _moduleSubscription = WebPayloadManager.getInstance()
        .getModuleStateStream(widget.detail.moduleKey)
        .listen((state) async {
      if (!mounted || state is! Data) return;
      final nextUa =
          WebHostController.buildMergedUserAgent(_safeAuthUserAgent());
      final credentialChanged = nextUa != _authUserAgent;
      setState(() => _authUserAgent = nextUa);
      await _controller.initUrl(state.data);
      // 凭证变化时 key 会重建原生 WebView，确保首个请求已使用新 UA。
      if (!credentialChanged) await _controller.reload();
    });
  }

  Future<void> _ensureLocalServerAndPage() async {
    await WebPayloadManager.getInstance().ensureLocalWebServerHealthy();
    if (mounted) await _controller.ensureAlive();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_ensureLocalServerAndPage());
    }
  }

  void _showModuleDetail() {
    final detail = widget.detail;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.paddingOf(context).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '模块详情',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _DetailRow(label: '模块名称', value: detail.moduleLabel),
              _DetailRow(label: '模块 Key', value: detail.moduleKey),
              _DetailRow(label: '本地服务地址', value: detail.localUrl),
              _DetailRow(label: '鉴权 UA', value: detail.authUserAgent),
              _DetailRow(label: '地址解析', value: detail.resolveStatusLabel),
              _DetailRow(
                label: '离线资源版本',
                value: _formatVersion(
                  detail.activeVersion,
                  detail.activeBuildLabel,
                  detail.activeSource,
                ),
              ),
              _DetailRow(
                label: '远程最新版本',
                value: _formatVersion(
                  detail.remoteVersion,
                  detail.remoteBuildLabel,
                  null,
                ),
              ),
              _DetailRow(
                label: '资源包同步',
                value: detail.payloadSyncStatusLabel ?? '—',
              ),
              _DetailRow(label: '检查更新地址', value: detail.updateUrl),
            ],
          ),
        );
      },
    );
  }

  String _formatVersion(dynamic version, String? buildLabel, String? source) {
    if (version == null) {
      return '—';
    }
    final vStr = version.toString();
    if (vStr.isEmpty) return '—';
    final build = buildLabel?.trim();
    final suffix = <String>[
      if (build != null && build.isNotEmpty) build,
      if (source != null && source.isNotEmpty) '来源：$source',
    ].join(' · ');
    final prefix =
        vStr.startsWith('v') || vStr.startsWith('V') ? vStr : 'v$vStr';
    return suffix.isEmpty ? prefix : '$prefix（$suffix）';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_moduleSubscription?.cancel());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pushDemoEvent() async {
    await _controller.emitEvent('HOST_DEMO_EVENT', {
      'source': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已向 H5 推送 HOST_DEMO_EVENT')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final handled = await _controller.tryGoBack();
        if (!handled && context.mounted) {
          Navigator.of(context).pop(result);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  '${widget.detail.moduleLabel} · ${widget.detail.moduleKey}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  border: Border.all(color: Colors.orange.shade400),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Flutter Native',
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.orange.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: _showInspector ? '关闭透视视窗' : '开启透视视窗',
              onPressed: () => setState(() => _showInspector = !_showInspector),
              icon: Icon(
                _showInspector ? Icons.visibility : Icons.visibility_off,
                color: _showInspector ? Theme.of(context).primaryColor : null,
              ),
            ),
            IconButton(
              tooltip: '推送演示事件',
              onPressed: _pushDemoEvent,
              icon: const Icon(Icons.campaign_outlined),
            ),
            IconButton(
              tooltip: '重新加载',
              onPressed: _controller.reload,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '模块详情',
              onPressed: _showModuleDetail,
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        body: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final webViewChild = WebHostWidget(
              key: ValueKey(_authUserAgent),
              controller: _controller,
              userAgent: _authUserAgent,
              engine: widget.engine,
            );

            final content = _showInspector
                ? Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        color: const Color(0xFF1E293B),
                        child: Row(
                          children: [
                            const Icon(Icons.layers,
                                size: 14, color: Colors.cyanAccent),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'H5 离线容器视窗 · Localhost HTTP · 来源: ${widget.detail.activeSource ?? "default"}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: Colors.cyanAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'H5 Web View',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.cyanAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Colors.blue.shade300, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.06),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: webViewChild,
                        ),
                      ),
                    ],
                  )
                : webViewChild;

            return Stack(
              children: [
                content,
                if (_controller.isLoading)
                  _LoadingHudOverlay(
                    progress: _controller.progress,
                    moduleKey: widget.detail.moduleKey,
                  ),
                if (_controller.bridgeInjectionFailed)
                  _BridgeFailureOverlay(
                    onRetry: _controller.retryBridge,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BridgeFailureOverlay extends StatelessWidget {
  const _BridgeFailureOverlay({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Bridge 注入失败',
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white70),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          SelectableText(value.isEmpty ? '—' : value),
        ],
      ),
    );
  }
}

class _LoadingHudOverlay extends StatelessWidget {
  const _LoadingHudOverlay({
    required this.progress,
    required this.moduleKey,
  });

  final int progress;
  final String moduleKey;

  String _getStageText(int p) {
    if (p < 30) {
      return '正在初始化 Localhost 离线服务...';
    } else if (p < 75) {
      return '正在加载本地离线模块 ($moduleKey)...';
    } else {
      return '正在建立 JSBridge 双向安全通信...';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.white.withValues(alpha: 0.85),
          child: Center(
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: CircularProgressIndicator(
                        value: progress > 0 && progress < 100
                            ? progress / 100.0
                            : null,
                        strokeWidth: 3.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _getStageText(progress),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '已加载 $progress%',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
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
}
