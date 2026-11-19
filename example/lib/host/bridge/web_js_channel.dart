/// JS Bridge 通道定义。
class WebJsChannel {
  const WebJsChannel({
    required this.name,
    required this.callback,
    this.version = 1,
  });

  final String name;
  final int version;
  final Future<dynamic> Function(dynamic data) callback;
}
