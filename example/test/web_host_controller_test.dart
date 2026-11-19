import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager_example/host/bridge/bridge_registry.dart';
import 'package:web_payload_manager_example/host/bridge/js_channel_adapter.dart';
import 'package:web_payload_manager_example/host/bridge/web_js_channel.dart';
import 'package:web_payload_manager_example/host/web_host_controller.dart';
import 'package:web_payload_manager_example/host/web_view_port.dart';

class FakeWebViewPort implements WebViewPort {
  final scripts = <String>[];
  final loads = <String>[];
  Completer<Object?>? evaluation;
  bool hasHistory = false;
  bool wentBack = false;
  @override
  Future<Object?> evaluateJavaScript(String script) async {
    scripts.add(script);
    return evaluation?.future ?? true;
  }

  @override
  Future<bool> canGoBack() async => hasHistory;
  @override
  Future<void> goBack() async => wentBack = true;
  @override
  Future<void> loadUrl(String url) async => loads.add(url);
}

void main() {
  late WebHostController host;
  late FakeWebViewPort port;
  setUp(() {
    host = WebHostController(onClosePage: () {}, onToast: (_) {});
    port = FakeWebViewPort();
    host.attachWebView(port);
  });
  tearDown(() => host.dispose());

  test('shared transport returns callbackId and double JSON payload', () async {
    await host.handleMessage(jsonEncode({
      'channel': 'DemoEcho',
      'callbackId': 'cb_1',
      'documentId': 'doc_1',
      'data': {'message': 'hello'},
    }));
    expect(port.scripts.single, contains('cb_1'));
    expect(port.scripts.single, contains('doc_1'));
    final line = port.scripts.single
        .split('\n')
        .firstWhere((line) => line.trim().startsWith('callback('));
    final literal = line.trim().substring(9, line.trim().length - 2);
    final raw = jsonDecode(literal) as String;
    expect(jsonDecode(jsonDecode(raw) as String), {
      'echo': {'message': 'hello'}
    });
  });

  test('unknown channels return bridge errors', () async {
    await host.handleMessage(
        {'channel': 'missing', 'callbackId': 'cb', 'documentId': 'doc'});
    expect(port.scripts.single, contains('__isBridgeError'));
    expect(port.scripts.single, contains('Unknown channel'));
  });

  test('page disposed during injection does not notify', () async {
    port.evaluation = Completer<Object?>();
    final pending = host.onLoadStop('http://localhost');
    host.detachWebView(port);
    port.evaluation!.complete(true);
    await pending;
    expect(port.scripts, hasLength(1));
    host.onProgress(50);
  });

  test('disposed controller ignores delayed native notifications', () async {
    final disposedHost = WebHostController(onClosePage: () {}, onToast: (_) {});
    final disposedPort = FakeWebViewPort();
    disposedHost.attachWebView(disposedPort);
    disposedHost.dispose();
    disposedHost.onProgress(100);
    disposedHost.onMainFrameError();
    await disposedHost.emitEvent('PAY_RESULT', {'status': 'success'});
    await disposedHost.reload();
    await disposedHost.onLoadStop('http://localhost');
    expect(disposedPort.scripts, isEmpty);
    expect(disposedPort.loads, isEmpty);
  });

  test('pending handlers cannot reply to replacement documents', () async {
    final result = Completer<Object?>();
    final registry = BridgeRegistry()
      ..registerAll([
        WebJsChannel(name: 'slow', version: 1, callback: (_) => result.future),
      ]);
    final adapter = JsChannelAdapter(registry);
    var active = true;
    final pending = adapter.handleMessage(
        port,
        {
          'channel': 'slow',
          'callbackId': 'cb',
          'documentId': 'doc',
        },
        isActive: () => active);
    active = false;
    result.complete({'ok': true});
    await pending;
    expect(port.scripts, isEmpty);
  });

  testWidgets('handler timeout returns error via callback', (tester) async {
    final never = Completer<Object?>();
    final registry = BridgeRegistry()
      ..registerAll([
        WebJsChannel(name: 'slow', version: 1, callback: (_) => never.future),
      ]);
    final pending = JsChannelAdapter(registry).handleMessage(
        port,
        {
          'channel': 'slow',
          'callbackId': 'cb',
          'documentId': 'doc',
        },
        isActive: () => true);
    await tester
        .pump(JsChannelAdapter.handlerTimeout + const Duration(seconds: 1));
    await pending;
    expect(port.scripts.single, contains('TimeoutException'));
    expect(port.scripts.single, contains('__isBridgeError'));
    never.complete(null);
  });

  test(
      'bridge injection exposes plugin neutral readiness and compatibility event',
      () {
    final script = host.bridge.injectionScript(dispatchReady: true);
    expect(script, contains('payloadBridgeReady'));
    expect(script, contains('flutterInAppWebViewPlatformReady'));
    expect(script, isNot(contains('flutter_inappwebview')));
    expect(script, contains('documentId'));
  });
}
