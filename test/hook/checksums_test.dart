import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../hook/src/checksums.dart';

void main() {
  group('checksumForArtifact', () {
    const checksum =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test('parses GNU and BSD checksum formats by exact artifact name', () {
      expect(
        checksumForArtifact(
          manifest: '$checksum  artifact.zip\n',
          artifactName: 'artifact.zip',
        ),
        checksum,
      );
      expect(
        checksumForArtifact(
          manifest: 'SHA256 (artifact.zip) = ${checksum.toUpperCase()}\n',
          artifactName: 'artifact.zip',
        ),
        checksum,
      );
    });

    test('does not accept a checksum for a suffix-matching artifact', () {
      expect(
        () => checksumForArtifact(
          manifest: '$checksum  other-artifact.zip\n',
          artifactName: 'artifact.zip',
        ),
        throwsFormatException,
      );
    });

    test('rejects duplicate checksum entries', () {
      expect(
        () => checksumForArtifact(
          manifest: '$checksum  artifact.zip\n$checksum *artifact.zip\n',
          artifactName: 'artifact.zip',
        ),
        throwsFormatException,
      );
    });
  });

  group('verifySha256', () {
    late Directory temporaryDirectory;
    late File fixture;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'vtk-checksum-test-',
      );
      fixture = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}artifact.zip',
      );
      await fixture.writeAsString('verified bytes');
    });

    tearDown(() async {
      await temporaryDirectory.delete(recursive: true);
    });

    test('accepts the exact file digest', () async {
      final checksum = sha256.convert(await fixture.readAsBytes()).toString();

      await expectLater(
        verifySha256(file: fixture, expectedChecksum: checksum),
        completes,
      );
    });

    test('rejects a digest mismatch', () async {
      await expectLater(
        verifySha256(file: fixture, expectedChecksum: '0' * 64),
        throwsStateError,
      );
    });
  });
}
