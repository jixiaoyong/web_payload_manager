import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_payload_manager/web_payload_manager.dart';
import 'package:web_payload_manager_example/payload/module_loader_page.dart';
import 'package:web_payload_manager_example/payload/payload_module_controller.dart';

import 'widget_test.dart';

class FakePayloadModuleController extends PayloadModuleController {
  FakePayloadModuleController(super.moduleKey, {required this.initialState}) {
    state = initialState;
  }

  final ResourceState initialState;

  @override
  Future<void> start() async {
    notifyListeners();
  }
}

Future<void> _pumpUntilModuleResolved(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('auto resolve shows loading progress', (tester) async {
    await tester.pumpWidget(
      wrapForTest(
        ModuleLoaderPage(
          controllerFactory: (key) => FakePayloadModuleController(
            key,
            initialState: const ResourceState.loading(
              progress: 0.42,
              currentBytes: 420000,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilModuleResolved(tester);
    await tester.scrollUntilVisible(
      find.text('本地模块访问'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('下载中 42%'), findsWidgets);
    expect(find.textContaining('410.2 KB'), findsOneWidget);
    expect(find.text('解析进度'), findsOneWidget);
  });

  testWidgets('auto resolve shows ready state and open action', (tester) async {
    await tester.pumpWidget(
      wrapForTest(
        ModuleLoaderPage(
          controllerFactory: (key) => FakePayloadModuleController(
            key,
            initialState: const ResourceState.data(
              'http://127.0.0.1:9999/index.html',
            ),
          ),
        ),
      ),
    );

    await _pumpUntilModuleResolved(tester);
    await tester.scrollUntilVisible(
      find.text('本地模块访问'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.scrollUntilVisible(
      find.text('flutter_inappwebview'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('flutter_inappwebview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('flutter_inappwebview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('webview_flutter').last);
    await tester.pumpAndSettle();
    expect(find.text('webview_flutter'), findsOneWidget);
    expect(find.text('已就绪'), findsWidgets);
    expect(find.text('http://127.0.0.1:9999/index.html'), findsOneWidget);
    expect(find.text('打开模块页面'), findsOneWidget);
  });

  testWidgets('shows error state when resolve fails', (tester) async {
    await tester.pumpWidget(
      wrapForTest(
        ModuleLoaderPage(
          controllerFactory: (_) => FakePayloadModuleController(
            'missing_module',
            initialState: const ResourceState.error(
              message: 'Module missing',
              severity: ErrorSeverity.critical,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilModuleResolved(tester);
    await tester.scrollUntilVisible(
      find.text('本地模块访问'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('加载失败'), findsWidgets);
  });
}
