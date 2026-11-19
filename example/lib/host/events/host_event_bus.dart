import 'dart:convert';

import '../web_view_port.dart';

/// 向 H5 推送事件的轻量工具（对应 H5 侧 window.__AppEventBus）。
class HostEventBus {
  HostEventBus._();

  static Future<void> emit(
    WebViewPort controller,
    String eventType,
    Map<String, dynamic> data,
  ) async {
    final sanitized = data.map(
      (key, value) => MapEntry(key, _sanitize(value)),
    );
    final js = '''
if (window.__AppEventBus && typeof window.__AppEventBus.emit === 'function') {
  window.__AppEventBus.emit(${jsonEncode(eventType)}, ${jsonEncode(sanitized)});
}
''';
    try {
      await controller.evaluateJavaScript(js);
    } catch (_) {}
  }

  static dynamic _sanitize(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _sanitize(v)));
    }
    if (value is List) {
      return value.map(_sanitize).toList();
    }
    return value.toString();
  }
}
