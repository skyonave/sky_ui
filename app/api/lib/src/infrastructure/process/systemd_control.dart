import 'dart:io';

import 'command_runner.dart';

class SystemdControl {
  const SystemdControl(this.path);

  final String path;

  Future<CommandResult> run(String verb, String unit) async {
    Socket? socket;
    try {
      const connectTimeout = Duration(seconds: 2);
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: connectTimeout,
      );
      socket.writeln('$verb $unit');
      await socket.flush().timeout(connectTimeout);
      final accepted = await socket
          .take(1)
          .fold(false, (_, bytes) => bytes.length == 1 && bytes.single == 48)
          .timeout(const Duration(seconds: 16));
      if (accepted) {
        return const CommandResult(0, '');
      }
    } on Exception {
      // Treat a failed transport like a failed systemctl call.
    } finally {
      socket?.destroy();
    }
    return const CommandResult(1, 'Managed systemd operation failed.');
  }
}
