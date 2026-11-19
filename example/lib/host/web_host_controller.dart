import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

import '../config/app_config.dart';
import 'bridge/bridge_registry.dart';
import 'bridge/demo_channels.dart';
import 'bridge/js_channel_adapter.dart';
import 'events/host_event_bus.dart';
import 'web_view_port.dart';
import 'webview_tweaks.dart';

class WebHostController extends ChangeNotifier {
  WebHostController({
    required VoidCallback onClosePage,
    required void Function(String) onToast,
    Future<void> Function(String, String)? onShowNativeModal,
    PaymentHandler? onPayment,
  }) {
    registerDemoChannels(
      registry: _registry,
      onClosePage: onClosePage,
      onToast: onToast,
      onShowNativeModal: onShowNativeModal,
      onPayment: onPayment,
    );
    bridge = JsChannelAdapter(_registry);
  }

  final _registry = BridgeRegistry();
  late final JsChannelAdapter bridge;
  WebViewPort? _port;
  bool _disposed = false;
  int _documentGeneration = 0;
  String url = '';
  bool isLoading = true;
  int progress = 0;
  bool bridgeInjectionFailed = false;
  bool loadFailed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initUrl(String initialUrl) async {
    if (_disposed) return;
    url = initialUrl;
    _notify();
  }

  static String buildMergedUserAgent(String? authUserAgent) {
    final platformUa = Platform.isIOS
        ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
        : 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
    return '$platformUa ${AppConfig.hostAppId} ${authUserAgent ?? ''}';
  }

  void attachWebView(WebViewPort port) {
    if (!_disposed) _port = port;
  }

  void detachWebView(WebViewPort port) {
    if (identical(_port, port)) {
      _port = null;
      _documentGeneration++;
    }
  }

  Future<void> handleMessage(Object? message) async {
    final port = _port;
    final generation = _documentGeneration;
    if (_disposed || port == null) return;
    await bridge.handleMessage(port, message,
        isActive: () =>
            !_disposed &&
            identical(_port, port) &&
            generation == _documentGeneration);
  }

  void onLoadStart(String nextUrl) {
    if (_disposed) return;
    _documentGeneration++;
    isLoading = true;
    progress = 0;
    loadFailed = false;
    bridgeInjectionFailed = false;
    url = nextUrl;
    _notify();
  }

  Future<void> onLoadStop(String nextUrl) async {
    final port = _port;
    final generation = _documentGeneration;
    if (_disposed || port == null) return;
    await WebViewTweaks.injectDisableSelection(port);
    if (_disposed || generation != _documentGeneration) return;
    final ok = await bridge.injectBridge(port);
    if (_disposed || generation != _documentGeneration) return;
    isLoading = false;
    bridgeInjectionFailed = !ok;
    _notify();
  }

  void onProgress(int value) {
    if (_disposed) return;
    progress = value;
    if (value >= 100) isLoading = false;
    _notify();
  }

  void onMainFrameError() {
    if (_disposed) return;
    isLoading = false;
    loadFailed = true;
    _notify();
  }

  Future<void> retryBridge() => onLoadStop(url);

  Future<void> emitEvent(String type, Map<String, dynamic> data) async {
    final port = _port;
    if (_disposed || port == null) return;
    await HostEventBus.emit(port, type, data);
  }

  Future<bool> tryGoBack() async {
    final port = _port;
    if (_disposed || port == null) return false;
    return WebNavigationNegotiator.tryGoBack(
      runJavaScriptReturningResult: port.evaluateJavaScript,
      canGoBackFallback: () async => !_disposed && await port.canGoBack(),
      goBackFallback: () async {
        if (!_disposed) await port.goBack();
      },
    );
  }

  DateTime? _lastEnsureAliveTime;
  Future<void> ensureAlive() async {
    final port = _port;
    if (_disposed || port == null) return;
    final now = DateTime.now();
    if (_lastEnsureAliveTime != null &&
        now.difference(_lastEnsureAliveTime!) < const Duration(seconds: 5)) {
      return;
    }
    _lastEnsureAliveTime = now;
    if (loadFailed || bridgeInjectionFailed) {
      await reload();
      return;
    }
    try {
      final result = await port
          .evaluateJavaScript(
            'document.body ? document.body.innerHTML.length : 0',
          )
          .timeout(const Duration(seconds: 2));
      if (!_disposed && (int.tryParse(result.toString()) ?? 0) == 0) {
        await reload();
      }
    } catch (_) {
      if (!_disposed) await reload();
    }
  }

  Future<void> reload() async {
    if (!_disposed && url.isNotEmpty) await _port?.loadUrl(url);
  }

  @override
  void dispose() {
    _disposed = true;
    _port = null;
    _registry.clear();
    super.dispose();
  }
}
