const nativeReleaseRepository = 'wwwdata/vtk_flutter';
const nativeReleaseTag = 'native-v0.2.0-dev.2';
const nativeChecksumManifestName = 'SHA256SUMS';

const nativeReleaseArtifacts = <String, String>{
  'macos-arm64': 'vtk_flutter-native-macos-arm64.zip',
  'macos-x64': 'vtk_flutter-native-macos-x64.zip',
  'ios-arm64': 'vtk_flutter-native-ios-arm64.zip',
  'ios-simulator-arm64': 'vtk_flutter-native-ios-simulator-arm64.zip',
  'ios-simulator-x64': 'vtk_flutter-native-ios-simulator-x64.zip',
  'android-arm64': 'vtk_flutter-native-android-arm64.zip',
  'android-armeabi-v7a': 'vtk_flutter-native-android-armeabi-v7a.zip',
  'android-x86_64': 'vtk_flutter-native-android-x86_64.zip',
  'windows-x64': 'vtk_flutter-native-windows-x64.zip',
};

Uri nativeReleaseAssetUri(String assetName) => Uri.https(
  'github.com',
  '/$nativeReleaseRepository/releases/download/$nativeReleaseTag/$assetName',
);
