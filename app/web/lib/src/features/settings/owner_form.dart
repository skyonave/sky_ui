import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class OwnerForm extends StatelessComponent {
  const OwnerForm({
    required this.ownerDraft,
    required this.ownerBusy,
    required this.password,
    super.key,
  });
  final Map<String, String> ownerDraft;
  final bool ownerBusy;
  final bool password;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) => div([
    if (!password)
      ownerField('username', 'admin.username', autocomplete: 'username'),
    ownerField(
      'currentPassword',
      'admin.currentPassword',
      secret: true,
      autocomplete: 'current-password',
    ),
    if (password) ...[
      ownerField(
        'password',
        'admin.newPassword',
        secret: true,
        autocomplete: 'new-password',
      ),
      ownerField(
        'confirmation',
        'admin.confirmPassword',
        secret: true,
        autocomplete: 'new-password',
      ),
      p([Component.text(t('admin.passwordHint'))], classes: 'muted small'),
    ],
    p([Component.text(t('admin.rotationHint'))], classes: 'muted small'),
  ], classes: 'owner-form');

  Component ownerField(
    String id,
    String labelKey, {
    bool secret = false,
    String? autocomplete,
  }) => label([
    txt(t(labelKey)),
    input<String>(
      value: ownerDraft[id] ?? '',
      type: secret ? InputType.password : InputType.text,
      disabled: ownerBusy,
      onInput: (v) => ownerDraft[id] = v,
      attributes: {
        'autocomplete': autocomplete ?? 'off',
        'maxlength': secret ? '72' : '32',
      },
    ),
  ]);
}
