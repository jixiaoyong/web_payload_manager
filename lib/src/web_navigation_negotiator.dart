import 'dart:async';

import 'util/logger.dart';

/// H5 SPA 单页路由与 Flutter 原生返回事件协商器
///
/// 解决混合开发中 Android 物理返回键 / iOS 边缘滑动手势回退时的三大致命痛点：
/// 1. 传统 WebView 仅依赖 `canGoBack()`，容易因 Vue/React Router 的 hash/history 栈不同步，
///    导致误把 H5 根路由判定为可回退，用户被卡死在页面中无法退出；
/// 2. 原生直接 `Navigator.pop(context)`，导致 H5 内部的二级、三级深层页面无法逐层回退，直接误关整个容器；
/// 3. H5 发生 JS 异常、未响应或未注入时，返回调用挂起导致原生返回键卡死。
///
/// 协议规范：
/// 前端 SPA 页面（如 Vue/React）在 `window` 上挂载 `__tryGoBack` 函数：
/// ```javascript
/// window.__tryGoBack = function() {
///   if (router && router.currentRoute && router.currentRoute.path !== '/') {
///     router.back();
///     return true; // 告知 Native：H5 已消费该回退事件，不要关闭原生页面
///   }
///   return false; // 告知 Native：已在根路径，需要原生容器执行关闭
/// };
/// ```
class WebNavigationNegotiator {
  const WebNavigationNegotiator._();

  /// 默认协商超时时间（500ms），防止 H5 挂起阻塞原生交互
  static const Duration defaultTimeout = Duration(milliseconds: 500);

  /// 协商回退操作
  ///
  /// - [runJavaScriptReturningResult]: 执行 JavaScript 并返回结果的回调
  /// - [canGoBackFallback]: 当 H5 未定义 `__tryGoBack` 或执行报错时的降级探测
  /// - [goBackFallback]: 降级执行 WebView 原生 goBack
  /// - [timeout]: 协商超时时间，默认 500ms
  ///
  /// 返回值：
  /// - `true`: 回退已被 H5 单页路由或原生 WebView 历史消费（不应关闭原生页面）
  /// - `false`: 无法继续内部回退，应由原生容器关闭当前页面 (`Navigator.pop`)
  static Future<bool> tryGoBack({
    required Future<dynamic> Function(String script)
        runJavaScriptReturningResult,
    Future<bool> Function()? canGoBackFallback,
    Future<void> Function()? goBackFallback,
    Duration timeout = defaultTimeout,
  }) async {
    try {
      final dynamic raw = await runJavaScriptReturningResult(
        "typeof window.__tryGoBack === 'function' ? window.__tryGoBack() : null",
      ).timeout(timeout);

      final handled = _parseBooleanResult(raw);
      logger.d(
        '[WebNavigationNegotiator] __tryGoBack raw: $raw, handled: $handled',
      );

      // 显式 false 是根路由的关闭指令，不得再消费 WebView 历史。
      if (handled != null) return handled;
    } catch (e) {
      logger.w(
        '[WebNavigationNegotiator] evaluate __tryGoBack failed or timed out: $e',
      );
    }

    // Fallback 策略：如果前端未实现 __tryGoBack 或执行失败，尝试 fallback 检查
    if (canGoBackFallback != null && goBackFallback != null) {
      try {
        final canBack = await canGoBackFallback();
        if (canBack) {
          await goBackFallback();
          return true;
        }
      } catch (e) {
        logger.w('[WebNavigationNegotiator] fallback goBack failed: $e');
      }
    }

    return false;
  }

  static bool? _parseBooleanResult(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final str = raw?.toString().trim().toLowerCase();
    if (str == 'true' || str == '1') return true;
    if (str == 'false' || str == '0') return false;
    return null; // 缺失函数或不符合协议的返回值才允许降级。
  }
}
