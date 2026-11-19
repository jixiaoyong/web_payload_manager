import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webview_flutter/webview_flutter.dart' as web;
import 'package:webview_flutter_android/webview_flutter_android.dart'
    as android;
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart' as wk;

import 'bridge/js_channel_adapter.dart';
import 'web_host_controller.dart';
import 'web_view_port.dart';

class WebHostWidget extends StatelessWidget {
  const WebHostWidget(
      {super.key,
      required this.controller,
      required this.userAgent,
      this.engine = WebViewEngine.inAppWebView});
  final WebHostController controller;
  final String userAgent;
  final WebViewEngine engine;

  @override
  Widget build(BuildContext context) {
    if (controller.url.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (engine) {
      WebViewEngine.inAppWebView =>
        _InAppHost(controller: controller, userAgent: userAgent),
      WebViewEngine.webViewFlutter =>
        _FlutterHost(controller: controller, userAgent: userAgent),
    };
  }
}

Set<Factory<OneSequenceGestureRecognizer>> _gestures() => {
      Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
    };

class _InAppPort implements WebViewPort {
  _InAppPort(this.controller);
  final inapp.InAppWebViewController controller;
  @override
  Future<Object?> evaluateJavaScript(String script) =>
      controller.evaluateJavascript(source: script);
  @override
  Future<bool> canGoBack() => controller.canGoBack();
  @override
  Future<void> goBack() => controller.goBack();
  @override
  Future<void> loadUrl(String url) =>
      controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(url)));
}

class _InAppHost extends StatefulWidget {
  const _InAppHost({required this.controller, required this.userAgent});
  final WebHostController controller;
  final String userAgent;
  @override
  State<_InAppHost> createState() => _InAppHostState();
}

class _InAppHostState extends State<_InAppHost> {
  _InAppPort? _port;
  @override
  void dispose() {
    final port = _port;
    if (port != null) widget.controller.detachWebView(port);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => inapp.InAppWebView(
        initialSettings: inapp.InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent: widget.userAgent,
          supportZoom: false,
          builtInZoomControls: false,
          allowsInlineMediaPlayback: true,
          mediaPlaybackRequiresUserGesture: false,
          mixedContentMode: inapp.MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          allowsBackForwardNavigationGestures: false,
          isInspectable: kDebugMode,
          useHybridComposition: true,
        ),
        initialUrlRequest:
            inapp.URLRequest(url: inapp.WebUri(widget.controller.url)),
        initialUserScripts: UnmodifiableListView([
          inapp.UserScript(
            source: '''window.__payloadNativeSend = function(message) {
        window.flutter_inappwebview.callHandler('${JsChannelAdapter.transportName}', message);
      };\n${widget.controller.bridge.injectionScript(dispatchReady: false)}''',
            injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
          )
        ]),
        gestureRecognizers: _gestures(),
        onWebViewCreated: (controller) {
          if (!mounted) return;
          final port = _InAppPort(controller);
          _port = port;
          widget.controller.attachWebView(port);
          controller.addJavaScriptHandler(
              handlerName: JsChannelAdapter.transportName,
              callback: (args) async {
                if (mounted && args.isNotEmpty) {
                  await widget.controller.handleMessage(args.first);
                }
                return null;
              });
        },
        onLoadStart: (_, uri) {
          if (mounted) {
            widget.controller
                .onLoadStart(uri?.toString() ?? widget.controller.url);
          }
        },
        onLoadStop: (_, uri) async {
          if (mounted) {
            await widget.controller
                .onLoadStop(uri?.toString() ?? widget.controller.url);
          }
        },
        onProgressChanged: (_, value) {
          if (mounted) widget.controller.onProgress(value);
        },
        onReceivedError: (_, request, error) {
          if (mounted && request.isForMainFrame == true) {
            widget.controller.onMainFrameError();
          }
        },
        onWebContentProcessDidTerminate: (_) async {
          if (mounted) await widget.controller.reload();
        },
        onConsoleMessage: (_, message) =>
            debugPrint('[WebHost] ${message.message}'),
      );
}

class _FlutterPort implements WebViewPort {
  _FlutterPort(this.controller);
  final web.WebViewController controller;
  @override
  Future<Object?> evaluateJavaScript(String script) =>
      controller.runJavaScriptReturningResult(script);
  @override
  Future<bool> canGoBack() => controller.canGoBack();
  @override
  Future<void> goBack() => controller.goBack();
  @override
  Future<void> loadUrl(String url) => controller.loadRequest(Uri.parse(url));
}

class _FlutterHost extends StatefulWidget {
  const _FlutterHost({required this.controller, required this.userAgent});
  final WebHostController controller;
  final String userAgent;
  @override
  State<_FlutterHost> createState() => _FlutterHostState();
}

class _FlutterHostState extends State<_FlutterHost> {
  late final web.WebViewController _controller;
  late final _FlutterPort _port;
  bool _ready = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    final params = web.WebViewPlatform.instance is wk.WebKitWebViewPlatform
        ? wk.WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const {})
        : const web.PlatformWebViewControllerCreationParams();
    _controller = web.WebViewController.fromPlatformCreationParams(params);
    _port = _FlutterPort(_controller);
    _configure();
  }

  Future<void> _configure() async {
    try {
      await _controller.setJavaScriptMode(web.JavaScriptMode.unrestricted);
      // Controller UA covers the main document and subresources; set before load.
      await _controller.setUserAgent(widget.userAgent);
      await _controller.enableZoom(false);
      final platform = _controller.platform;
      if (platform is wk.WebKitWebViewController) {
        await platform.setAllowsBackForwardNavigationGestures(false);
        await platform.setInspectable(kDebugMode);
      }
      if (platform is android.AndroidWebViewController) {
        await android.AndroidWebViewController.enableDebugging(kDebugMode);
        await platform.setMediaPlaybackRequiresUserGesture(false);
        await platform
            .setMixedContentMode(android.MixedContentMode.alwaysAllow);
      }
      await _controller.addJavaScriptChannel(JsChannelAdapter.transportName,
          onMessageReceived: (message) {
        if (mounted) widget.controller.handleMessage(message.message);
      });
      await _controller.setNavigationDelegate(web.NavigationDelegate(
        onPageStarted: (url) {
          if (mounted) widget.controller.onLoadStart(url);
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          try {
            await _controller.runJavaScript(
                '''window.__payloadNativeSend = function(message) {
              window.${JsChannelAdapter.transportName}.postMessage(message);
            };''');
            if (mounted) await widget.controller.onLoadStop(url);
          } catch (_) {
            if (mounted) widget.controller.onMainFrameError();
          }
        },
        onProgress: (value) {
          if (mounted) widget.controller.onProgress(value);
        },
        onWebResourceError: (error) {
          if (!mounted) return;
          if (error.errorType ==
              web.WebResourceErrorType.webContentProcessTerminated) {
            widget.controller.reload();
          } else if (error.isForMainFrame == true) {
            widget.controller.onMainFrameError();
          }
        },
      ));
      if (!mounted) return;
      widget.controller.attachWebView(_port);
      await _controller.loadRequest(Uri.parse(widget.controller.url));
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    widget.controller.detachWebView(_port);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text('WebView 初始化失败：$_error'));
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return web.WebViewPlatform.instance is android.AndroidWebViewPlatform
        ? web.WebViewWidget.fromPlatformCreationParams(
            params: android.AndroidWebViewWidgetCreationParams(
                controller: _controller.platform,
                gestureRecognizers: _gestures(),
                displayWithHybridComposition: true))
        : web.WebViewWidget(
            controller: _controller, gestureRecognizers: _gestures());
  }
}
