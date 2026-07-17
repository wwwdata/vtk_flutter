import 'dart:io';

import 'bootstrap_vtk.dart' show vtkArchiveSha256, vtkArchiveUrl, vtkVersion;

const _outputPath = 'native/THIRD_PARTY_LICENSES.txt';
const _separator =
    '================================================================================';

const _licenses = <({String title, String path, String? target})>[
  (title: 'VTK $vtkVersion', path: 'Copyright.txt', target: null),
  (
    title: 'KWSys',
    path: 'Utilities/KWSys/vtksys/Copyright.txt',
    target: 'vtksys',
  ),
  (
    title: 'KWIML',
    path: 'Utilities/KWIML/vtkkwiml/Copyright.txt',
    target: 'kwiml',
  ),
  (
    title: 'DICOMParser',
    path: 'Utilities/DICOMParser/Copyright.txt',
    target: 'DICOMParser',
  ),
  (
    title: 'MetaIO',
    path: 'Utilities/MetaIO/vtkmetaio/License.txt',
    target: 'metaio',
  ),
  (
    title: 'exprtk',
    path: 'ThirdParty/exprtk/vtkexprtk/license.txt',
    target: 'exprtk',
  ),
  (
    title: 'fast_float',
    path: 'ThirdParty/fast_float/vtkfast_float/LICENSE-MIT',
    target: 'fast_float',
  ),
  (title: 'fmt', path: 'ThirdParty/fmt/vtkfmt/LICENSE', target: 'fmt'),
  (
    title: 'FreeType license overview',
    path: 'ThirdParty/freetype/vtkfreetype/LICENSE.TXT',
    target: 'freetype',
  ),
  (
    title: 'FreeType License',
    path: 'ThirdParty/freetype/vtkfreetype/docs/FTL.TXT',
    target: 'freetype',
  ),
  (title: 'glad', path: 'ThirdParty/glad/vtkglad/LICENSE', target: 'glad'),
  (title: 'JPEG', path: 'ThirdParty/jpeg/vtkjpeg/LICENSE.md', target: 'jpeg'),
  (
    title: 'KissFFT',
    path: 'ThirdParty/kissfft/vtkkissfft/COPYING',
    target: 'kissfft',
  ),
  (title: 'LZ4', path: 'ThirdParty/lz4/vtklz4/lib/LICENSE', target: 'lz4'),
  (
    title: 'XZ Utils / liblzma',
    path: 'ThirdParty/lzma/vtklzma/COPYING',
    target: 'lzma',
  ),
  (
    title: 'nlohmann/json',
    path: 'ThirdParty/nlohmannjson/vtknlohmannjson/LICENSE.MIT',
    target: 'nlohmannjson',
  ),
  (title: 'PEGTL', path: 'ThirdParty/pegtl/vtkpegtl/LICENSE', target: 'pegtl'),
  (title: 'libpng', path: 'ThirdParty/png/vtkpng/LICENSE', target: 'png'),
  (
    title: 'pugixml',
    path: 'ThirdParty/pugixml/vtkpugixml/LICENSE.md',
    target: 'pugixml',
  ),
  (title: 'scnlib', path: 'ThirdParty/scn/vtkscn/LICENSE', target: 'scn'),
  (
    title: 'nanorange (bundled by scnlib)',
    path: 'ThirdParty/scn/vtkscn/LICENSE.nanorange',
    target: 'scn',
  ),
  (
    title: 'libtiff',
    path: 'ThirdParty/tiff/vtktiff/LICENSE.md',
    target: 'tiff',
  ),
  (
    title: 'token',
    path: 'ThirdParty/token/vtktoken/license.md',
    target: 'token',
  ),
  (title: 'utf8.h', path: 'ThirdParty/utf8/vtkutf8/LICENSE', target: 'utf8'),
  (
    title: 'Verdict',
    path: 'ThirdParty/verdict/vtkverdict/LICENSE',
    target: 'verdict',
  ),
  (title: 'zlib', path: 'ThirdParty/zlib/vtkzlib/LICENSE', target: 'zlib'),
];

Future<void> main(List<String> arguments) async {
  final sourcePath = _option(arguments, '--source');
  final targetsPath = _option(arguments, '--targets');
  final check = arguments.contains('--check');
  final unknown = arguments.where(
    (argument) =>
        argument != '--check' &&
        argument != '--source' &&
        argument != '--targets' &&
        argument != sourcePath &&
        argument != targetsPath &&
        !argument.startsWith('--source=') &&
        !argument.startsWith('--targets='),
  );

  if (sourcePath == null || targetsPath == null || unknown.isNotEmpty) {
    stderr.writeln(
      'Usage: dart tool/generate_native_licenses.dart '
      '--source <VTK source directory> '
      '--targets <VTK-targets.cmake> [--check]',
    );
    exitCode = 64;
    return;
  }

  final source = Directory(sourcePath);
  final targets = File(targetsPath);
  final generated = await _generate(source: source, targets: targets);
  final output = File(_outputPath);

  if (check) {
    if (!output.existsSync() ||
        !nativeLicenseInventoryMatches(
          existing: await output.readAsString(),
          generated: generated,
        )) {
      stderr.writeln(
        '$_outputPath is stale. Regenerate it from the pinned VTK source.',
      );
      exitCode = 1;
    }
    return;
  }

  await output.writeAsString(generated);
}

bool nativeLicenseInventoryMatches({
  required String existing,
  required String generated,
}) {
  return existing.replaceAll('\r\n', '\n') == generated;
}

String? _option(List<String> arguments, String name) {
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == name && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

Future<String> _generate({
  required Directory source,
  required File targets,
}) async {
  if (!source.existsSync()) {
    throw ArgumentError.value(source.path, '--source', 'Directory not found');
  }
  if (!targets.existsSync()) {
    throw ArgumentError.value(targets.path, '--targets', 'File not found');
  }

  final bundledTargets = await _bundledTargets(source: source);
  final installedTargets = RegExp(r'add_library\(VTK::([A-Za-z0-9_]+)')
      .allMatches(await targets.readAsString())
      .map((match) {
        return match.group(1)!;
      })
      .toSet();
  final linkedBundledTargets = bundledTargets.intersection(installedTargets);
  final licensedTargets = _licenses
      .map((license) => license.target)
      .nonNulls
      .toSet();
  final unlicensedTargets = linkedBundledTargets.difference(licensedTargets);
  final unusedLicenses = licensedTargets.difference(linkedBundledTargets);
  if (unlicensedTargets.isNotEmpty || unusedLicenses.isNotEmpty) {
    throw StateError(
      'Native third-party target inventory mismatch. '
      'Missing licenses: ${unlicensedTargets.toList()..sort()}; '
      'not linked: ${unusedLicenses.toList()..sort()}',
    );
  }

  final output = StringBuffer()
    ..writeln('vtk_flutter native third-party licenses')
    ..writeln()
    ..writeln(
      'This file accompanies the monolithic native libraries built from the',
    )
    ..writeln(
      'checksum-pinned VTK $vtkVersion source archive. It reproduces the '
      'license texts for',
    )
    ..writeln(
      'VTK and the bundled third-party components linked into those libraries.',
    )
    ..writeln()
    ..writeln('Upstream archive:')
    ..writeln(vtkArchiveUrl)
    ..writeln()
    ..writeln('Archive SHA-256:')
    ..writeln(vtkArchiveSha256)
    ..writeln()
    ..writeln('Linked bundled VTK targets:')
    ..writeln((linkedBundledTargets.toList()..sort()).join(', '))
    ..writeln();

  for (final license in _licenses) {
    final file = File('${source.path}/${license.path}');
    if (!file.existsSync()) {
      throw StateError('Missing VTK license file: ${license.path}');
    }
    final text = (await file.readAsString())
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trimRight())
        .join('\n')
        .trimRight();
    output
      ..writeln(_separator)
      ..writeln(license.title)
      ..writeln('Source path: ${license.path}')
      ..writeln(_separator)
      ..writeln()
      ..writeln(text)
      ..writeln()
      ..writeln();
  }

  return '${output.toString().trimRight()}\n';
}

Future<Set<String>> _bundledTargets({required Directory source}) async {
  final moduleRoots = [
    (
      directory: Directory('${source.path}/ThirdParty'),
      requireDeclaration: true,
    ),
    (
      directory: Directory('${source.path}/Utilities/KWSys'),
      requireDeclaration: false,
    ),
    (
      directory: Directory('${source.path}/Utilities/KWIML'),
      requireDeclaration: false,
    ),
    (
      directory: Directory('${source.path}/Utilities/DICOMParser'),
      requireDeclaration: false,
    ),
    (
      directory: Directory('${source.path}/Utilities/MetaIO'),
      requireDeclaration: false,
    ),
  ];
  final targets = <String>{};
  for (final root in moduleRoots) {
    await for (final entity in root.directory.list(recursive: true)) {
      if (entity is! File || entity.uri.pathSegments.last != 'vtk.module') {
        continue;
      }
      final contents = await entity.readAsString();
      final declaresThirdParty = RegExp(
        r'^\s*THIRD_PARTY\s*$',
        multiLine: true,
      ).hasMatch(contents);
      if (!declaresThirdParty && root.requireDeclaration) {
        continue;
      }
      final name = RegExp(
        r'^\s*VTK::([A-Za-z0-9_]+)\s*$',
        multiLine: true,
      ).firstMatch(contents)?.group(1);
      if (name == null) {
        throw StateError(
          'Could not read third-party target from ${entity.path}',
        );
      }
      targets.add(name);
    }
  }
  return targets;
}
