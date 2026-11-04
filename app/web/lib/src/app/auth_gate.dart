import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../shared/api/api_client.dart';
import '../shared/components/primitives.dart';
import '../shared/localization/strings.dart';
import '../shared/localization/language_select.dart';
import 'sky_app.dart';

class OwnerGate extends StatefulComponent {
  const OwnerGate({super.key});
  @override
  State<OwnerGate> createState() => _OwnerGateState();
}

class _OwnerGateState extends State<OwnerGate> {
  static const _languageKey = 'sky-ui.language';
  final api = ApiClient(), locale = const AppStrings();
  OwnerState? owner;
  String username = '', password = '';
  String? error;
  bool loading = true, busy = false;
  Timer? sessionTimer;
  bool checking = false;
  int generation = 0;
  String t(String key) => locale(key);
  @override
  void initState() {
    super.initState();
    try {
      final saved = web.window.localStorage.getItem(_languageKey);
      if (AppStrings.supportedLocales.contains(saved))
        AppStrings.defaultLocale = saved!;
    } on Object {
      // The interface still works when storage is blocked.
    }
    web.document.documentElement?.setAttribute('lang', locale.locale);
    unawaited(check());
    sessionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!busy) unawaited(check());
    });
  }

  void changeLanguage(String language) {
    if (!AppStrings.supportedLocales.contains(language) ||
        language == locale.locale)
      return;
    setState(() => AppStrings.defaultLocale = language);
    web.document.documentElement?.setAttribute('lang', language);
    try {
      web.window.localStorage.setItem(_languageKey, language);
    } on Object {
      // Keep the current language for the open tab.
    }
  }

  @override
  void dispose() {
    sessionTimer?.cancel();
    super.dispose();
  }

  void authenticated(OwnerState value) {
    generation++;
    if (mounted) setState(() => owner = value);
  }

  Future<void> check() async {
    if (checking) return;
    checking = true;
    final current = generation;
    try {
      final value = await api.owner();
      if (mounted &&
          current == generation &&
          (owner == null ||
              owner!.sessionId != value.sessionId ||
              owner!.configured != value.configured))
        setState(() => owner = value);
    } on ApiClientException catch (e) {
      if (mounted && owner == null) setState(() => error = e.code);
    } finally {
      checking = false;
      if (mounted) setState(() => loading = false);
    }
  }

  void signedOut() {
    generation++;
    if (mounted)
      setState(() {
        owner = OwnerState(configured: true, authenticated: false);
        password = '';
        error = null;
      });
    unawaited(check());
  }

  Future<void> login() async {
    if (busy || username.isEmpty || password.isEmpty) return;
    generation++;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await api.login(username, password);
      if (mounted)
        setState(() {
          owner = value;
          password = '';
        });
    } on ApiClientException catch (e) {
      if (mounted) setState(() => error = e.code);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Component build(BuildContext context) {
    if (loading)
      return div([txt(t('runtime.loading'))], classes: 'login-shell');
    if (owner?.authenticated == true)
      return SkyApp(
        owner: owner!,
        onSignedOut: signedOut,
        onOwnerChanged: authenticated,
        onLocaleChanged: changeLanguage,
        key: ValueKey((owner!.sessionId, locale.locale)),
      );
    return div([
      el(
        'form',
        [
          h1([Component.text('Sky UI')]),
          LanguageSelect(onChanged: changeLanguage),
          label([
            txt(t('admin.username')),
            input<String>(
              value: username,
              disabled: busy,
              onInput: (v) => username = v,
              attributes: {
                'autocomplete': 'username',
                'autofocus': '',
                'maxlength': '32',
                'required': '',
              },
            ),
          ]),
          label([
            txt(t('admin.password')),
            input<String>(
              type: InputType.password,
              value: password,
              disabled: busy,
              onInput: (v) => password = v,
              attributes: {'autocomplete': 'current-password', 'required': ''},
            ),
          ]),
          div(
            [if (error != null) Component.text(t('runtime.error.$error'))],
            classes: 'login-error',
            attributes: {'role': 'alert'},
          ),
          if (owner?.configured == false)
            p([Component.text(t('auth.setupRequired'))], classes: 'notice'),
          if (owner == null)
            action(t('common.refresh'), () => unawaited(check())),
          button(
            [Component.text(t(busy ? 'auth.signingIn' : 'auth.signIn'))],
            type: ButtonType.submit,
            classes: 'button primary',
            disabled: busy || owner?.configured != true,
          ),
        ],
        classes: 'panel login-panel',
        events: {
          'submit': (event) {
            event.preventDefault();
            unawaited(login());
          },
        },
      ),
    ], classes: 'login-shell');
  }
}
