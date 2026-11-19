import 'dart:convert';

import 'web_js_channel.dart';

/// Bridge 元数据与通道注册表（Example 内自包含）。
class BridgeRegistry {
  BridgeRegistry();

  final List<WebJsChannel> _channels = [];

  List<WebJsChannel> get channels => List.unmodifiable(_channels);

  void registerAll(Iterable<WebJsChannel> items) {
    for (final item in items) {
      _channels.removeWhere((c) => c.name == item.name);
      _channels.add(item);
    }
  }

  void clear() {
    _channels.clear();
  }

  Map<String, dynamic> buildMetaMap({
    String appVersion = '1.0.0',
    String buildNumber = '1',
  }) {
    return {
      'metaVersion': 1,
      'bridgeVersion': 1,
      'appVersion': appVersion,
      'buildNumber': buildNumber,
      'channels': _channels
          .map((c) => {
                'name': c.name,
                'version': c.version,
              })
          .toList(),
    };
  }

  String buildMetaJson({
    String appVersion = '1.0.0',
    String buildNumber = '1',
  }) {
    return jsonEncode(
      buildMetaMap(appVersion: appVersion, buildNumber: buildNumber),
    );
  }
}
