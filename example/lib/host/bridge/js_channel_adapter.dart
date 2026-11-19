import 'dart:async';
import 'dart:convert';

import '../web_view_port.dart';
import 'bridge_registry.dart';

/// 两个插件均只运输 JSON 信封；业务结果统一由 Dart 执行 JS 回传。
class JsChannelAdapter {
  JsChannelAdapter(this.registry);
  final BridgeRegistry registry;
  static const transportName = 'PayloadBridge';
  static const handlerTimeout = Duration(seconds: 30);

  Future<void> handleMessage(
    WebViewPort port,
    Object? message, {
    required bool Function() isActive,
  }) async {
    if (!isActive()) return;
    String? callbackId;
    String? documentId;
    Object? result;
    try {
      final decoded = message is String ? jsonDecode(message) : message;
      if (decoded is! Map) {
        throw const FormatException('Invalid bridge envelope');
      }
      callbackId = decoded['callbackId'] as String?;
      documentId = decoded['documentId'] as String?;
      final channel = registry.channels.firstWhere(
        (item) => item.name == decoded['channel'],
        orElse: () =>
            throw StateError('Unknown channel: ${decoded['channel']}'),
      );
      result = await channel.callback(decoded['data']).timeout(handlerTimeout);
      // Fail unsupported values through the same error protocol.
      jsonEncode(result);
    } catch (error) {
      result = {'__isBridgeError': true, 'msg': error.toString()};
    }
    if (!isActive() || callbackId == null) return;
    // Keep the legacy double-JSON callback contract for existing H5 clients.
    final payload = jsonEncode(jsonEncode(result));
    try {
      await port.evaluateJavaScript('''
(function() {
  if (window.__PAYLOAD_DOCUMENT_ID__ !== ${jsonEncode(documentId)}) return;
  var callbacks = window.__webviewChannelCallbacks || {};
  var callback = callbacks[${jsonEncode(callbackId)}];
  if (callback) {
    delete callbacks[${jsonEncode(callbackId)}];
    callback(${jsonEncode(payload)});
  }
})();
''');
    } catch (_) {
      // Navigation/disposal may invalidate the document while the handler runs.
    }
  }

  String injectionScript({required bool dispatchReady}) => '''
(function() {
  window.__BRIDGE_META__ = ${registry.buildMetaJson()};
  window.__webviewChannelCallbacks = window.__webviewChannelCallbacks || {};
  window.__PAYLOAD_DOCUMENT_ID__ = window.__PAYLOAD_DOCUMENT_ID__ ||
      (Date.now() + '_' + Math.random());
  var send = window.__payloadNativeSend;
  if (typeof send !== 'function') return false;
  window.__BRIDGE_META__.channels.forEach(function(entry) {
    window[entry.name] = {postMessage: function(message) {
      var envelope = typeof message === 'string' ? JSON.parse(message) : message;
      envelope.channel = entry.name;
      envelope.documentId = window.__PAYLOAD_DOCUMENT_ID__;
      send(JSON.stringify(envelope));
    }};
  });
  if (${dispatchReady ? 'true' : 'false'} && !window.__BRIDGE_READY_DISPATCHED__) {
    window.__BRIDGE_READY_DISPATCHED__ = true;
    window.dispatchEvent(new Event('payloadBridgeReady'));
    // Compatibility only: old pages still subscribe to the InApp event.
    window.dispatchEvent(new Event('flutterInAppWebViewPlatformReady'));
    if (typeof window.flutterInAppWebViewPlatformReady === 'function') {
      window.flutterInAppWebViewPlatformReady();
    }
  }
  return true;
})();
''';

  Future<bool> injectBridge(WebViewPort port) async {
    try {
      final result =
          await port.evaluateJavaScript(injectionScript(dispatchReady: true));
      return result == true || result == 'true';
    } catch (_) {
      return false;
    }
  }
}
