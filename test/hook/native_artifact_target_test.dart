import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/src/native_artifact_target.dart';

void main() {
  final supportedTargets =
      <
        ({
          OS operatingSystem,
          Architecture architecture,
          IOSSdk? appleSdk,
          String key,
          String archiveName,
          String libraryFileName,
          String? androidAbi,
        })
      >[
        (
          operatingSystem: OS.macOS,
          architecture: Architecture.arm64,
          appleSdk: null,
          key: 'macos-arm64',
          archiveName: 'vtk_flutter-native-macos-arm64.zip',
          libraryFileName: 'libvtk_flutter_core.dylib',
          androidAbi: null,
        ),
        (
          operatingSystem: OS.macOS,
          architecture: Architecture.x64,
          appleSdk: null,
          key: 'macos-x64',
          archiveName: 'vtk_flutter-native-macos-x64.zip',
          libraryFileName: 'libvtk_flutter_core.dylib',
          androidAbi: null,
        ),
        (
          operatingSystem: OS.iOS,
          architecture: Architecture.arm64,
          appleSdk: IOSSdk.iPhoneOS,
          key: 'ios-arm64',
          archiveName: 'vtk_flutter-native-ios-arm64.zip',
          libraryFileName: 'libvtk_flutter_core.dylib',
          androidAbi: null,
        ),
        (
          operatingSystem: OS.iOS,
          architecture: Architecture.arm64,
          appleSdk: IOSSdk.iPhoneSimulator,
          key: 'ios-simulator-arm64',
          archiveName: 'vtk_flutter-native-ios-simulator-arm64.zip',
          libraryFileName: 'libvtk_flutter_core.dylib',
          androidAbi: null,
        ),
        (
          operatingSystem: OS.iOS,
          architecture: Architecture.x64,
          appleSdk: IOSSdk.iPhoneSimulator,
          key: 'ios-simulator-x64',
          archiveName: 'vtk_flutter-native-ios-simulator-x64.zip',
          libraryFileName: 'libvtk_flutter_core.dylib',
          androidAbi: null,
        ),
        (
          operatingSystem: OS.android,
          architecture: Architecture.arm64,
          appleSdk: null,
          key: 'android-arm64',
          archiveName: 'vtk_flutter-native-android-arm64.zip',
          libraryFileName: 'libvtk_flutter_core.so',
          androidAbi: 'arm64-v8a',
        ),
        (
          operatingSystem: OS.android,
          architecture: Architecture.arm,
          appleSdk: null,
          key: 'android-armeabi-v7a',
          archiveName: 'vtk_flutter-native-android-armeabi-v7a.zip',
          libraryFileName: 'libvtk_flutter_core.so',
          androidAbi: 'armeabi-v7a',
        ),
        (
          operatingSystem: OS.android,
          architecture: Architecture.x64,
          appleSdk: null,
          key: 'android-x86_64',
          archiveName: 'vtk_flutter-native-android-x86_64.zip',
          libraryFileName: 'libvtk_flutter_core.so',
          androidAbi: 'x86_64',
        ),
        (
          operatingSystem: OS.windows,
          architecture: Architecture.x64,
          appleSdk: null,
          key: 'windows-x64',
          archiveName: 'vtk_flutter-native-windows-x64.zip',
          libraryFileName: 'vtk_flutter_core.dll',
          androidAbi: null,
        ),
      ];

  for (final expected in supportedTargets) {
    test('maps ${expected.key} to its release artifact', () {
      final target = NativeArtifactTarget.resolve(
        operatingSystem: expected.operatingSystem,
        architecture: expected.architecture,
        appleSdk: expected.appleSdk,
      );

      expect(target.key, expected.key);
      expect(target.archiveName, expected.archiveName);
      expect(target.libraryFileName, expected.libraryFileName);
      expect(target.androidAbi, expected.androidAbi);
      expect(target.appleSdk, expected.appleSdk);
    });
  }

  test('rejects unsupported OS, architecture, and Apple SDK combinations', () {
    final unsupportedTargets =
        <({OS operatingSystem, Architecture architecture, IOSSdk? appleSdk})>[
          (
            operatingSystem: OS.linux,
            architecture: Architecture.x64,
            appleSdk: null,
          ),
          (
            operatingSystem: OS.windows,
            architecture: Architecture.arm64,
            appleSdk: null,
          ),
          (
            operatingSystem: OS.iOS,
            architecture: Architecture.x64,
            appleSdk: IOSSdk.iPhoneOS,
          ),
          (
            operatingSystem: OS.android,
            architecture: Architecture.ia32,
            appleSdk: null,
          ),
        ];

    for (final target in unsupportedTargets) {
      expect(
        () => NativeArtifactTarget.resolve(
          operatingSystem: target.operatingSystem,
          architecture: target.architecture,
          appleSdk: target.appleSdk,
        ),
        throwsA(isA<UnsupportedNativeArtifactTarget>()),
      );
    }
  });
}
