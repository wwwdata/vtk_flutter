import 'package:code_assets/code_assets.dart';

import '../../tool/native_artifacts.dart';

final class NativeArtifactTarget {
  const NativeArtifactTarget._({
    required this.key,
    required this.archiveName,
    required this.libraryFileName,
    this.androidAbi,
    this.appleSdk,
  });

  final String key;
  final String archiveName;
  final String libraryFileName;
  final String? androidAbi;
  final IOSSdk? appleSdk;

  static NativeArtifactTarget resolve({
    required OS operatingSystem,
    required Architecture architecture,
    IOSSdk? appleSdk,
  }) {
    final (:key, :libraryFileName, :androidAbi) = switch ((
      operatingSystem,
      architecture,
      appleSdk,
    )) {
      (OS.macOS, Architecture.arm64, null) => (
        key: 'macos-arm64',
        libraryFileName: 'libvtk_flutter_core.dylib',
        androidAbi: null,
      ),
      (OS.macOS, Architecture.x64, null) => (
        key: 'macos-x64',
        libraryFileName: 'libvtk_flutter_core.dylib',
        androidAbi: null,
      ),
      (OS.iOS, Architecture.arm64, IOSSdk.iPhoneOS) => (
        key: 'ios-arm64',
        libraryFileName: 'libvtk_flutter_core.dylib',
        androidAbi: null,
      ),
      (OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator) => (
        key: 'ios-simulator-arm64',
        libraryFileName: 'libvtk_flutter_core.dylib',
        androidAbi: null,
      ),
      (OS.iOS, Architecture.x64, IOSSdk.iPhoneSimulator) => (
        key: 'ios-simulator-x64',
        libraryFileName: 'libvtk_flutter_core.dylib',
        androidAbi: null,
      ),
      (OS.android, Architecture.arm64, null) => (
        key: 'android-arm64',
        libraryFileName: 'libvtk_flutter_core.so',
        androidAbi: 'arm64-v8a',
      ),
      (OS.android, Architecture.arm, null) => (
        key: 'android-armeabi-v7a',
        libraryFileName: 'libvtk_flutter_core.so',
        androidAbi: 'armeabi-v7a',
      ),
      (OS.android, Architecture.x64, null) => (
        key: 'android-x86_64',
        libraryFileName: 'libvtk_flutter_core.so',
        androidAbi: 'x86_64',
      ),
      (OS.windows, Architecture.x64, null) => (
        key: 'windows-x64',
        libraryFileName: 'vtk_flutter_core.dll',
        androidAbi: null,
      ),
      _ => throw UnsupportedNativeArtifactTarget(
        operatingSystem: operatingSystem,
        architecture: architecture,
        appleSdk: appleSdk,
      ),
    };

    final archiveName = nativeReleaseArtifacts[key];
    if (archiveName == null) {
      throw StateError('No release artifact is configured for target $key.');
    }
    return NativeArtifactTarget._(
      key: key,
      archiveName: archiveName,
      libraryFileName: libraryFileName,
      androidAbi: androidAbi,
      appleSdk: appleSdk,
    );
  }
}

final class UnsupportedNativeArtifactTarget implements Exception {
  const UnsupportedNativeArtifactTarget({
    required this.operatingSystem,
    required this.architecture,
    required this.appleSdk,
  });

  final OS operatingSystem;
  final Architecture architecture;
  final IOSSdk? appleSdk;

  @override
  String toString() {
    final sdkDescription = switch (appleSdk) {
      null => '',
      final sdk => ', SDK ${sdk.type}',
    };
    return 'Unsupported vtk_flutter native target: '
        '${operatingSystem.name}/${architecture.name}$sdkDescription.';
  }
}
