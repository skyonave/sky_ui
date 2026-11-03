import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../shared/api_exception.dart';

class CommandResult {
  const CommandResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

abstract interface class CommandRunner {
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 15),
  });
}

class NativeCommandRunner implements CommandRunner {
  const NativeCommandRunner({this.environment = const {}});
  final Map<String, String> environment;
  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        runInShell: false,
        environment: environment,
      );
    } on ProcessException {
      throw const ApiException('command_unavailable');
    }
    final bytes = <int>[];
    void collect(List<int> chunk) {
      final remaining = 16384 - bytes.length;
      if (remaining > 0) bytes.addAll(chunk.take(remaining));
    }

    final output = process.stdout.listen(collect);
    final errors = process.stderr.listen(collect);
    try {
      final completed = await Future.wait<Object?>([
        process.exitCode,
        output.asFuture<void>(),
        errors.asFuture<void>(),
      ]).timeout(timeout);
      final code = completed.first as int;
      return CommandResult(code, utf8.decode(bytes, allowMalformed: true));
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        if (!Platform.isWindows) process.kill(ProcessSignal.sigkill);
      }
      throw const ApiException('command_timeout', status: 504);
    } finally {
      await output.cancel();
      await errors.cancel();
    }
  }
}
