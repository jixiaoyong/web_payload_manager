import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_payload_manager_example/payload/module_loader_page.dart';

Widget wrapForTest(Widget child) {
  return MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
    theme: ThemeData(
      useMaterial3: false,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
    ),
    home: child,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('resource panel renders capability sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      wrapForTest(const ModuleLoaderPage(autoResolveOnStart: false)),
    );
    await tester.pump();

    expect(find.text('Web 资源更新面板'), findsOneWidget);
    expect(find.text('保存地址'), findsOneWidget);
    expect(find.text('检查版本'), findsOneWidget);
    expect(find.text('立即同步'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('本地模块访问'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('本地模块访问'), findsOneWidget);
    expect(find.text('打开模块页面'), findsOneWidget);
    expect(find.text('加载模块'), findsNothing);
  });
}
