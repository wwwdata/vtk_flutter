import 'dart:async';
import 'dart:io';

const vtkVersion = '9.6.2';
const vtkBuildParallelJobs = '10';
const vtkArchiveSha256 =
    'aed12cec12a9609179bf66329070266627ca64244a10856a452b2a17ffb04a1d';
const vtkArchiveUrl =
    'https://vtk.org/files/release/9.6/VTK-$vtkVersion.tar.gz';

const supportedPlatforms = <String>{
  'macos-arm64',
  'macos-x64',
  'ios-arm64',
  'ios-simulator-arm64',
  'ios-simulator-x64',
  'android-arm64',
  'android-armeabi-v7a',
  'android-x86_64',
  'windows-x64',
};

const vtkModules = <String>[
  'CommonCore',
  'CommonDataModel',
  'FiltersCore',
  'ImagingColor',
  'ImagingCore',
  'RenderingCore',
  'RenderingOpenGL2',
  'RenderingVolumeOpenGL2',
  'SerializationManager',
];

const _moduleGroups = <String>[
  'Imaging',
  'MPI',
  'Qt',
  'Rendering',
  'StandAlone',
  'Views',
  'Web',
];

const _usage =
    '''
Bootstrap VTK $vtkVersion for vtk_flutter.

Usage:
  dart tool/bootstrap_vtk.dart --platform <target> [options]

Targets:
  macos-arm64
  macos-x64
  ios-arm64
  ios-simulator-arm64
  ios-simulator-x64
  android-arm64
  android-armeabi-v7a
  android-x86_64
  windows-x64

Options:
  --source-dir <path>  Use an existing VTK $vtkVersion source tree.
  --dry-run            Print the work without downloading or building.
  -h, --help           Show this help.

The default cache is .dart_tool/vtk/$vtkVersion/<target>.
''';

Future<void> main(List<String> arguments) async {
  try {
    final parsed = BootstrapArguments.parse(arguments);
    if (parsed.showHelp) {
      stdout.write(_usage);
      return;
    }

    await VtkBootstrapper(options: parsed.options!).run();
  } on UsageException catch (error) {
    stderr.writeln('Error: ${error.message}\n');
    stderr.write(_usage);
    exitCode = 64;
  } on Object catch (error) {
    stderr.writeln('Error: $error');
    exitCode = 1;
  }
}

final class UsageException implements Exception {
  const UsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class BootstrapArguments {
  const BootstrapArguments._({this.options, required this.showHelp});

  final BootstrapOptions? options;
  final bool showHelp;

  static BootstrapArguments parse(List<String> arguments) {
    String? platform;
    String? sourceDirectory;
    var dryRun = false;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--help' || argument == '-h') {
        return const BootstrapArguments._(showHelp: true);
      }
      if (argument == '--dry-run') {
        dryRun = true;
        continue;
      }
      if (argument == '--platform' || argument == '--source-dir') {
        if (index + 1 >= arguments.length) {
          throw UsageException('Missing value for $argument.');
        }
        final value = arguments[++index];
        if (value.startsWith('-')) {
          throw UsageException('Missing value for $argument.');
        }
        if (argument == '--platform') {
          platform = value;
        } else {
          sourceDirectory = value;
        }
        continue;
      }
      if (argument.startsWith('--platform=')) {
        platform = argument.substring('--platform='.length);
        continue;
      }
      if (argument.startsWith('--source-dir=')) {
        sourceDirectory = argument.substring('--source-dir='.length);
        continue;
      }
      throw UsageException('Unknown argument: $argument');
    }

    if (platform == null || platform.isEmpty) {
      throw const UsageException('--platform is required.');
    }
    if (!supportedPlatforms.contains(platform)) {
      throw UsageException(
        'Unsupported platform "$platform". Expected one of: '
        '${supportedPlatforms.join(', ')}.',
      );
    }
    if (sourceDirectory?.isEmpty ?? false) {
      throw const UsageException('--source-dir must not be empty.');
    }

    return BootstrapArguments._(
      options: BootstrapOptions(
        platform: platform,
        sourceDirectory: sourceDirectory,
        dryRun: dryRun,
      ),
      showHelp: false,
    );
  }
}

final class BootstrapOptions {
  const BootstrapOptions({
    required this.platform,
    required this.sourceDirectory,
    required this.dryRun,
  });

  final String platform;
  final String? sourceDirectory;
  final bool dryRun;
}

final class CmakeCommand {
  const CmakeCommand({required this.arguments, this.workingDirectory});

  final List<String> arguments;
  final String? workingDirectory;
}

List<CmakeCommand> createBuildPlan({
  required BootstrapOptions options,
  required String sourceDirectory,
  required String cacheDirectory,
  String? androidNdkDirectory,
  String compileToolsVersionFile =
      'native/cmake/vtkcompiletools-config-version.cmake',
}) {
  final buildDirectory = _join([cacheDirectory, 'build']);
  final installDirectory = _join([cacheDirectory, 'install']);
  final commands = <CmakeCommand>[];
  String? compileToolsDirectory;

  if (_isMobile(options.platform)) {
    compileToolsDirectory = _join([cacheDirectory, 'host-tools']);
    commands.add(
      CmakeCommand(
        arguments: [
          '-S',
          sourceDirectory,
          '-B',
          compileToolsDirectory,
          '-DCMAKE_BUILD_TYPE=Release',
          '-DVTK_BUILD_COMPILE_TOOLS_ONLY=ON',
          '-DVTK_BUILD_ALL_MODULES=OFF',
          '-DVTK_BUILD_EXAMPLES=OFF',
          '-DVTK_BUILD_TESTING=OFF',
          '-DVTK_ENABLE_WRAPPING=ON',
          '-DVTK_WRAP_SERIALIZATION=ON',
          '-DBUILD_SHARED_LIBS=ON',
        ],
      ),
    );
    commands.add(
      CmakeCommand(
        arguments: [
          '-E',
          'copy_if_different',
          compileToolsVersionFile,
          _join([
            compileToolsDirectory,
            'vtkcompiletools-config-version.cmake',
          ]),
        ],
      ),
    );
    commands.add(
      CmakeCommand(
        arguments: ['--build', compileToolsDirectory, '--config', 'Release'],
      ),
    );
  }

  final configureArguments = <String>[
    '-S',
    sourceDirectory,
    '-B',
    buildDirectory,
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_INSTALL_PREFIX=$installDirectory',
    '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
    '-DBUILD_SHARED_LIBS=OFF',
    '-DVTK_BUILD_ALL_MODULES=OFF',
    '-DVTK_BUILD_DOCUMENTATION=OFF',
    '-DVTK_BUILD_EXAMPLES=OFF',
    '-DVTK_BUILD_TESTING=OFF',
    '-DVTK_ENABLE_LOGGING=OFF',
    '-DVTK_ENABLE_REMOTE_MODULES=OFF',
    '-DVTK_ENABLE_WRAPPING=ON',
    '-DVTK_WRAP_SERIALIZATION=ON',
    '-DVTK_USE_CUDA=OFF',
    '-DVTK_USE_MPI=OFF',
    for (final group in _moduleGroups) '-DVTK_GROUP_ENABLE_$group=DONT_WANT',
    for (final module in vtkModules) '-DVTK_MODULE_ENABLE_VTK_$module=YES',
    if (compileToolsDirectory != null)
      '-DVTKCompileTools_DIR=$compileToolsDirectory',
    ..._platformCmakeArguments(
      platform: options.platform,
      androidNdkDirectory: androidNdkDirectory,
    ),
  ];

  commands.add(CmakeCommand(arguments: configureArguments));
  commands.add(
    CmakeCommand(
      arguments: [
        '--build',
        buildDirectory,
        '--config',
        'Release',
        '--parallel',
        vtkBuildParallelJobs,
      ],
    ),
  );
  commands.add(
    CmakeCommand(
      arguments: ['--install', buildDirectory, '--config', 'Release'],
    ),
  );
  return commands;
}

List<String> _platformCmakeArguments({
  required String platform,
  required String? androidNdkDirectory,
}) => switch (platform) {
  'macos-arm64' => [
    '-DCMAKE_OSX_ARCHITECTURES=arm64',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0',
  ],
  'macos-x64' => [
    '-DCMAKE_OSX_ARCHITECTURES=x86_64',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0',
  ],
  'ios-arm64' => [
    '-DCMAKE_SYSTEM_NAME=iOS',
    '-DCMAKE_MACOSX_BUNDLE=OFF',
    '-DAPPLE_IOS=ON',
    '-DTARGET_OS_IPHONE=ON',
    '-DCMAKE_OSX_ARCHITECTURES=arm64',
    '-DCMAKE_OSX_SYSROOT=iphoneos',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0',
  ],
  'ios-simulator-arm64' => [
    '-DCMAKE_SYSTEM_NAME=iOS',
    '-DCMAKE_MACOSX_BUNDLE=OFF',
    '-DAPPLE_IOS=ON',
    '-DTARGET_IPHONE_SIMULATOR=ON',
    '-DCMAKE_OSX_ARCHITECTURES=arm64',
    '-DCMAKE_OSX_SYSROOT=iphonesimulator',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0',
  ],
  'ios-simulator-x64' => [
    '-DCMAKE_SYSTEM_NAME=iOS',
    '-DCMAKE_MACOSX_BUNDLE=OFF',
    '-DAPPLE_IOS=ON',
    '-DTARGET_IPHONE_SIMULATOR=ON',
    '-DCMAKE_OSX_ARCHITECTURES=x86_64',
    '-DCMAKE_OSX_SYSROOT=iphonesimulator',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0',
  ],
  'android-arm64' => [
    '-DCMAKE_TOOLCHAIN_FILE=${_join([androidNdkDirectory ?? '<android-ndk>', 'build', 'cmake', 'android.toolchain.cmake'])}',
    '-DANDROID_ABI=arm64-v8a',
    '-DANDROID_PLATFORM=android-27',
    '-DANDROID_STL=c++_static',
  ],
  'android-armeabi-v7a' => [
    '-DCMAKE_TOOLCHAIN_FILE=${_join([androidNdkDirectory ?? '<android-ndk>', 'build', 'cmake', 'android.toolchain.cmake'])}',
    '-DANDROID_ABI=armeabi-v7a',
    '-DANDROID_PLATFORM=android-27',
    '-DANDROID_STL=c++_static',
  ],
  'android-x86_64' => [
    '-DCMAKE_TOOLCHAIN_FILE=${_join([androidNdkDirectory ?? '<android-ndk>', 'build', 'cmake', 'android.toolchain.cmake'])}',
    '-DANDROID_ABI=x86_64',
    '-DANDROID_PLATFORM=android-27',
    '-DANDROID_STL=c++_static',
  ],
  'windows-x64' => ['-A', 'x64'],
  _ => throw UsageException('Unsupported platform "$platform".'),
};

final class VtkBootstrapper {
  VtkBootstrapper({required this.options, Directory? workingDirectory})
    : workingDirectory = workingDirectory ?? Directory.current;

  final BootstrapOptions options;
  final Directory workingDirectory;

  Future<void> run() async {
    final packageDirectory = _findPackageDirectory(workingDirectory);
    final cacheDirectory = Directory(
      _join([
        packageDirectory.path,
        '.dart_tool',
        'vtk',
        vtkVersion,
        options.platform,
      ]),
    ).absolute;
    final sourceDirectory = options.sourceDirectory == null
        ? Directory(_join([cacheDirectory.path, 'source'])).absolute
        : Directory(options.sourceDirectory!).absolute;

    String? androidNdkDirectory;
    if (options.platform.startsWith('android-')) {
      androidNdkDirectory = _findAndroidNdk()?.path;
      if (androidNdkDirectory == null && !options.dryRun) {
        throw StateError(
          'Android NDK not found. Set ANDROID_NDK_HOME, ANDROID_NDK_ROOT, '
          'ANDROID_NDK, ANDROID_HOME, or ANDROID_SDK_ROOT.',
        );
      }
    }

    final plan = createBuildPlan(
      options: options,
      sourceDirectory: sourceDirectory.path,
      cacheDirectory: cacheDirectory.path,
      androidNdkDirectory: androidNdkDirectory,
      compileToolsVersionFile: _join([
        packageDirectory.path,
        'native',
        'cmake',
        'vtkcompiletools-config-version.cmake',
      ]),
    );

    stdout.writeln('VTK target: ${options.platform}');
    stdout.writeln('Cache: ${cacheDirectory.path}');
    stdout.writeln('Source: ${sourceDirectory.path}');

    if (options.dryRun) {
      if (options.sourceDirectory == null) {
        stdout.writeln('Would download $vtkArchiveUrl');
        stdout.writeln('Would verify SHA-256 $vtkArchiveSha256');
      }
      if (options.platform.startsWith('ios-')) {
        stdout.writeln('Would apply the VTK 9.6.2 iOS pointer type fix.');
      }
      if (options.platform.startsWith('android-')) {
        stdout.writeln('Would apply the VTK 9.6.2 compile-tools target fix.');
      }
      for (final command in plan) {
        _printCommand(command);
      }
      return;
    }

    _validateHost();
    await _run(const CmakeCommand(arguments: ['--version']));
    await cacheDirectory.create(recursive: true);

    if (options.sourceDirectory == null) {
      await _ensureDownloadedSource(
        cacheDirectory: cacheDirectory,
        sourceDirectory: sourceDirectory,
      );
    } else {
      validateVtkSourceDirectory(sourceDirectory);
    }
    if (options.platform.startsWith('ios-')) {
      applyVtkIosPointerTypeFix(sourceDirectory);
    }
    if (options.platform.startsWith('android-')) {
      applyVtkCompileToolsTargetFix(sourceDirectory);
    }

    for (final command in plan) {
      await _run(command);
    }

    stdout.writeln(
      'Installed VTK $vtkVersion to ${_join([cacheDirectory.path, 'install'])}',
    );
  }

  void _validateHost() {
    final target = options.platform;
    if ((target.startsWith('macos-') || target.startsWith('ios-')) &&
        !Platform.isMacOS) {
      throw StateError('$target must be built on macOS.');
    }
    if (target.startsWith('windows-') && !Platform.isWindows) {
      throw StateError('$target must be built on Windows.');
    }
  }

  Future<void> _ensureDownloadedSource({
    required Directory cacheDirectory,
    required Directory sourceDirectory,
  }) async {
    if (File(_join([sourceDirectory.path, 'CMakeLists.txt'])).existsSync()) {
      try {
        validateVtkSourceDirectory(sourceDirectory);
        return;
      } on StateError {
        await sourceDirectory.delete(recursive: true);
      }
    }

    final archive = File(
      _join([cacheDirectory.path, 'VTK-$vtkVersion.tar.gz']),
    );
    if (archive.existsSync() && !await _hasExpectedSha256(archive)) {
      await archive.delete();
    }
    if (!archive.existsSync()) {
      stdout.writeln('Downloading $vtkArchiveUrl');
      await _download(Uri.parse(vtkArchiveUrl), archive);
    }
    if (!await _hasExpectedSha256(archive)) {
      await archive.delete();
      throw StateError('Downloaded VTK archive failed SHA-256 verification.');
    }

    final extractionDirectory = Directory(
      _join([cacheDirectory.path, 'extract.tmp']),
    );
    if (extractionDirectory.existsSync()) {
      await extractionDirectory.delete(recursive: true);
    }
    await extractionDirectory.create(recursive: true);

    try {
      await _run(
        CmakeCommand(
          arguments: ['-E', 'tar', 'xzf', archive.path],
          workingDirectory: extractionDirectory.path,
        ),
      );
      final extractedSource = Directory(
        _join([extractionDirectory.path, 'VTK-$vtkVersion']),
      );
      validateVtkSourceDirectory(extractedSource);
      if (sourceDirectory.existsSync()) {
        await sourceDirectory.delete(recursive: true);
      }
      await extractedSource.rename(sourceDirectory.path);
    } finally {
      if (extractionDirectory.existsSync()) {
        await extractionDirectory.delete(recursive: true);
      }
    }
  }

  Future<bool> _hasExpectedSha256(File archive) async {
    final result = await Process.run('cmake', [
      '-E',
      'sha256sum',
      archive.path,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'cmake',
        ['-E', 'sha256sum', archive.path],
        result.stderr.toString(),
        result.exitCode,
      );
    }
    final actual = result.stdout.toString().trim().split(RegExp(r'\s+')).first;
    return actual.toLowerCase() == vtkArchiveSha256;
  }

  Future<void> _run(CmakeCommand command) async {
    _printCommand(command);
    final process = await Process.start(
      'cmake',
      command.arguments,
      workingDirectory: command.workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    final result = await process.exitCode;
    if (result != 0) {
      throw ProcessException('cmake', command.arguments, '', result);
    }
  }
}

void validateVtkSourceDirectory(Directory sourceDirectory) {
  final cmakeLists = File(_join([sourceDirectory.path, 'CMakeLists.txt']));
  if (!cmakeLists.existsSync()) {
    throw StateError(
      '${sourceDirectory.path} is not a VTK source tree: CMakeLists.txt missing.',
    );
  }

  final versionFile = File(
    _join([sourceDirectory.path, 'CMake', 'vtkVersion.cmake']),
  );
  if (!versionFile.existsSync()) {
    throw StateError(
      '${sourceDirectory.path} is not a VTK source tree: '
      'CMake/vtkVersion.cmake missing.',
    );
  }
  final contents = versionFile.readAsStringSync();
  final components = <String>[];
  for (final name in const ['MAJOR', 'MINOR', 'BUILD']) {
    final match = RegExp(
      r'set\(VTK_' + name + r'_VERSION\s+([0-9]+)\s*\)',
    ).firstMatch(contents);
    if (match == null) {
      throw StateError(
        'Could not determine VTK version in ${versionFile.path}.',
      );
    }
    components.add(match.group(1)!);
  }
  final actualVersion = components.join('.');
  if (actualVersion != vtkVersion) {
    throw StateError(
      'Expected VTK $vtkVersion sources, found VTK $actualVersion in '
      '${sourceDirectory.path}.',
    );
  }
}

void applyVtkIosPointerTypeFix(Directory sourceDirectory) {
  final sourceFile = File(
    _join([
      sourceDirectory.path,
      'Rendering',
      'OpenGL2',
      'vtkIOSRenderWindow.mm',
    ]),
  );
  if (!sourceFile.existsSync()) {
    throw StateError(
      '${sourceFile.path} is missing; cannot apply the VTK $vtkVersion '
      'iOS pointer type fix.',
    );
  }

  const invalidDeclaration = '  uptrdiff_t tmp = 0;';
  const correctedDeclaration = '  uintptr_t tmp = 0;';
  final contents = sourceFile.readAsStringSync();
  final invalidCount = invalidDeclaration.allMatches(contents).length;
  final correctedCount = correctedDeclaration.allMatches(contents).length;
  if (invalidCount == 0 && correctedCount == 2) {
    return;
  }
  if (invalidCount != 2 || correctedCount != 0) {
    throw StateError(
      'Unexpected vtkIOSRenderWindow.mm contents for VTK $vtkVersion: '
      'found $invalidCount invalid and $correctedCount corrected pointer '
      'declarations.',
    );
  }

  sourceFile.writeAsStringSync(
    contents.replaceAll(invalidDeclaration, correctedDeclaration),
  );
}

void applyVtkCompileToolsTargetFix(Directory sourceDirectory) {
  final templateFile = File(
    _join([sourceDirectory.path, 'CMake', 'vtkcompiletools-config.cmake.in']),
  );
  if (!templateFile.existsSync()) {
    throw StateError(
      '${templateFile.path} is missing; cannot apply the VTK $vtkVersion '
      'compile-tools target fix.',
    );
  }

  const original = '''
    separate_arguments(_compile_tools_flags NATIVE_COMMAND "\${CMAKE_CXX_FLAGS}")

    # Add a custom command and target to generate the macro headers.
''';
  const corrected = '''
    separate_arguments(_compile_tools_flags NATIVE_COMMAND "\${CMAKE_CXX_FLAGS}")
    if (CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND
        CMAKE_CXX_COMPILER_TARGET)
      list(INSERT _compile_tools_flags 0
        "--target=\${CMAKE_CXX_COMPILER_TARGET}")
    endif ()

    # Add a custom command and target to generate the macro headers.
''';
  final contents = templateFile.readAsStringSync();
  final originalCount = original.allMatches(contents).length;
  final correctedCount = corrected.allMatches(contents).length;
  if (originalCount == 0 && correctedCount == 1) {
    return;
  }
  if (originalCount != 1 || correctedCount != 0) {
    throw StateError(
      'Unexpected vtkcompiletools-config.cmake.in contents for VTK '
      '$vtkVersion: found $originalCount original and $correctedCount '
      'corrected command blocks.',
    );
  }

  templateFile.writeAsStringSync(contents.replaceFirst(original, corrected));
}

Future<void> _download(Uri uri, File destination) async {
  final temporary = File('${destination.path}.part');
  if (temporary.existsSync()) {
    await temporary.delete();
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'vtk_flutter bootstrap');
    final response = await request.close().timeout(const Duration(minutes: 2));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Download failed with HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    await response
        .pipe(temporary.openWrite())
        .timeout(const Duration(minutes: 10));
    if (destination.existsSync()) {
      await destination.delete();
    }
    await temporary.rename(destination.path);
  } finally {
    client.close(force: true);
    if (temporary.existsSync()) {
      await temporary.delete();
    }
  }
}

Directory? _findAndroidNdk() {
  for (final variable in const [
    'ANDROID_NDK_HOME',
    'ANDROID_NDK_ROOT',
    'ANDROID_NDK',
  ]) {
    final value = Platform.environment[variable];
    if (value != null && _isAndroidNdk(Directory(value))) {
      return Directory(value).absolute;
    }
  }

  for (final variable in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
    final sdkPath = Platform.environment[variable];
    if (sdkPath == null) {
      continue;
    }
    final ndkRoot = Directory(_join([sdkPath, 'ndk']));
    if (!ndkRoot.existsSync()) {
      continue;
    }
    final candidates =
        ndkRoot.listSync().whereType<Directory>().where(_isAndroidNdk).toList()
          ..sort((left, right) => right.path.compareTo(left.path));
    if (candidates.isNotEmpty) {
      return candidates.first.absolute;
    }
  }
  return null;
}

bool _isAndroidNdk(Directory directory) => File(
  _join([directory.path, 'build', 'cmake', 'android.toolchain.cmake']),
).existsSync();

Directory _findPackageDirectory(Directory start) {
  var current = start.absolute;
  while (true) {
    if (File(_join([current.path, 'pubspec.yaml'])).existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      return start.absolute;
    }
    current = parent;
  }
}

bool _isMobile(String platform) =>
    platform.startsWith('ios-') || platform.startsWith('android-');

String _join(List<String> parts) => parts.join(Platform.pathSeparator);

void _printCommand(CmakeCommand command) {
  if (command.workingDirectory != null) {
    stdout.writeln('In ${command.workingDirectory}:');
  }
  stdout.writeln(r'$ cmake ' + command.arguments.map(_quote).join(' '));
}

String _quote(String argument) {
  if (!argument.contains(RegExp(r'''[\s"']'''))) {
    return argument;
  }
  return '"${argument.replaceAll('"', r'\"')}"';
}
