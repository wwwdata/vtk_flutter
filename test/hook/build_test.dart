import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as build_hook;
import '../../hook/src/native_artifact_target.dart';

void main() {
  // Consumer pubspec syntax:
  // hooks:
  //   user_defines:
  //     vtk_flutter:
  //       native_artifact: path/to/libvtk_flutter_core.dylib
  test('accepts hooks.user_defines.vtk_flutter.native_artifact and emits a '
      'stable bundled code asset', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'vtk-build-hook-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final localArtifact = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}local-library',
    );
    await localArtifact.writeAsString('local native library');
    final userDefines = PackageUserDefines(
      workspacePubspec: PackageUserDefinesSource(
        defines: {build_hook.nativeArtifactOverrideKey: 'local-library'},
        basePath: temporaryDirectory.uri,
      ),
    );

    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.macOS,
      targetArchitecture: Architecture.arm64,
      userDefines: userDefines,
      check: (input, output) async {
        final asset = output.assets.code.single;
        final file = asset.file;
        expect(asset.id, 'package:vtk_flutter/vtk_flutter_core.dart');
        expect(asset.linkMode, isA<DynamicLoadingBundled>());
        expect(file?.pathSegments.last, 'libvtk_flutter_core.dylib');
        if (file == null) return;
        expect(await File.fromUri(file).readAsString(), 'local native library');
      },
    );
  });

  test(
    'skips Linux portable analysis without downloading an artifact',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.linux,
        targetArchitecture: Architecture.x64,
        check: (input, output) {
          expect(output.assets.code, isEmpty);
        },
      );
    },
  );

  test(
    'fails unsupported architectures on declared native platforms',
    () async {
      await expectLater(
        testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.windows,
          targetArchitecture: Architecture.arm64,
          check: (input, output) {},
        ),
        throwsA(isA<UnsupportedNativeArtifactTarget>()),
      );
    },
  );
}
