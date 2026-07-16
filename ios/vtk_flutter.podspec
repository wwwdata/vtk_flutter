#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vtk_flutter.podspec` to validate before publishing.
vtk_version = '9.5.2'
vtk_install = lambda { |target| "../.dart_tool/vtk/#{vtk_version}/#{target}/install" }
vtk_link_flags = lambda do |target|
  install = vtk_install.call(target)
  archives = Dir[File.expand_path("#{install}/lib/*.a", __dir__)].sort
  archives.map do |archive|
    "-Wl,-force_load,$(PODS_ROOT)/../Flutter/ephemeral/.symlinks/plugins/vtk_flutter/.dart_tool/vtk/#{vtk_version}/#{target}/install/lib/#{File.basename(archive)}"
  end.join(' ')
end
device_install = vtk_install.call('ios-arm64')
simulator_install = vtk_install.call('ios-simulator-arm64')

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
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.static_framework = true
  s.frameworks = 'CoreVideo', 'IOSurface', 'Metal', 'OpenGLES', 'QuartzCore', 'UIKit'
  s.libraries = 'c++', 'z'
  s.requires_arc = true
  s.resource_bundles = {
    'vtk_flutter_privacy' => ['vtk_flutter/Sources/vtk_flutter/PrivacyInfo.xcprivacy']
  }

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GLES_SILENCE_DEPRECATION=1 COREVIDEO_SILENCE_GL_DEPRECATION=1 VTK_FLUTTER_STATIC=1',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'HEADER_SEARCH_PATHS[sdk=iphoneos*]' => "$(inherited) \"$(PODS_TARGET_SRCROOT)/../native/include\" \"$(PODS_TARGET_SRCROOT)/../native/src\" \"$(PODS_TARGET_SRCROOT)/#{device_install}/include/vtk-9.5\"",
    'HEADER_SEARCH_PATHS[sdk=iphonesimulator*]' => "$(inherited) \"$(PODS_TARGET_SRCROOT)/../native/include\" \"$(PODS_TARGET_SRCROOT)/../native/src\" \"$(PODS_TARGET_SRCROOT)/#{simulator_install}/include/vtk-9.5\"",
  }
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' => "$(inherited) #{vtk_link_flags.call('ios-arm64')}",
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => "$(inherited) #{vtk_link_flags.call('ios-simulator-arm64')}",
  }
  s.script_phase = {
    :name => 'Verify bootstrapped VTK',
    :execution_position => :before_compile,
    :script => <<-SCRIPT
vtk_target="ios-arm64"
if [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
  vtk_target="ios-simulator-arm64"
fi
vtk_headers="${PODS_TARGET_SRCROOT}/../.dart_tool/vtk/#{vtk_version}/${vtk_target}/install/include/vtk-9.5"
if [ ! -d "$vtk_headers" ]; then
  echo "error: Missing VTK #{vtk_version} ${vtk_target} install. Run: dart run tool/bootstrap_vtk.dart --platform ${vtk_target}" >&2
  exit 1
fi
SCRIPT
  }

  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = 'Tests/**/*.{h,m,mm}'
    test_spec.frameworks = 'XCTest'
  end
end
