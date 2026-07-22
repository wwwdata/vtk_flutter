import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/vtk_flutter_method_channel.dart';
import 'package:vtk_flutter/src/vtk_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vtk_flutter/session');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'createView' => <String, Object>{'textureId': 42},
            'presentFrame' => <String, Object>{
              'frameId': 1,
              'presentedFrameCount': 1,
              'presentedFrameId': 1,
              'graphicsContextGeneration': 1,
              'handoffMode': 'test',
            },
            'resize' || 'disposeView' => null,
            _ => throw MissingPluginException(),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('is the default native platform implementation', () {
    expect(VtkFlutterPlatform.instance, isA<MethodChannelVtkFlutter>());
    expect(
      (VtkFlutterPlatform.instance as MethodChannelVtkFlutter)
          .methodChannel
          .name,
      'vtk_flutter/session',
    );
  });

  test('advertises independent session views on native plugin platforms', () {
    try {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          MethodChannelVtkFlutter().supportsIndependentSessionViews,
          isTrue,
          reason: '$platform',
        );
      }

      for (final platform in [TargetPlatform.linux, TargetPlatform.fuchsia]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          MethodChannelVtkFlutter().supportsIndependentSessionViews,
          isFalse,
          reason: '$platform',
        );
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('passes only opaque session data and presentation lifecycle', () async {
    final platform = MethodChannelVtkFlutter();
    final viewport = VtkViewport(width: 640, height: 320);

    final textureId = await platform.createView(
      viewport: viewport,
      presentationApiAddress: 2048,
      nativeSessionAddress: 4096,
    );
    await platform.presentFrame(nativeSessionAddress: 4096);
    await platform.resize(
      nativeSessionAddress: 4096,
      viewport: VtkViewport(width: 800, height: 600),
    );
    await platform.disposeView(nativeSessionAddress: 4096);

    expect(textureId, 42);
    expect(calls.map((call) => call.method), [
      'createView',
      'presentFrame',
      'resize',
      'disposeView',
    ]);
    expect(calls.first.arguments, {
      'width': 640,
      'height': 320,
      'presentationApiAddress': 2048,
      'nativeSessionAddress': 4096,
    });
    expect(calls[1].arguments, {'nativeSessionAddress': 4096});
    expect(calls[2].arguments, {
      'nativeSessionAddress': 4096,
      'width': 800,
      'height': 600,
    });
    expect(calls[3].arguments, {'nativeSessionAddress': 4096});
  });

  test('rejects malformed texture identifiers', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => <String, Object>{'textureId': -1},
        );

    await expectLater(
      MethodChannelVtkFlutter().createView(
        viewport: VtkViewport(width: 1, height: 1),
        presentationApiAddress: 1,
        nativeSessionAddress: 2,
      ),
      throwsA(isA<VtkApiStateException>()),
    );
  });

  test(
    'maps platform and missing-plugin failures to API state errors',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'invalid_state',
              message: 'View is already attached',
            );
          });

      await expectLater(
        MethodChannelVtkFlutter().disposeView(nativeSessionAddress: 4096),
        throwsA(
          isA<VtkApiStateException>().having(
            (error) => error.message,
            'message',
            contains('already attached'),
          ),
        ),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => throw MissingPluginException(),
          );
      await expectLater(
        MethodChannelVtkFlutter().disposeView(nativeSessionAddress: 4096),
        throwsA(isA<VtkApiStateException>()),
      );
    },
  );
}
