#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vtk_flutter.podspec` to validate before publishing.

Pod::Spec.new do |s|
  s.name             = 'vtk_flutter'
  s.version          = '0.2.0-dev.1'
  s.summary          = 'Domain-agnostic VTK rendering for Flutter.'
  s.description      = <<-DESC
Typed Dart VTK pipelines with Flutter texture presentation.
                       DESC
  s.homepage         = 'https://github.com/wwwdata/vtk_flutter'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Ben Bieker' => 'ben@bieker.ninja' }
  s.source           = { :path => '.' }
  s.source_files = 'vtk_flutter/Sources/vtk_flutter/**/*.{h,m,mm}'
  s.public_header_files =
    'vtk_flutter/Sources/vtk_flutter/include/vtk_flutter/VtkFlutterPlugin.h'
  s.private_header_files = 'vtk_flutter/Sources/vtk_flutter/VtkFlutterProtocol.h'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.static_framework = true
  s.frameworks = 'CoreVideo', 'IOSurface'
  s.libraries = 'c++'
  s.requires_arc = true
  s.resource_bundles = {
    'vtk_flutter_privacy' => ['vtk_flutter/Sources/vtk_flutter/PrivacyInfo.xcprivacy']
  }

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' =>
      '$(inherited) "$(PODS_TARGET_SRCROOT)/vtk_flutter/Sources/vtk_flutter/include/vtk_flutter"',
  }

  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = 'Tests/**/*.{h,m,mm}'
    test_spec.frameworks = 'XCTest'
  end
end
