import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/file_path_utility.dart';

void main() {
  group('FilePathUtility.isPathSafe', () {
    test('accepts file inside base path', () {
      expect(
        FilePathUtility.isPathSafe('module/index.html', '/tmp/web'),
        isTrue,
      );
    });

    test('rejects parent traversal outside base path', () {
      expect(
        FilePathUtility.isPathSafe('../secret.txt', '/tmp/web'),
        isFalse,
      );
    });

    test('rejects absolute escape path', () {
      expect(
        FilePathUtility.isPathSafe('/etc/passwd', '/tmp/web'),
        isFalse,
      );
    });
  });
}
