#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vtk_flutter.podspec` to validate before publishing.
#
vtk_install = '../.dart_tool/vtk/9.5.2/macos-arm64/install'
vtk_archives = Dir[File.expand_path("#{vtk_install}/lib/*.a", __dir__)].sort
vtk_link_flags = vtk_archives.map do |archive|
  "-Wl,-force_load,$(PODS_ROOT)/../Flutter/ephemeral/.symlinks/plugins/vtk_flutter/.dart_tool/vtk/9.5.2/macos-arm64/install/lib/#{File.basename(archive)}"
end.join(' ')

Pod::Spec.new do |s|
  s.name             = 'vtk_flutter'
  s.version          = '0.1.0-dev.1'
  s.summary          = 'VTK-backed volume rendering for Flutter.'
  s.description      = <<-DESC
Focused VTK rendering for Flutter applications.
                       DESC
  s.homepage         = 'https://github.com/wwwdata/vtk_flutter'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Ben Bieker' => 'ben@bieker.ninja' }

  s.source           = { :path => '.' }
  s.source_files = 'vtk_flutter/Sources/vtk_flutter/**/*.{h,m,mm,c,cc,cpp,cxx}'
  s.public_header_files = 'vtk_flutter/Sources/vtk_flutter/VtkFlutterPlugin.h'
  s.private_header_files = 'vtk_flutter/Sources/vtk_flutter/VtkFlutterProtocol.h'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {
    'vtk_flutter_privacy' => ['vtk_flutter/Sources/vtk_flutter/PrivacyInfo.xcprivacy']
  }

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '11.0'
  s.static_framework = true
  s.frameworks = 'Cocoa', 'CoreVideo', 'IOSurface', 'OpenGL', 'QuartzCore'
  s.libraries = 'c++', 'z'
  s.requires_arc = true
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GL_SILENCE_DEPRECATION=1 VTK_FLUTTER_STATIC=1',
    'HEADER_SEARCH_PATHS' => "$(inherited) \"$(PODS_TARGET_SRCROOT)/../native/include\" \"$(PODS_TARGET_SRCROOT)/../native/src\" \"$(PODS_TARGET_SRCROOT)/#{vtk_install}/include/vtk-9.5\"",
  }
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => "$(inherited) #{vtk_link_flags}",
  }
  s.script_phase = {
    :name => 'Verify bootstrapped VTK',
    :execution_position => :before_compile,
    :script => <<-SCRIPT
if [ ! -d "${PODS_TARGET_SRCROOT}/#{vtk_install}/include/vtk-9.5" ]; then
  echo "error: Missing VTK 9.5.2 macos-arm64 install. Run: dart run tool/bootstrap_vtk.dart --platform macos-arm64" >&2
  exit 1
fi
SCRIPT
  }

  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = 'Tests/**/*.{h,m,mm}'
    test_spec.frameworks = 'XCTest'
  end
end
