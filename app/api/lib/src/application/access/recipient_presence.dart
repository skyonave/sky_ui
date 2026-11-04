import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../engines/contracts.dart';
import '../engines/core_manager.dart';
import 'repository.dart';

class RecipientPresenceService {
  RecipientPresenceService(this.repository, this.managers, this.canObserve);

  final AccessRepository repository;
  final Map<String, CoreManager> managers;
  final Future<bool> Function() canObserve;
  Future<Map<String, Object?>>? _inFlight;

  Future<Map<String, Object?>> snapshot() =>
      _inFlight ??= _snapshot().whenComplete(() => _inFlight = null);

  Future<Map<String, Object?>> _snapshot() async {
    final revision = repository.revision;
    final data = repository.read();
    final observed = <String, RecipientPresence>{};
    if (await canObserve()) {
      await Future.wait([
        for (final owner in managers.values)
          () async {
            final instance = data.forInstance(owner.core.id);
            final listening = instance.listeningConnections;
            if (listening.isEmpty) return;
            try {
              final service = await owner.supervisor.inspect(owner.core);
              if (service.state == CoreProcessState.inactive ||
                  service.state == CoreProcessState.failed) {
                for (final c in listening) {
                  for (final g in instance.activeGrants(c.value.id)) {
                    observed[g.id] = RecipientPresence.offline;
                  }
                }
              } else if (service.state == CoreProcessState.active) {
                final source = owner.adapter;
                if (source is CorePresenceSource)
                  observed.addAll(
                    await (source as CorePresenceSource).presence(
                      owner.core,
                      instance,
                    ),
                  );
              }
            } on Exception {
              // An unavailable observation cannot prove that a user is offline.
            }
          }(),
      ]);
    }
    if (repository.revision != revision || repository.pending != null) {
      return {
        'revision': repository.revision,
        'recipients': <String, String>{},
      };
    }
    final byRecipient = <String, List<RecipientPresence>>{};
    for (final c in data.listeningConnections) {
      for (final g in data.activeGrants(c.value.id)) {
        (byRecipient[g.recipientId] ??= []).add(
          observed[g.id] ?? RecipientPresence.unavailable,
        );
      }
    }
    return {
      'revision': revision,
      'recipients': {
        for (final user in data.recipients)
          user.id: combinePresence(byRecipient[user.id] ?? const []).name,
      },
    };
  }
}

RecipientPresence combinePresence(List<RecipientPresence> observations) {
  if (observations.contains(RecipientPresence.online))
    return RecipientPresence.online;
  if (observations.contains(RecipientPresence.recent))
    return RecipientPresence.recent;
  if (observations.contains(RecipientPresence.unavailable))
    return RecipientPresence.unavailable;
  return RecipientPresence.offline;
}
