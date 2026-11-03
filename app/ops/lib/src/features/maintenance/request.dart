import 'dart:convert';

import '../../platform/host.dart';
import '../../shared/artifacts.dart';

const intentNames = [
  'restore-intent.json',
  'update-intent.json',
  'core-remove-intent.json',
  'engine-intent.json',
  'panel-update-intent.json',
];
Map<String, dynamic> consumeRequest(int uid, {bool remove = true}) {
  const path = '$state/inbox/request.json';
  final value = object(
    jsonDecode(utf8.decode(host.read(path, limit: 4096, uid: uid))),
  );
  const keys = {
    'backup': {'id', 'action'},
    'restore': {'id', 'action', 'backupId'},
    'update': {'id', 'action', 'core', 'tag'},
    'install': {'id', 'action', 'core', 'tag'},
    'remove': {'id', 'action', 'core'},
    'panel-update': {'id', 'action', 'tag'},
    'install-sni-scanner': {'id', 'action'},
  };
  final action = value['action'];
  require(
    value['id'] is String &&
        identityPattern.hasMatch(value['id']) &&
        keys.containsKey(action),
    'request_invalid',
  );
  require(
    value.length == keys[action]!.length &&
        keys[action]!.every(value.containsKey),
    'request_invalid',
  );
  if (action == 'restore')
    require(
      value['backupId'] is String &&
          identityPattern.hasMatch(value['backupId']),
      'request_invalid',
    );
  if (['update', 'install', 'remove'].contains(action))
    require(repositories.containsKey(value['core']), 'request_invalid');
  if (['update', 'install'].contains(action))
    require(
      value['tag'] is String && coreTagPattern.hasMatch(value['tag']),
      'request_invalid',
    );
  if (action == 'panel-update')
    require(
      value['tag'] is String &&
          (value['tag'] as String).startsWith('v') &&
          parseVersion(value['tag']) != null,
      'request_invalid',
    );
  if (remove) unlink(path);
  return value;
}
