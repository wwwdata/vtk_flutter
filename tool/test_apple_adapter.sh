#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
if [[ "$platform" != "macos" && "$platform" != "ios" ]]; then
  echo "Usage: tool/test_apple_adapter.sh <macos|ios>" >&2
  exit 64
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${FLUTTER_ROOT:-}" ]]; then
  flutter_root="$FLUTTER_ROOT"
elif command -v fvm >/dev/null 2>&1; then
  flutter_executable="$(cd "$repository_root" && fvm exec which flutter)"
  flutter_root="$(dirname "$(dirname "$flutter_executable")")"
else
  flutter_executable="$(command -v flutter)"
  flutter_root="$(dirname "$(dirname "$flutter_executable")")"
fi

harness="$(mktemp -d "${TMPDIR:-/tmp}/vtk-flutter-${platform}-tests.XXXXXX")"
trap 'rm -rf "$harness"' EXIT
mkdir -p "$harness/Flutter"

if [[ "$platform" == "macos" ]]; then
  "$flutter_root/bin/flutter" precache --macos
  framework="$flutter_root/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework"
  if [[ ! -d "$framework" ]]; then
    framework="$(find "$flutter_root/bin/cache/artifacts/engine" \
      -type d -name FlutterMacOS.xcframework -print -quit)"
  fi
  [[ -d "$framework" ]] || {
    echo "FlutterMacOS.xcframework is unavailable under $flutter_root" >&2
    exit 1
  }
  ln -s "$framework" "$harness/Flutter/FlutterMacOS.xcframework"
  cat >"$harness/Flutter/FlutterMacOS.podspec" <<'RUBY'
Pod::Spec.new do |spec|
  spec.name = 'FlutterMacOS'
  spec.version = '1.0.0'
  spec.summary = 'Local Flutter framework for vtk_flutter macOS adapter tests.'
  spec.homepage = 'https://flutter.dev'
  spec.license = { :type => 'BSD' }
  spec.author = { 'Flutter Team' => 'flutter-dev@googlegroups.com' }
  spec.source = { :path => '.' }
  spec.platform = :osx, '11.0'
  spec.vendored_frameworks = 'FlutterMacOS.xcframework'
end
RUBY
  cat >"$harness/Podfile" <<RUBY
install! 'cocoapods', :integrate_targets => false

platform :osx, '11.0'

target 'vtk_flutter_tests' do
  use_frameworks! :linkage => :static
  pod 'FlutterMacOS', :path => '$harness/Flutter'
  pod 'vtk_flutter', :path => '$repository_root/macos', :testspecs => ['Tests']
end
RUBY
  destination='platform=macOS'
else
  "$flutter_root/bin/flutter" precache --ios
  framework="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework"
  [[ -d "$framework" ]] || {
    echo "Flutter.xcframework is unavailable under $flutter_root" >&2
    exit 1
  }
  ln -s "$framework" "$harness/Flutter/Flutter.xcframework"
  cat >"$harness/Flutter/Flutter.podspec" <<'RUBY'
Pod::Spec.new do |spec|
  spec.name = 'Flutter'
  spec.version = '1.0.0'
  spec.summary = 'Local Flutter framework for vtk_flutter iOS adapter tests.'
  spec.homepage = 'https://flutter.dev'
  spec.license = { :type => 'BSD' }
  spec.author = { 'Flutter Team' => 'flutter-dev@googlegroups.com' }
  spec.source = { :path => '.' }
  spec.platform = :ios, '13.0'
  spec.vendored_frameworks = 'Flutter.xcframework'
end
RUBY
  cat >"$harness/Podfile" <<RUBY
install! 'cocoapods', :integrate_targets => false

platform :ios, '13.0'

target 'vtk_flutter_tests' do
  use_frameworks! :linkage => :static
  pod 'Flutter', :path => '$harness/Flutter'
  pod 'vtk_flutter', :path => '$repository_root/ios', :testspecs => ['Tests']
end
RUBY
  simulator_id="$(xcrun simctl list devices available | \
    sed -nE '/iPhone/ s/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n 1)"
  [[ -n "$simulator_id" ]] || {
    echo 'No available iPhone simulator was found.' >&2
    exit 1
  }
  destination="platform=iOS Simulator,id=$simulator_id"
fi

pod install --project-directory="$harness"
xcodebuild test \
  -project "$harness/Pods/Pods.xcodeproj" \
  -scheme vtk_flutter-Unit-Tests \
  -configuration Debug \
  -destination "$destination" \
  CODE_SIGNING_ALLOWED=NO
