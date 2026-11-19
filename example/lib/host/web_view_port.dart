/// Example 业务实际需要的最小 WebView 能力，不暴露插件 controller。
abstract interface class WebViewPort {
  Future<Object?> evaluateJavaScript(String script);
  Future<bool> canGoBack();
  Future<void> goBack();
  Future<void> loadUrl(String url);
}

enum WebViewEngine {
  inAppWebView('flutter_inappwebview'),
  webViewFlutter('webview_flutter');

  const WebViewEngine(this.label);
  final String label;
}
