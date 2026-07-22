import 'package:flutter_test/flutter_test.dart';

import '../../tool/check.dart';

void main() {
  test('runs format, analyze, and test in order', () async {
    final commands = <String>[];

    final result = await runChecks(
      const [],
      runner:
          ({required executable, required arguments, workingDirectory}) async {
            commands.add(
              '${workingDirectory ?? '.'}: '
              '${[executable, ...arguments].join(' ')}',
            );
            return 0;
          },
      writeLine: (_) {},
    );

    expect(result, 0);
    expect(commands, [
      '.: fvm dart format --output=none --set-exit-if-changed .',
      '.: fvm flutter analyze',
      '.: fvm flutter test',
      'example: fvm flutter test',
    ]);
  });

  test('stops after the first failed check', () async {
    var commandCount = 0;

    final result = await runChecks(
      const [],
      runner:
          ({required executable, required arguments, workingDirectory}) async {
            commandCount++;
            return 3;
          },
      writeLine: (_) {},
    );

    expect(result, 3);
    expect(commandCount, 1);
  });

  test('supports help without running checks', () async {
    var commandCount = 0;
    final output = <String>[];

    final result = await runChecks(
      const ['--help'],
      runner:
          ({required executable, required arguments, workingDirectory}) async {
            commandCount++;
            return 0;
          },
      writeLine: output.add,
    );

    expect(result, 0);
    expect(commandCount, 0);
    expect(output.single, contains('Usage:'));
  });

  test('full checks include native, web, and host integration evidence', () {
    final checks = createChecks(
      full: true,
      operatingSystem: 'macos',
      rootDirectory: '/workspace',
    );
    final commands = [
      for (final check in checks)
        '${check.workingDirectory ?? '.'}: '
            '${[check.executable, ...check.arguments].join(' ')}',
    ];

    expect(commands, contains('example: fvm flutter build web'));
    expect(
      commands,
      contains(
        '.: cmake -S native -B .dart_tool/native-test '
        '-DVTK_DIR=/workspace/.dart_tool/vtk/9.6.2/macos-arm64/install/lib/cmake/vtk-9.6 '
        '-DBUILD_TESTING=ON',
      ),
    );
    expect(
      commands,
      contains(
        'example: fvm flutter test '
        'integration_test/renderer_lab_test.dart -d macos',
      ),
    );
    expect(commands, contains('.: bash tool/test_apple_adapter.sh macos'));
    expect(commands, contains('.: bash tool/test_apple_adapter.sh ios'));
  });

  test('full Windows checks execute the presentation-adapter tests', () {
    final checks = createChecks(
      full: true,
      operatingSystem: 'windows',
      rootDirectory: r'C:\workspace',
    );
    final commands = [
      for (final check in checks)
        '${check.workingDirectory ?? '.'}: '
            '${[check.executable, ...check.arguments].join(' ')}',
    ];

    expect(
      commands,
      contains(
        'example: ctest --test-dir '
        'build/windows/x64/plugins/vtk_flutter '
        '-C Debug --output-on-failure',
      ),
    );
  });
}
