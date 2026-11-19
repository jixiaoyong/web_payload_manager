import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/web_payload_models.dart';

void main() {
  group('VersionJsonBean', () {
    test('parses modules and file info from json', () {
      final bean = VersionJsonBean.fromJson({
        'version': 6,
        'fileInfo': {
          'total_files': 2,
          'files': [
            {'path': 'module_one/index.html', 'md5': 'aaa'},
            {'path': 'common/style.css', 'md5': 'bbb'},
          ],
        },
        'modules': [
          {
            'name': 'Module One',
            'key': 'module_one',
            'entryHtml': 'module_one/index.html',
            'version': 6,
            'description': 'demo',
          }
        ],
      });

      expect(bean.version, 6);
      expect(bean.fileInfo?.totalFiles, 2);
      expect(bean.fileInfo?.files?.first.path, 'module_one/index.html');
      expect(bean.modules, isNotNull);
      expect(bean.modules!.single.key, 'module_one');
      expect(bean.modules!.single.entryHtml, 'module_one/index.html');
    });
  });

  group('ResourceState', () {
    test('data state stores url', () {
      const state = ResourceState.data('http://127.0.0.1:8080/index.html');
      expect((state as Data).data, contains('127.0.0.1'));
    });

    test('error state stores message and severity', () {
      const state = ResourceState.error(
        message: 'boom',
        severity: ErrorSeverity.critical,
      );
      expect((state as Error).message, 'boom');
      expect(state.severity, ErrorSeverity.critical);
    });
  });
}
