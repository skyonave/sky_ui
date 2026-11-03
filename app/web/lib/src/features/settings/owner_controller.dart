import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api/api_client.dart';
import '../../shared/localization/strings.dart';

/// Owner credentials and session revocation keep their own busy state and draft.
class OwnerController {
  OwnerController({
    required this.api,
    required this.isAlive,
    required this.readOwner,
    required this.readModal,
    required this.message,
    required this.notify,
    required this.onError,
    required this.closeModal,
    required this.onSignedOut,
    required this.onOwnerChanged,
    required this.onChanged,
  });
  final ApiClient api;
  final bool Function() isAlive;
  final OwnerState Function() readOwner;
  final String? Function() readModal;
  final String Function(String) message;
  final void Function(String) notify;
  final void Function(String?) onError;
  final void Function() closeModal, onSignedOut, onChanged;
  final void Function(OwnerState) onOwnerChanged;
  final t = const AppStrings();
  bool get mounted => isAlive();
  String? get modal => readModal();
  set error(String? value) => onError(value);
  void _change(void Function() update) {
    if (!mounted) return;
    update();
    onChanged();
  }

  bool ownerBusy = false, ownerSessionsLoading = false;
  final ownerDraft = <String, String>{};
  List<OwnerSession> ownerSessions = [];
  String? revokeSessionId;
  Future<void> refreshOwnerSessions() async {
    if (ownerSessionsLoading || ownerBusy) return;
    ownerSessionsLoading = true;
    try {
      final values = await api.ownerSessions();
      if (mounted) _change(() => ownerSessions = values);
    } on ApiClientException catch (e) {
      if (mounted && e.code != 'auth_required') notify(message(e.code));
    } finally {
      ownerSessionsLoading = false;
    }
  }

  Future<void> signOut() async {
    if (ownerBusy) return;
    _change(() => ownerBusy = true);
    try {
      await api.logout();
      if (mounted) onSignedOut();
    } on ApiClientException catch (e) {
      if (mounted) notify(message(e.code));
    } finally {
      if (mounted) _change(() => ownerBusy = false);
    }
  }

  Future<void> saveOwner() async {
    if (ownerBusy) return;
    if ((ownerDraft['currentPassword'] ?? '').isEmpty) {
      _change(() => error = t('common.required'));
      return;
    }
    if (modal == 'ownerPassword' &&
        ownerDraft['password'] != ownerDraft['confirmation']) {
      _change(() => error = t('admin.passwordMismatch'));
      return;
    }
    final payload = <String, Object?>{
      'currentPassword': ownerDraft['currentPassword'],
      if (modal == 'ownerName') 'username': ownerDraft['username']?.trim(),
      if (modal == 'ownerPassword') 'password': ownerDraft['password'] ?? '',
    };
    _change(() => ownerBusy = true);
    try {
      final owner = await api.changeOwner(payload);
      if (mounted) {
        ownerDraft.clear();
        onOwnerChanged(owner);
      }
    } on ApiClientException catch (e) {
      if (mounted) _change(() => error = message(e.code));
    } finally {
      if (mounted) _change(() => ownerBusy = false);
    }
  }

  Future<void> revokeOwnerSessions() async {
    if (ownerBusy) return;
    final id = revokeSessionId;
    _change(() => ownerBusy = true);
    try {
      if (id == null) {
        await api.revokeOtherSessions();
      } else {
        await api.revokeSession(id);
      }
      if (!mounted) return;
      if (id == readOwner().sessionId) {
        onSignedOut();
        return;
      }
      _change(() => ownerBusy = false);
      closeModal();
      await refreshOwnerSessions();
    } on ApiClientException catch (e) {
      if (mounted) _change(() => error = message(e.code));
    } finally {
      if (mounted) _change(() => ownerBusy = false);
    }
  }
}
