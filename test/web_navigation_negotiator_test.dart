import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/web_navigation_negotiator.dart';

void main() {
  group('WebNavigationNegotiator', () {
    test('returns true when H5 __tryGoBack returns boolean true', () async {
      final handled = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async => true,
      );
      expect(handled, isTrue);
    });

    test('returns false when H5 __tryGoBack returns boolean false', () async {
      final handled = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async => false,
      );
      expect(handled, isFalse);
    });

    test('accepts string "true" and "1"', () async {
      final handled1 = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async => 'true',
      );
      expect(handled1, isTrue);

      final handled2 = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async => 1,
      );
      expect(handled2, isTrue);
    });

    test('explicit false closes container even when native history exists',
        () async {
      bool goBackCalled = false;

      final handled = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async => false,
        canGoBackFallback: () async => true,
        goBackFallback: () async {
          goBackCalled = true;
        },
      );

      expect(handled, isFalse);
      expect(goBackCalled, isFalse);
    });

    test('returns false when both __tryGoBack and fallback cannot go back',
        () async {
      bool goBackCalled = false;

      final handled = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async => false,
        canGoBackFallback: () async => false,
        goBackFallback: () async {
          goBackCalled = true;
        },
      );

      expect(handled, isFalse);
      expect(goBackCalled, isFalse);
    });

    test('missing function uses null sentinel and native fallback', () async {
      var called = false;
      expect(
          await WebNavigationNegotiator.tryGoBack(
            runJavaScriptReturningResult: (script) async {
              expect(
                  script, contains("typeof window.__tryGoBack === 'function'"));
              expect(script, endsWith(': null'));
              return null;
            },
            canGoBackFallback: () async => true,
            goBackFallback: () async {
              called = true;
            },
          ),
          isTrue);
      expect(called, isTrue);
    });

    test('string false never falls back', () async {
      expect(
          await WebNavigationNegotiator.tryGoBack(
            runJavaScriptReturningResult: (_) async => 'false',
            canGoBackFallback: () async => fail('must not probe history'),
            goBackFallback: () async => fail('must not navigate history'),
          ),
          isFalse);
    });

    test('falls back safely when JS evaluation throws an error', () async {
      bool goBackCalled = false;

      final handled = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async =>
            throw Exception('JS crashed'),
        canGoBackFallback: () async => true,
        goBackFallback: () async {
          goBackCalled = true;
        },
      );

      expect(handled, isTrue);
      expect(goBackCalled, isTrue);
    });

    test(
        'falls back safely when JS evaluation times out (500ms safety timeout)',
        () async {
      bool goBackCalled = false;

      final handled = await WebNavigationNegotiator.tryGoBack(
        runJavaScriptReturningResult: (script) async {
          await Future.delayed(const Duration(milliseconds: 700));
          return true;
        },
        timeout: const Duration(milliseconds: 100),
        canGoBackFallback: () async => true,
        goBackFallback: () async {
          goBackCalled = true;
        },
      );

      expect(handled, isTrue);
      expect(goBackCalled, isTrue);
    });
  });
}
