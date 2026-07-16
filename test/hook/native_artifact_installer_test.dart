import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../hook/src/native_artifact_installer.dart';
import '../../hook/src/native_artifact_target.dart';
import '../../tool/native_artifacts.dart';

void main() {
  late Directory temporaryDirectory;
  late File archiveFixture;
  late File manifestFixture;
  late NativeArtifactTarget target;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vtk-installer-test-',
    );
    target = NativeArtifactTarget.resolve(
      operatingSystem: OS.macOS,
      architecture: Architecture.arm64,
    );
    final archive = Archive()
      ..add(ArchiveFile.string(target.libraryFileName, 'native library'));
    archiveFixture = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}fixture.zip',
    );
    await archiveFixture.writeAsBytes(ZipEncoder().encode(archive));
    final checksum = sha256
        .convert(await archiveFixture.readAsBytes())
        .toString();
    manifestFixture = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}fixture.SHA256SUMS',
    );
    await manifestFixture.writeAsString('$checksum  ${target.archiveName}\n');
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('downloads the pinned manifest and verified target artifact', () async {
    final requestedUris = <Uri>[];
    final installer = NativeArtifactInstaller(
      download: ({required source, required destination}) async {
        requestedUris.add(source);
        final fixture = source.pathSegments.last == nativeChecksumManifestName
            ? manifestFixture
            : archiveFixture;
        return fixture.copy(destination.path);
      },
    );

    final installed = await installer.installRelease(
      target: target,
      outputDirectory: Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}output',
      ),
    );

    expect(await installed.readAsString(), 'native library');
    expect(requestedUris, [
      nativeReleaseAssetUri(nativeChecksumManifestName),
      nativeReleaseAssetUri(target.archiveName),
    ]);
  });

  test('does not extract an artifact with a mismatched checksum', () async {
    await manifestFixture.writeAsString('${'0' * 64}  ${target.archiveName}\n');
    final installer = NativeArtifactInstaller(
      download: ({required source, required destination}) {
        final fixture = source.pathSegments.last == nativeChecksumManifestName
            ? manifestFixture
            : archiveFixture;
        return fixture.copy(destination.path);
      },
    );
    final outputDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}output',
    );

    await expectLater(
      installer.installRelease(
        target: target,
        outputDirectory: outputDirectory,
      ),
      throwsStateError,
    );
    expect(
      await File(
        '${outputDirectory.path}${Platform.pathSeparator}'
        '${target.libraryFileName}',
      ).exists(),
      isFalse,
    );
  });
}
