import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '../../hook/src/safe_zip.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory outputDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('vtk-zip-test-');
    outputDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}output',
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('extracts one nested library to the stable output filename', () async {
    final archive = await _writeZip(
      temporaryDirectory: temporaryDirectory,
      entries: [
        ArchiveFile.string('payload/libvtk_flutter_core.dylib', 'library'),
        ArchiveFile.string('payload/NOTICE.txt', 'notice'),
      ],
    );

    final result = await extractLibraryFromZip(
      archiveFile: archive,
      outputDirectory: outputDirectory,
      libraryFileName: 'libvtk_flutter_core.dylib',
    );

    expect(result.path, endsWith('libvtk_flutter_core.dylib'));
    expect(await result.readAsString(), 'library');
    expect(
      await File(
        '${outputDirectory.path}${Platform.pathSeparator}NOTICE.txt',
      ).exists(),
      isFalse,
    );
  });

  test('rejects path traversal even in an unextracted entry', () async {
    final archive = await _writeZip(
      temporaryDirectory: temporaryDirectory,
      entries: [
        ArchiveFile.string('libvtk_flutter_core.dylib', 'library'),
        ArchiveFile.string('../escape.txt', 'escape'),
      ],
    );

    await expectLater(
      extractLibraryFromZip(
        archiveFile: archive,
        outputDirectory: outputDirectory,
        libraryFileName: 'libvtk_flutter_core.dylib',
      ),
      throwsFormatException,
    );
    expect(
      await File('${temporaryDirectory.parent.path}/escape.txt').exists(),
      isFalse,
    );
  });

  test('rejects symbolic links', () async {
    final archive = await _writeZip(
      temporaryDirectory: temporaryDirectory,
      markEntriesAsUnix: true,
      entries: [
        ArchiveFile.string('libvtk_flutter_core.dylib', 'library'),
        ArchiveFile.string('payload/link', '../outside')..mode = 0xa1ff,
      ],
    );

    await expectLater(
      extractLibraryFromZip(
        archiveFile: archive,
        outputDirectory: outputDirectory,
        libraryFileName: 'libvtk_flutter_core.dylib',
      ),
      throwsFormatException,
    );
  });

  test('rejects missing and duplicate library payloads', () async {
    final missing = await _writeZip(
      temporaryDirectory: temporaryDirectory,
      fileName: 'missing.zip',
      entries: [ArchiveFile.string('README.txt', 'missing')],
    );
    final duplicate = await _writeZip(
      temporaryDirectory: temporaryDirectory,
      fileName: 'duplicate.zip',
      entries: [
        ArchiveFile.string('one/libvtk_flutter_core.dylib', 'one'),
        ArchiveFile.string('two/libvtk_flutter_core.dylib', 'two'),
      ],
    );

    for (final archive in [missing, duplicate]) {
      await expectLater(
        extractLibraryFromZip(
          archiveFile: archive,
          outputDirectory: outputDirectory,
          libraryFileName: 'libvtk_flutter_core.dylib',
        ),
        throwsFormatException,
      );
    }
  });
}

Future<File> _writeZip({
  required Directory temporaryDirectory,
  required List<ArchiveFile> entries,
  String fileName = 'artifact.zip',
  bool markEntriesAsUnix = false,
}) async {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  final bytes = ZipEncoder().encode(archive);
  if (markEntriesAsUnix) {
    for (var index = 0; index < bytes.length - 5; index++) {
      final isCentralDirectoryEntry =
          bytes[index] == 0x50 &&
          bytes[index + 1] == 0x4b &&
          bytes[index + 2] == 0x01 &&
          bytes[index + 3] == 0x02;
      if (isCentralDirectoryEntry) bytes[index + 5] = 3;
    }
  }
  final file = File(
    '${temporaryDirectory.path}${Platform.pathSeparator}$fileName',
  );
  await file.writeAsBytes(bytes);
  return file;
}
