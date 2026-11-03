import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:web/web.dart' as web;

import 'primitives.dart';

/// Keeps tooltip placement in the render state, including during parent polls.
class FieldHelp extends StatefulComponent {
  const FieldHelp({
    required this.id,
    required this.label,
    required this.description,
    required this.buttonLabel,
    super.key,
  });
  final String id, label, description, buttonLabel;
  @override
  State<FieldHelp> createState() => _FieldHelpState();
}

class _FieldHelpState extends State<FieldHelp> {
  bool _positioned = false;
  String? _placement;

  void _enter(web.Event event) {
    final trigger = event.currentTarget as web.HTMLElement;
    final popup = trigger.nextElementSibling as web.HTMLElement;
    // Measure hidden content synchronously; the next render owns every style.
    popup.style.visibility = 'hidden';
    popup.style.position = 'fixed';
    popup.style.width = '${(web.window.innerWidth - 32).clamp(200, 380)}px';
    popup.style.maxHeight = '${web.window.innerHeight - 32}px';
    popup.style.overflowY = 'auto';
    popup.style.right = 'auto';
    popup.style.bottom = 'auto';
    popup.style.left = '0px';
    popup.style.top = '0px';
    final anchor = trigger.getBoundingClientRect(),
        bounds = popup.getBoundingClientRect();
    final below = anchor.bottom + 12;
    final top =
        (below + bounds.height <= web.window.innerHeight - 16
                ? below
                : anchor.top - bounds.height - 12)
            .clamp(16, web.window.innerHeight - bounds.height - 16);
    final left = anchor.left.clamp(
      16,
      web.window.innerWidth - bounds.width - 16,
    );
    setState(() {
      _placement =
          'position:fixed;width:${(web.window.innerWidth - 32).clamp(200, 380)}px;max-height:${web.window.innerHeight - 32}px;overflow-y:auto;right:auto;bottom:auto;left:${left}px;top:${top}px;';
      _positioned = true;
    });
  }

  @override
  Component build(BuildContext context) => el('span', [
    el(
      'button',
      [Component.text('?')],
      attributes: {
        'type': 'button',
        'aria-label': component.buttonLabel,
        'aria-describedby': component.id,
      },
      events: {
        'mouseenter': _enter,
        'mouseleave': (_) {
          if (_positioned) setState(() => _positioned = false);
        },
      },
    ),
    div(
      [
        el('strong', [Component.text(component.label)]),
        p([Component.text(component.description)]),
      ],
      classes: 'help-popover',
      attributes: {
        'id': component.id,
        'role': 'tooltip',
        'data-positioned': _positioned ? 'true' : 'false',
        if (_placement != null) 'style': _placement!,
      },
    ),
  ], classes: 'field-help');
}
