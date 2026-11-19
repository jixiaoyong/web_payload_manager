import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_payload_manager/web_payload_manager.dart';
import 'package:web_payload_manager_example/payload/module_loader_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final manager = WebPayloadManager.getInstance();
    await manager.dispose();
    await manager.initialize(
      updateUrl: 'https://example.com/check-update',
      webAssetBaseDir: 'assets/web_modules',
      dio: Dio(),
      syncOnStart: false,
      syncOnEachModuleStart: false,
    );
  });

  Widget wrapForIntegration(Widget child) {
    return MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      theme: ThemeData(useMaterial3: false),
      home: child,
    );
  }

  testWidgets('resource panel renders default controls', (tester) async {
    await tester.pumpWidget(
      wrapForIntegration(const ModuleLoaderPage(autoResolveOnStart: false)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Web 资源更新面板'), findsOneWidget);
    expect(find.text('保存地址'), findsOneWidget);
    expect(find.text('检查版本'), findsOneWidget);
    expect(find.text('立即同步'), findsOneWidget);
    expect(find.text('模块一'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('about dialog can be opened', (tester) async {
    await tester.pumpWidget(
      wrapForIntegration(const ModuleLoaderPage(autoResolveOnStart: false)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();

    expect(find.text('插件能力说明'), findsOneWidget);
    expect(find.textContaining('自动检测远程更新'), findsOneWidget);
  });
}
