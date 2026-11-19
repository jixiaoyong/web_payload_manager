import 'package:flutter/material.dart';

typedef AppRestartCallback = Future<void> Function();

/// 供子页面在配置变更后触发 Example 重新初始化。
class AppRestartScope extends InheritedWidget {
  const AppRestartScope({
    super.key,
    required this.onRestart,
    required super.child,
  });

  final AppRestartCallback onRestart;

  static AppRestartCallback? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AppRestartScope>()
        ?.onRestart;
  }

  @override
  bool updateShouldNotify(AppRestartScope oldWidget) {
    return onRestart != oldWidget.onRestart;
  }
}
