import 'package:jaspr/client.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import 'app_controller.dart';
import 'app_view.dart';

class SkyApp extends StatefulComponent {
  const SkyApp({
    required this.owner,
    required this.onSignedOut,
    required this.onOwnerChanged,
    super.key,
  });
  final OwnerState owner;
  final void Function() onSignedOut;
  final void Function(OwnerState) onOwnerChanged;
  @override
  State<SkyApp> createState() => _SkyAppState();
}

class _SkyAppState extends State<SkyApp> {
  late final AppController controller;
  @override
  void initState() {
    super.initState();
    controller = AppController(
      readOwner: () => component.owner,
      onSignedOut: () => component.onSignedOut(),
      onOwnerChanged: (owner) => component.onOwnerChanged(owner),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    controller.start();
  }

  @override
  Component build(BuildContext context) => AppView(controller: controller);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
