import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

Response failure(
  String code,
  int status, {
  Map<String, String> fields = const {},
}) => Response.json(
  statusCode: status,
  body: {'error': ApiError(code, fields: fields).toJson()},
);
