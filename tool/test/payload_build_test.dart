import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../bin/server.dart';

void main() {
  test('awaited ZIP close produces readable payload and matching digest',
      () async {
    final temp = await Directory.systemTemp.createTemp('payload_build_');
    addTearDown(() => temp.delete(recursive: true));
    final assets = Directory('${temp.path}/assets');
    for (final module in ['module_one', 'module_two']) {
      final file = File('${assets.path}/$module/index.html');
      await file.parent.create(recursive: true);
      await file.writeAsString('<html><body>你好 payload</body></html>');
    }
    final output = Directory('${temp.path}/dist');
    await runPayloadBuild(assetsDirectory: assets, outputDirectory: output);
    final manifest = jsonDecode(
        await File('${output.path}/server_manifest.json').readAsString());
    final bytes =
        await File('${output.path}/${manifest['zipFilename']}').readAsBytes();
    expect(md5.convert(bytes).toString(), manifest['zipMd5']);
    expect(bytes.length, manifest['zipSize']);
    final archive =
        ZipDecoder().decodeBytes(bytes, verify: true, throwOnError: true);
    for (final file in archive.files) {
      expect(file.content.length, file.size);
    }
    final metadata =
        jsonDecode(utf8.decode(archive.findFile('version.json')!.content));
    expect(metadata['version'], manifest['version']);
    for (final entry in metadata['fileInfo']['files']) {
      expect(md5.convert(archive.findFile(entry['path'])!.content).toString(),
          entry['md5']);
    }
  });
}
