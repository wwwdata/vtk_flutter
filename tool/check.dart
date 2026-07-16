import 'dart:io';

const _usage = '''
Run vtk_flutter quality checks.

Usage:
  dart run tool/check.dart [--full] [--help]

Checks:
  fvm dart format --output=none --set-exit-if-changed .
  fvm flutter analyze
  fvm flutter test
  fvm flutter test (example)

With --full:
  fvm flutter build web
  Native CMake configure, build, and contract tests (macOS/Windows hosts)
  Host desktop example build and render integration test
''';

typedef CheckCommandRunner =
    Future<int> Function({
      required String executable,
      required List<String> arguments,
      String? workingDirectory,
    });

typedef CheckCommand = ({
  String executable,
  List<String> arguments,
  String? workingDirectory,
});

Future<void> main(List<String> arguments) async {
  exitCode = await runChecks(arguments);
}

Future<int> runChecks(
  List<String> arguments, {
  CheckCommandRunner runner = runCheckCommand,
  void Function(String message)? writeLine,
}) async {
  final output = writeLine ?? stdout.writeln;
  if (arguments.any((argument) => argument == '--help' || argument == '-h')) {
    output(_usage);
    return 0;
  }
  final full = arguments.contains('--full');
  final unknownArguments = arguments
      .where((argument) => argument != '--full')
      .toList();
  if (unknownArguments.isNotEmpty) {
    stderr.writeln('Unknown argument: ${unknownArguments.first}\n');
    stderr.write(_usage);
    return 64;
  }

  final checks = createChecks(full: full);
  for (final check in checks) {
    final prefix = check.workingDirectory == null
        ? ''
        : '${check.workingDirectory}: ';
    output(prefix + r'$ ' + [check.executable, ...check.arguments].join(' '));
    final result = await runner(
      executable: check.executable,
      arguments: check.arguments,
      workingDirectory: check.workingDirectory,
    );
    if (result != 0) {
      return result;
    }
  }
  return 0;
}

List<CheckCommand> createChecks({
  required bool full,
  String? operatingSystem,
  String? rootDirectory,
}) {
  final checks = <CheckCommand>[
    (
      executable: 'fvm',
      arguments: [
        'dart',
        'format',
        '--output=none',
        '--set-exit-if-changed',
        '.',
      ],
      workingDirectory: null,
    ),
    (
      executable: 'fvm',
      arguments: ['flutter', 'analyze'],
      workingDirectory: null,
    ),
    (executable: 'fvm', arguments: ['flutter', 'test'], workingDirectory: null),
    (
      executable: 'fvm',
      arguments: ['flutter', 'test'],
      workingDirectory: 'example',
    ),
  ];
  if (!full) return checks;

  checks.add((
    executable: 'fvm',
    arguments: ['flutter', 'build', 'web'],
    workingDirectory: 'example',
  ));
  final host = operatingSystem ?? Platform.operatingSystem;
  final target = switch (host) {
    'macos' => 'macos-arm64',
    'windows' => 'windows-x64',
    _ => null,
  };
  if (target == null) return checks;
  final root = rootDirectory ?? Directory.current.absolute.path;

  checks.addAll([
    (
      executable: 'cmake',
      arguments: [
        '-S',
        'native',
        '-B',
        '.dart_tool/native-test',
        '-DVTK_DIR=$root/.dart_tool/vtk/9.5.2/$target/install/lib/cmake/vtk-9.5',
        '-DBUILD_TESTING=ON',
      ],
      workingDirectory: null,
    ),
    (
      executable: 'cmake',
      arguments: ['--build', '.dart_tool/native-test', '--parallel'],
      workingDirectory: null,
    ),
    (
      executable: 'ctest',
      arguments: [
        '--test-dir',
        '.dart_tool/native-test',
        '--output-on-failure',
      ],
      workingDirectory: null,
    ),
    (
      executable: 'fvm',
      arguments: ['flutter', 'build', host, '--debug'],
      workingDirectory: 'example',
    ),
    (
      executable: 'fvm',
      arguments: [
        'flutter',
        'test',
        'integration_test/renderer_lab_test.dart',
        '-d',
        host,
      ],
      workingDirectory: 'example',
    ),
  ]);
  return checks;
}

Future<int> runCheckCommand({
  required String executable,
  required List<String> arguments,
  String? workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
