import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/download_service.dart';

void main() {
  group('DownloadService.compareVersions', () {
    final service = DownloadService();

    test('returns true when local version is null', () {
      expect(
        service.compareVersions(localVersion: null, remoteVersion: 1),
        isTrue,
      );
    });

    test('returns true when remote version is greater', () {
      expect(
        service.compareVersions(localVersion: 1, remoteVersion: 2),
        isTrue,
      );
    });

    test('returns false when versions are equal', () {
      expect(
        service.compareVersions(localVersion: 2, remoteVersion: 2),
        isFalse,
      );
    });

    test('returns false when remote version is smaller', () {
      expect(
        service.compareVersions(localVersion: 3, remoteVersion: 2),
        isFalse,
      );
    });

    tearDownAll(service.dispose);
  });
}
