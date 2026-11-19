import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/exception_handler.dart';
import 'package:web_payload_manager/src/version_parser.dart';
import 'package:web_payload_manager/src/web_payload_models.dart';

void main() {
  group('StandardVersionParser', () {
    const parser = StandardVersionParser();

    test('parses static root JSON with SemVer version and downloadUrl', () {
      const json = {
        'moduleKey': 'finance_report',
        'version': '1.2.0',
        'downloadUrl':
            'https://cdn.example.com/bundles/finance_report_1.2.0.zip',
        'md5': 'e10adc3949ba59abbe56e057f20f883e',
        'minAppVersion': '1.0.0',
        'forceUpdate': true,
        'entryFile': 'index.html',
      };

      final bean = parser.parse(json);
      expect(bean.versionStr, '1.2.0');
      expect(bean.effectiveVersionStr, '1.2.0');
      expect(bean.downloadUrl,
          'https://cdn.example.com/bundles/finance_report_1.2.0.zip');
      expect(bean.zipUrl,
          'https://cdn.example.com/bundles/finance_report_1.2.0.zip');
      expect(bean.md5, 'e10adc3949ba59abbe56e057f20f883e');
      expect(bean.minAppVersion, '1.0.0');
      expect(bean.forceUpdate, true);
      expect(bean.entryFile, 'index.html');
      expect(bean.moduleKey, 'finance_report');
    });

    test('parses static root JSON from raw JSON string', () {
      const jsonStr = '''
      {
        "version": 15,
        "zipUrl": "https://cdn.example.com/bundle_15.zip",
        "md5": "abc12345"
      }
      ''';

      final bean = parser.parse(jsonStr);
      expect(bean.version, 15);
      expect(bean.versionStr, '15');
      expect(bean.zipUrl, 'https://cdn.example.com/bundle_15.zip');
      expect(bean.md5, 'abc12345');
    });

    test('parses legacy business envelope with code: 0', () {
      const envelope = {
        'code': 0,
        'msg': 'success',
        'data': {
          'version': 100,
          'zipUrl': 'https://company.internal/bundle.zip',
          'md5': 'fff999',
        },
      };

      final bean = parser.parse(envelope);
      expect(bean.version, 100);
      expect(bean.zipUrl, 'https://company.internal/bundle.zip');
      expect(bean.md5, 'fff999');
    });

    test('throws NetworkException on business failure code', () {
      const failure = {
        'code': 5001,
        'msg': 'Resource not released yet',
      };

      expect(
        () => parser.parse(failure),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.message,
            'message',
            contains('Resource not released yet'),
          ),
        ),
      );
    });

    test('throws ValidationException when data is null in envelope', () {
      const invalid = {
        'code': 0,
        'data': null,
      };

      expect(
        () => parser.parse(invalid),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('CustomVersionParser', () {
    test('uses user-provided parsing callback', () {
      final custom = CustomVersionParser((raw) {
        final map = raw as Map<String, dynamic>;
        return WebVersionInfoBean(
          versionStr: map['v_tag'] as String?,
          zipUrl: map['cdn_source'] as String?,
        );
      });

      final result =
          custom.parse({'v_tag': '2.4.1', 'cdn_source': 'http://cdn/app.zip'});
      expect(result.versionStr, '2.4.1');
      expect(result.zipUrl, 'http://cdn/app.zip');
    });
  });

  group('VersionComparator', () {
    test('compares integer versions', () {
      expect(VersionComparator.needsUpdate(localVersion: 10, remoteVersion: 12),
          isTrue);
      expect(VersionComparator.needsUpdate(localVersion: 12, remoteVersion: 12),
          isFalse);
      expect(VersionComparator.needsUpdate(localVersion: 15, remoteVersion: 12),
          isFalse);
    });

    test('compares timestamp versions', () {
      expect(
        VersionComparator.needsUpdate(
          localVersion: 1792649400000,
          remoteVersion: 1792649467655,
        ),
        isTrue,
      );
      expect(
        VersionComparator.needsUpdate(
          localVersion: 1792649467655,
          remoteVersion: 1792649400000,
        ),
        isFalse,
      );
    });

    test('compares semantic version strings (SemVer)', () {
      expect(
        VersionComparator.needsUpdate(
          localVersion: '1.1.9',
          remoteVersion: '1.2.0',
        ),
        isTrue,
      );
      expect(
        VersionComparator.needsUpdate(
          localVersion: '1.2.0',
          remoteVersion: '1.2.0',
        ),
        isFalse,
      );
      expect(
        VersionComparator.needsUpdate(
          localVersion: '2.0.0',
          remoteVersion: '1.9.99',
        ),
        isFalse,
      );
      expect(
        VersionComparator.needsUpdate(
          localVersion: 'v1.0.0',
          remoteVersion: 'v1.0.1',
        ),
        isTrue,
      );
    });

    test('orders prereleases according to SemVer precedence', () {
      const versions = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (var i = 0; i < versions.length; i++) {
        expect(VersionComparator.compareSemVer(versions[i], versions[i]), 0);
        for (var j = i + 1; j < versions.length; j++) {
          expect(
            VersionComparator.compareSemVer(versions[i], versions[j]),
            lessThan(0),
            reason: '${versions[i]} < ${versions[j]}',
          );
          expect(
            VersionComparator.compareSemVer(versions[j], versions[i]),
            greaterThan(0),
          );
        }
      }
    });

    test('ignores build metadata for releases and prereleases', () {
      for (final pair in [
        ['1.2.3+build.1', '1.2.3+build.99'],
        ['1.2.3+build.1', '1.2.3'],
        ['1.2.3-rc.1+build.1', '1.2.3-rc.1+build.99'],
      ]) {
        expect(VersionComparator.compareSemVer(pair[0], pair[1]), 0);
        expect(VersionComparator.compareSemVer(pair[1], pair[0]), 0);
        expect(
          VersionComparator.needsUpdate(
            localVersion: pair[0],
            remoteVersion: pair[1],
          ),
          isFalse,
        );
      }
    });

    test('updates from prerelease to release but not the reverse', () {
      expect(
        VersionComparator.needsUpdate(
          localVersion: 'v1.2.3-rc.1+build.9',
          remoteVersion: 'V1.2.3+build.1',
        ),
        isTrue,
      );
      expect(
        VersionComparator.needsUpdate(
          localVersion: '1.2.3',
          remoteVersion: '1.2.3-rc.1',
        ),
        isFalse,
      );
    });

    test('compares numeric identifiers below text and preserves hyphens', () {
      expect(
        VersionComparator.compareSemVer('1.0.0-2', '1.0.0-1a'),
        lessThan(0),
      );
      expect(
        VersionComparator.compareSemVer('1.0.0-alpha-1', '1.0.0-alpha.1'),
        greaterThan(0),
      );
      expect(
        VersionComparator.compareSemVer(
          '1.0.0-999999999999999999999999999999',
          '1.0.0-1000000000000000000000000000000',
        ),
        lessThan(0),
      );
      expect(
        VersionComparator.compareSemVer('2.0.0-alpha', '1.9.9'),
        greaterThan(0),
      );
    });

    test('preserves numeric strings, timestamps and shortened versions', () {
      expect(
        VersionComparator.needsUpdate(localVersion: '9', remoteVersion: '10'),
        isTrue,
      );
      expect(
        VersionComparator.needsUpdate(
          localVersion: '1792649400000',
          remoteVersion: '1792649467655',
        ),
        isTrue,
      );
      expect(VersionComparator.compareSemVer(' V1.2 ', '1.2.0'), 0);
    });

    test('returns true when local version is null or empty', () {
      expect(
          VersionComparator.needsUpdate(
              localVersion: null, remoteVersion: '1.0.0'),
          isTrue);
      expect(
          VersionComparator.needsUpdate(
              localVersion: '', remoteVersion: '1.0.0'),
          isTrue);
      expect(
          VersionComparator.needsUpdate(
              localVersion: '1.0.0', remoteVersion: null),
          isFalse);
    });
  });
}
