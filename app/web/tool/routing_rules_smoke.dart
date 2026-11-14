import 'dart:async';
import 'dart:convert';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/features/routing/route_rules.dart';
import 'package:sky_ui_web/src/shared/localization/strings.dart';
import 'package:web/web.dart' as web;

/// Browser regression fixture for production drag/drop and keyboard reordering.
void main() {
  AppStrings.defaultLocale = 'en';
  runApp(const RoutingRulesSmoke(), attachTo: '#app');
  unawaited(_check());
}

Future<void> _frame() => Future<void>.delayed(const Duration(milliseconds: 80));

Future<void> _check() async {
  final result = web.document.querySelector('#result')!;
  try {
    await _frame();
    List<web.Element> rows() {
      final nodes = web.document.querySelectorAll('.route-rule-row');
      return [
        for (var i = 0; i < nodes.length; i++) nodes.item(i)! as web.Element,
      ];
    }

    String first() =>
        (rows().first.querySelector('input') as web.HTMLInputElement).value;
    void require(bool condition, String message) {
      if (!condition) throw StateError(message);
    }

    require(rows().length == 3, 'Three rules must render.');
    final data = web.DataTransfer();
    rows()[1]
        .querySelector('.route-rule-grip')!
        .dispatchEvent(
          web.DragEvent(
            'dragstart',
            web.DragEventInit(bubbles: true, dataTransfer: data),
          ),
        );
    await _frame();
    rows()[0].dispatchEvent(
      web.DragEvent(
        'dragover',
        web.DragEventInit(bubbles: true, cancelable: true, dataTransfer: data),
      ),
    );
    await _frame();
    require(
      rows()[0].classList.contains('drop-before'),
      'Drop insertion marker must appear.',
    );
    rows()[0].dispatchEvent(
      web.DragEvent(
        'drop',
        web.DragEventInit(bubbles: true, cancelable: true, dataTransfer: data),
      ),
    );
    await _frame();
    require(
      first() == 'video.example.org',
      'Dragging up must update field values and priority.',
    );
    (rows()[0].querySelector('[aria-label="Move rule down"]')
            as web.HTMLElement)
        .click();
    await _frame();
    require(
      first() == 'example.org',
      'Keyboard-accessible down action must use the same ordering.',
    );
    (web.document.querySelector('#reload-policy') as web.HTMLElement).click();
    await _frame();
    require(
      first() == 'example.org',
      'Saved policy must retain the displayed order.',
    );
    (web.document.querySelector('#read-only') as web.HTMLElement).click();
    await _frame();
    require(
      rows().first
              .querySelector('.route-rule-grip')!
              .getAttribute('draggable') ==
          'false',
      'Read-only policy must not allow dragging.',
    );
    require(
      (rows().first.querySelector('select') as web.HTMLSelectElement).disabled,
      'Read-only policy fields must be disabled.',
    );
    result.textContent =
        'PASS: drag/drop, keyboard reorder, serialized reload, read-only controls';
  } catch (error) {
    result.textContent = 'FAIL: $error';
  }
}

class RoutingRulesSmoke extends StatefulComponent {
  const RoutingRulesSmoke({super.key});
  @override
  State<RoutingRulesSmoke> createState() => _RoutingRulesSmoke();
}

class _RoutingRulesSmoke extends State<RoutingRulesSmoke> {
  bool editable = true;
  NodeRouting policy = const NodeRouting(
    rules: [
      RoutingRule('suffix', 'example.org', NodeRouting.block),
      RoutingRule('domain', 'video.example.org', NodeRouting.direct),
      RoutingRule('network', 'udp', NodeRouting.next),
    ],
  );

  @override
  Component build(BuildContext context) => div([
    RouteRules(
      nodes: const ['local'],
      node: 'local',
      names: const {'local': 'Server'},
      policy: policy,
      coreId: 'mihomo',
      ruleLimit: NodeRouting.maxRules,
      editable: editable,
      onChange: (value) => setState(() => policy = value),
    ),
    button(
      [Component.text('Reload saved policy')],
      id: 'reload-policy',
      onClick: () => setState(
        () => policy = NodeRouting.fromJson(
          jsonDecode(jsonEncode(policy.toJson())) as Map<String, dynamic>,
        ),
      ),
    ),
    button(
      [Component.text('Read only')],
      id: 'read-only',
      onClick: () => setState(() => editable = false),
    ),
  ]);
}
