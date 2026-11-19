import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'web_payload_manager.dart';
import 'web_payload_models.dart';

/// 离线包模块状态感知与构建 Widget。
///
/// 自动订阅 [WebPayloadManager.getModuleStateStream]，承接 `Loading`、`Data` 与 `Error` 状态。
class WebPayloadBuilder extends StatefulWidget {
  /// 目标离线 H5 模块标识（对应 `version.json` 中 `modules[].key`）。
  final String moduleKey;

  /// 资源就绪时的页面构建回调，参数 `localUrl` 为本地不可变会话 HTTP 地址。
  final Widget Function(BuildContext context, String localUrl) builder;

  /// 自定义加载态构建器，缺省展示内置进度指示器。
  final Widget Function(
    BuildContext context,
    double? progress,
    int? currentBytes,
  )? loadingBuilder;

  /// 自定义错误态构建器，提供错误描述、严重级别与重试回调。
  final Widget Function(
    BuildContext context,
    String message,
    ErrorSeverity severity,
    VoidCallback onRetry,
  )? errorBuilder;

  /// 创建模块状态监听构建器。
  const WebPayloadBuilder({
    super.key,
    required this.moduleKey,
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
  });

  @override
  State<WebPayloadBuilder> createState() => _WebPayloadBuilderState();
}

class _WebPayloadBuilderState extends State<WebPayloadBuilder> {
  StreamSubscription<ResourceState>? _subscription;
  ResourceState _state = const ResourceState.loading();

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant WebPayloadBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.moduleKey != widget.moduleKey) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _state = const ResourceState.loading();
    try {
      _subscription = WebPayloadManager.getInstance()
          .getModuleStateStream(widget.moduleKey)
          .listen(
        (state) {
          if (mounted) setState(() => _state = state);
        },
        onError: (e) {
          if (mounted) {
            setState(() {
              _state = ResourceState.error(
                message: e.toString(),
                severity: ErrorSeverity.critical,
              );
            });
          }
        },
      );
    } catch (e) {
      _state = ResourceState.error(
        message: e.toString(),
        severity: ErrorSeverity.critical,
      );
    }
  }

  void _retry() {
    _subscription?.cancel();
    _subscribe();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return switch (_state) {
      Loading(:final progress, :final currentBytes) =>
        widget.loadingBuilder?.call(context, progress, currentBytes) ??
            _defaultLoading(progress, currentBytes),
      Data(:final data) => widget.builder(context, data),
      Error(:final message, :final severity) =>
        widget.errorBuilder?.call(context, message, severity, _retry) ??
            _defaultError(message, _retry),
    };
  }

  Widget _defaultLoading(double? progress, int? currentBytes) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(value: progress),
          const SizedBox(height: 16),
          Text(
            progress != null
                ? '正在加载模块 ${(progress * 100).toStringAsFixed(0)}%'
                : '正在准备离线资源...',
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _defaultError(String message, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              '模块加载失败: $message',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.black87),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
