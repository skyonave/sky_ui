import 'package:sky_ui_shared/sky_ui_shared.dart';

class ApiException implements Exception {
  const ApiException(this.code, {this.status = 503, this.fields = const {}});
  final String code;
  final int status;
  final Map<String, String> fields;
  ApiError get error => ApiError(code, fields: fields);
}

String redact(String value, Iterable<String> secrets) {
  var result = value;
  for (final secret in secrets.where((s) => s.isNotEmpty)) {
    result = result.replaceAll(secret, '[redacted]');
  }
  result = result.replaceAll(
    RegExp(r'(?i:bearer)\s+[^\s,;]+'),
    'Bearer [redacted]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'(?i:password|passwd|secret|token|private[-_ ]?key|uuid|authorization)\s*[:=]\s*[^\s,;]+',
    ),
    (_) => '[credential redacted]',
  );
  result = result.replaceAll(
    RegExp(r'(?<=://)[^\s/@]+:[^\s/@]+@'),
    '[redacted]@',
  );
  result = result.replaceAll(
    RegExp(
      r'(?i:[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})',
    ),
    '[uuid redacted]',
  );
  result = result.replaceAll(
    RegExp(r'/s/[A-Za-z0-9_-]{43}\.yaml'),
    '/s/[redacted]',
  );
  return result.length > 512 ? '${result.substring(0, 512)}…' : result;
}
