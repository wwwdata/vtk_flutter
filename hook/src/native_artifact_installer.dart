import 'dart:io';

import '../../tool/native_artifacts.dart';
import 'checksums.dart';
import 'download.dart';
import 'native_artifact_target.dart';
import 'safe_zip.dart';

typedef ArtifactDownload =
    Future<File> Function({required Uri source, required File destination});

final class NativeArtifactInstaller {
  const NativeArtifactInstaller({this.download = downloadFile});

  final ArtifactDownload download;

  Future<File> installRelease({
    required NativeArtifactTarget target,
    required Directory outputDirectory,
  }) async {
    await outputDirectory.create(recursive: true);
    final manifestFile = File(
      '${outputDirectory.path}${Platform.pathSeparator}'
      '$nativeChecksumManifestName',
    );
    final archiveFile = File(
      '${outputDirectory.path}${Platform.pathSeparator}${target.archiveName}',
    );

    await download(
      source: nativeReleaseAssetUri(nativeChecksumManifestName),
      destination: manifestFile,
    );
    final expectedChecksum = checksumForArtifact(
      manifest: await manifestFile.readAsString(),
      artifactName: target.archiveName,
    );
    await download(
      source: nativeReleaseAssetUri(target.archiveName),
      destination: archiveFile,
    );
    await verifySha256(file: archiveFile, expectedChecksum: expectedChecksum);
    return extractLibraryFromZip(
      archiveFile: archiveFile,
      outputDirectory: outputDirectory,
      libraryFileName: target.libraryFileName,
    );
  }

  Future<File> installLocal({
    required File source,
    required NativeArtifactTarget target,
    required Directory outputDirectory,
  }) async {
    if (!await source.exists()) {
      throw ArgumentError.value(source.path, 'source', 'does not exist');
    }
    if (source.path.toLowerCase().endsWith('.zip')) {
      return extractLibraryFromZip(
        archiveFile: source,
        outputDirectory: outputDirectory,
        libraryFileName: target.libraryFileName,
      );
    }

    await outputDirectory.create(recursive: true);
    final destination = File(
      '${outputDirectory.path}${Platform.pathSeparator}'
      '${target.libraryFileName}',
    );
    final partial = File('${destination.path}.partial');
    if (await partial.exists()) await partial.delete();
    await source.copy(partial.path);
    if (await destination.exists()) await destination.delete();
    return partial.rename(destination.path);
  }
}
