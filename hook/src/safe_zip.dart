import 'dart:io';

import 'package:archive/archive_io.dart';

const _maximumArchiveEntries = 1024;
const _maximumLibrarySize = 512 * 1024 * 1024;

Future<File> extractLibraryFromZip({
  required File archiveFile,
  required Directory outputDirectory,
  required String libraryFileName,
}) async {
  final input = InputFileStream(archiveFile.path);
  late final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input, verify: true);
  } on Object {
    input.closeSync();
    rethrow;
  }

  try {
    if (archive.length > _maximumArchiveEntries) {
      throw const FormatException('Native artifact has too many entries.');
    }

    final candidates = <ArchiveFile>[];
    for (final entry in archive) {
      _validateArchivePath(entry.name);
      if (entry.isSymbolicLink) {
        throw FormatException(
          'Native artifact contains a symbolic link: ${entry.name}.',
        );
      }
      if (entry.isFile && _basename(entry.name) == libraryFileName) {
        candidates.add(entry);
      }
    }

    if (candidates.length != 1) {
      throw FormatException(
        'Native artifact must contain exactly one $libraryFileName; '
        'found ${candidates.length}.',
      );
    }

    final library = candidates.single;
    if (library.size <= 0 || library.size > _maximumLibrarySize) {
      throw FormatException(
        'Native library has invalid uncompressed size ${library.size}.',
      );
    }

    await outputDirectory.create(recursive: true);
    final destination = File(
      '${outputDirectory.path}${Platform.pathSeparator}$libraryFileName',
    );
    final partial = File('${destination.path}.partial');
    if (await partial.exists()) await partial.delete();

    final output = OutputFileStream(partial.path);
    try {
      library.writeContent(output);
      output.closeSync();
    } on Object {
      output.closeSync();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }

    if (await partial.length() != library.size) {
      await partial.delete();
      throw const FormatException('Extracted native library size is invalid.');
    }
    if (await destination.exists()) await destination.delete();
    return partial.rename(destination.path);
  } finally {
    archive.clearSync();
    input.closeSync();
  }
}

void _validateArchivePath(String path) {
  if (path.isEmpty ||
      path.contains('\u0000') ||
      path.startsWith('/') ||
      path.startsWith('\\') ||
      path.contains('\\') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(path)) {
    throw FormatException('Unsafe native artifact path: $path.');
  }

  final segments = path.split('/');
  final pathSegments = path.endsWith('/')
      ? segments.take(segments.length - 1)
      : segments;
  if (pathSegments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw FormatException('Unsafe native artifact path: $path.');
  }
}

String _basename(String path) => path.split('/').last;
