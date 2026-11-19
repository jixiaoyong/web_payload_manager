import 'web_view_port.dart';

/// 可选的通用 WebView 注入能力。
///
/// 当前仅提供一项通用 WebView 注入能力：
/// 减少页面上的长按选中文本与系统菜单出现概率。
class WebViewTweaks {
  WebViewTweaks._();

  static const String _disableSelectionScript = r'''
(function() {
  var style = document.getElementById('__wv_no_select_style__');
  if (!style) {
    style = document.createElement('style');
    style.id = '__wv_no_select_style__';
    style.innerHTML =
      '*{-webkit-touch-callout:none!important;' +
      '-webkit-user-select:none!important;user-select:none!important;}' +
      'input,textarea,[contenteditable="true"]{' +
      '-webkit-user-select:text!important;user-select:text!important;}';
    document.head.appendChild(style);
  }
  function allowEditTarget(t) {
    if (!t || !t.tagName) return false;
    var tag = t.tagName.toLowerCase();
    if (tag === 'input' || tag === 'textarea') return true;
    return t.isContentEditable === true;
  }
  document.addEventListener('contextmenu', function(e) {
    if (allowEditTarget(e.target)) return;
    e.preventDefault();
  }, { capture: true });
  ['copy', 'cut', 'paste', 'selectstart'].forEach(function(type) {
    document.addEventListener(type, function(e) {
      if (allowEditTarget(e.target)) return;
      e.preventDefault();
    }, { capture: true });
  });
})();
''';

  static Future<void> injectDisableSelection(
    WebViewPort controller,
  ) async {
    try {
      await controller.evaluateJavaScript(_disableSelectionScript);
    } catch (_) {}
  }
}
