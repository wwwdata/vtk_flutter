import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/bootstrap_vtk.dart';

void main() {
  group('BootstrapArguments', () {
    test('parses the platform, source directory, and dry-run', () {
      final parsed = BootstrapArguments.parse([
        '--platform=ios-arm64',
        '--source-dir',
        'vtk-source',
        '--dry-run',
      ]);

      expect(parsed.showHelp, isFalse);
      expect(parsed.options?.platform, 'ios-arm64');
      expect(parsed.options?.sourceDirectory, 'vtk-source');
      expect(parsed.options?.dryRun, isTrue);
    });

    test('accepts every approved target', () {
      for (final platform in supportedPlatforms) {
        final parsed = BootstrapArguments.parse(['--platform', platform]);

        expect(parsed.options?.platform, platform);
      }
    });

    test('rejects a missing platform', () {
      expect(
        () => BootstrapArguments.parse(const []),
        throwsA(isA<UsageException>()),
      );
    });

    test('rejects an unsupported platform', () {
      expect(
        () => BootstrapArguments.parse(const ['--platform', 'linux-x64']),
        throwsA(isA<UsageException>()),
      );
    });
  });

  group('createBuildPlan', () {
    const sourceDirectory = '/vtk/source';
    const cacheDirectory = '/cache';

    test('selects exactly the approved explicit VTK modules', () {
      final plan = createBuildPlan(
        options: const BootstrapOptions(
          platform: 'macos-arm64',
          sourceDirectory: null,
          dryRun: true,
        ),
        sourceDirectory: sourceDirectory,
        cacheDirectory: cacheDirectory,
      );
      final configuredModules = plan.first.arguments
          .where((argument) => argument.startsWith('-DVTK_MODULE_ENABLE_VTK_'))
          .toSet();

      expect(
        configuredModules,
        vtkModules
            .map((module) => '-DVTK_MODULE_ENABLE_VTK_$module=YES')
            .toSet(),
      );
      expect(plan.first.arguments, contains('-DVTK_ENABLE_WRAPPING=ON'));
      expect(plan.first.arguments, contains('-DVTK_WRAP_SERIALIZATION=ON'));
    });

    test('prepares host tools before an iOS cross-build', () {
      final plan = createBuildPlan(
        options: const BootstrapOptions(
          platform: 'ios-simulator-arm64',
          sourceDirectory: null,
          dryRun: true,
        ),
        sourceDirectory: sourceDirectory,
        cacheDirectory: cacheDirectory,
      );

      expect(plan, hasLength(6));
      expect(
        plan.first.arguments,
        contains('-DVTK_BUILD_COMPILE_TOOLS_ONLY=ON'),
      );
      expect(plan.first.arguments, contains('-DVTK_ENABLE_WRAPPING=ON'));
      expect(plan.first.arguments, contains('-DVTK_WRAP_SERIALIZATION=ON'));
      expect(
        plan[1].arguments,
        containsAllInOrder([
          '-E',
          'copy_if_different',
          'native/cmake/vtkcompiletools-config-version.cmake',
          _path('/cache', 'host-tools', 'vtkcompiletools-config-version.cmake'),
        ]),
      );
      expect(plan[2].arguments.first, '--build');
      expect(
        plan[3].arguments,
        contains('-DCMAKE_OSX_SYSROOT=iphonesimulator'),
      );
      expect(plan[3].arguments, contains('-DCMAKE_MACOSX_BUNDLE=OFF'));
      expect(plan[3].arguments, contains('-DAPPLE_IOS=ON'));
      expect(plan[3].arguments, contains('-DTARGET_IPHONE_SIMULATOR=ON'));
      expect(
        plan[3].arguments,
        contains('-DVTKCompileTools_DIR=${_path('/cache', 'host-tools')}'),
      );
    });

    test('uses the Android NDK arm64 toolchain', () {
      final plan = createBuildPlan(
        options: const BootstrapOptions(
          platform: 'android-arm64',
          sourceDirectory: null,
          dryRun: true,
        ),
        sourceDirectory: sourceDirectory,
        cacheDirectory: cacheDirectory,
        androidNdkDirectory: '/android/ndk',
      );
      final configure = plan[3].arguments;

      expect(
        configure,
        contains(
          '-DCMAKE_TOOLCHAIN_FILE=${_path('/android/ndk', 'build', 'cmake', 'android.toolchain.cmake')}',
        ),
      );
      expect(configure, contains('-DANDROID_ABI=arm64-v8a'));
      expect(configure, contains('-DANDROID_PLATFORM=android-27'));
    });

    test('maps every additional architecture to its native toolchain', () {
      final cases = <String, String>{
        'macos-x64': '-DCMAKE_OSX_ARCHITECTURES=x86_64',
        'ios-simulator-x64': '-DCMAKE_OSX_ARCHITECTURES=x86_64',
        'android-armeabi-v7a': '-DANDROID_ABI=armeabi-v7a',
        'android-x86_64': '-DANDROID_ABI=x86_64',
      };

      for (final MapEntry(key: platform, value: expected) in cases.entries) {
        final plan = createBuildPlan(
          options: BootstrapOptions(
            platform: platform,
            sourceDirectory: null,
            dryRun: true,
          ),
          sourceDirectory: sourceDirectory,
          cacheDirectory: cacheDirectory,
          androidNdkDirectory: '/android/ndk',
        );

        final configureIndex =
            platform.startsWith('android-') || platform.startsWith('ios-')
            ? 3
            : 0;
        expect(plan[configureIndex].arguments, contains(expected));
      }
    });

    test('builds and installs with CMake', () {
      final plan = createBuildPlan(
        options: const BootstrapOptions(
          platform: 'windows-x64',
          sourceDirectory: null,
          dryRun: true,
        ),
        sourceDirectory: sourceDirectory,
        cacheDirectory: cacheDirectory,
      );

      expect(plan, hasLength(3));
      expect(plan.first.arguments, containsAllInOrder(['-A', 'x64']));
      expect(plan[1].arguments.first, '--build');
      expect(
        plan[1].arguments,
        containsAllInOrder(['--parallel', vtkBuildParallelJobs]),
      );
      expect(plan[2].arguments.first, '--install');
    });
  });

  group('validateVtkSourceDirectory', () {
    late Directory sourceDirectory;

    setUp(() {
      sourceDirectory = Directory.systemTemp.createTempSync('vtk-source-test-');
    });

    tearDown(() {
      sourceDirectory.deleteSync(recursive: true);
    });

    test('accepts VTK 9.6.2 sources', () {
      _writeSourceVersion(directory: sourceDirectory, version: '9.6.2');

      expect(
        () => validateVtkSourceDirectory(sourceDirectory),
        returnsNormally,
      );
    });

    test('rejects sources from another VTK version', () {
      _writeSourceVersion(directory: sourceDirectory, version: '9.5.1');

      expect(
        () => validateVtkSourceDirectory(sourceDirectory),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('applyVtkIosPointerTypeFix', () {
    late Directory sourceDirectory;
    late File sourceFile;

    setUp(() {
      sourceDirectory = Directory.systemTemp.createTempSync(
        'vtk-ios-source-test-',
      );
      sourceFile = File(
        _path(
          sourceDirectory.path,
          'Rendering',
          'OpenGL2',
          'vtkIOSRenderWindow.mm',
        ),
      )..createSync(recursive: true);
    });

    tearDown(() {
      sourceDirectory.deleteSync(recursive: true);
    });

    test('corrects both invalid pointer declarations and is idempotent', () {
      sourceFile.writeAsStringSync('''
void SetWindowInfo() {
  uptrdiff_t tmp = 0;
}
void SetParentInfo() {
  uptrdiff_t tmp = 0;
}
''');

      applyVtkIosPointerTypeFix(sourceDirectory);
      applyVtkIosPointerTypeFix(sourceDirectory);

      expect(sourceFile.readAsStringSync(), isNot(contains('uptrdiff_t')));
      expect(
        '  uintptr_t tmp = 0;'.allMatches(sourceFile.readAsStringSync()),
        hasLength(2),
      );
    });

    test('rejects source contents outside the pinned patch contract', () {
      sourceFile.writeAsStringSync('void SetWindowInfo() {}\n');

      expect(
        () => applyVtkIosPointerTypeFix(sourceDirectory),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('compile tools metadata accepts a 32-bit cross-build target', () async {
    final packageDirectory = Directory.systemTemp.createTempSync(
      'vtk-compile-tools-package-test-',
    );
    addTearDown(() => packageDirectory.deleteSync(recursive: true));

    File(
      _path(packageDirectory.path, 'vtkcompiletools-config.cmake'),
    ).writeAsStringSync('set(VTKCompileTools_FOUND TRUE)\n');
    final versionFile = File(
      _path(packageDirectory.path, 'vtkcompiletools-config-version.cmake'),
    );
    versionFile.writeAsStringSync('''
set(PACKAGE_VERSION "$vtkVersion")
if(NOT CMAKE_SIZEOF_VOID_P STREQUAL "8")
  set(PACKAGE_VERSION_UNSUITABLE TRUE)
endif()
''');

    final rejected = await _findCompileToolsPackage(packageDirectory);
    expect(rejected.exitCode, isNot(0));

    versionFile.writeAsStringSync(
      File(
        _path(
          Directory.current.path,
          'native',
          'cmake',
          'vtkcompiletools-config-version.cmake',
        ),
      ).readAsStringSync(),
    );
    final accepted = await _findCompileToolsPackage(packageDirectory);

    expect(
      accepted.exitCode,
      0,
      reason: '${accepted.stdout}\n${accepted.stderr}',
    );
  });
}

String _path(String first, String second, [String? third, String? fourth]) =>
    [first, second, ?third, ?fourth].join(Platform.pathSeparator);

void _writeSourceVersion({
  required Directory directory,
  required String version,
}) {
  final components = version.split('.');
  File(
    _path(directory.path, 'CMakeLists.txt'),
  ).writeAsStringSync('project(VTK)');
  final cmakeDirectory = Directory(_path(directory.path, 'CMake'))
    ..createSync();
  File(_path(cmakeDirectory.path, 'vtkVersion.cmake')).writeAsStringSync('''
set(VTK_MAJOR_VERSION ${components[0]})
set(VTK_MINOR_VERSION ${components[1]})
set(VTK_BUILD_VERSION ${components[2]})
''');
}

Future<ProcessResult> _findCompileToolsPackage(Directory packageDirectory) =>
    Process.run('cmake', [
      '--find-package',
      '-DNAME=VTKCompileTools',
      '-DCOMPILER_ID=GNU',
      '-DLANGUAGE=CXX',
      '-DMODE=EXIST',
      '-DCMAKE_SIZEOF_VOID_P=4',
      '-DVTKCompileTools_DIR=${packageDirectory.path.replaceAll(r'\', '/')}',
    ], workingDirectory: packageDirectory.path);
