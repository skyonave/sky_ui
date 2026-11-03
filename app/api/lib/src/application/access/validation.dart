import 'dart:io';

import '../../shared/api_exception.dart';

bool validAddress(String value) {
  if (value.length > 253 || value.isEmpty) return false;
  if (InternetAddress.tryParse(value) != null) return true;
  return value
      .split('.')
      .every(
        (p) =>
            p.isNotEmpty &&
            p.length <= 63 &&
            RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$').hasMatch(p),
      );
}

String validatedName(String value) {
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 80 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name))
    throw const ApiException('name_invalid', status: 422);
  return name;
}
