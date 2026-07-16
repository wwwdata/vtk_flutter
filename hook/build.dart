import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import '../tool/native_artifacts.dart';
import 'src/native_artifact_installer.dart';
import 'src/native_artifact_target.dart';

const nativeArtifactOverrideKey = 'native_artifact';
const nativeCodeAssetName = 'vtk_flutter_core.dart';
const skipNativeArtifactKey = 'skip_native_artifact';

Future<void> main(List<String> arguments) async {
  await build(arguments, runBuildHook);
}

Future<void> runBuildHook(BuildInput input, BuildOutputBuilder output) async {
  if (!input.config.buildCodeAssets) return;
  if (input.userDefines[skipNativeArtifactKey] == true) return;

  final codeConfig = input.config.code;
  if (codeConfig.targetOS == OS.linux) return;

  final target = NativeArtifactTarget.resolve(
    operatingSystem: codeConfig.targetOS,
    architecture: codeConfig.targetArchitecture,
    appleSdk: codeConfig.targetOS == OS.iOS ? codeConfig.iOS.targetSdk : null,
  );
  final outputDirectory = Directory.fromUri(
    input.outputDirectoryShared.resolve(
      'vtk_flutter/$nativeReleaseTag/${target.key}/',
    ),
  );
  const installer = NativeArtifactInstaller();
  final localArtifactUri = input.userDefines.path(nativeArtifactOverrideKey);
  final library = switch (localArtifactUri) {
    null => await installer.installRelease(
      target: target,
      outputDirectory: outputDirectory,
    ),
    final uri => await _installLocalArtifact(
      uri: uri,
      output: output,
      installer: installer,
      target: target,
      outputDirectory: outputDirectory,
    ),
  };

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: nativeCodeAssetName,
      linkMode: DynamicLoadingBundled(),
      file: library.absolute.uri,
    ),
  );
}

Future<File> _installLocalArtifact({
  required Uri uri,
  required BuildOutputBuilder output,
  required NativeArtifactInstaller installer,
  required NativeArtifactTarget target,
  required Directory outputDirectory,
}) async {
  final directory = Directory.fromUri(uri);
  final source = await directory.exists()
      ? File(
          '${directory.path}${Platform.pathSeparator}${target.key}'
          '${Platform.pathSeparator}${target.libraryFileName}',
        )
      : File.fromUri(uri);
  output.dependencies.add(source.uri);
  return installer.installLocal(
    source: source,
    target: target,
    outputDirectory: outputDirectory,
  );
}
