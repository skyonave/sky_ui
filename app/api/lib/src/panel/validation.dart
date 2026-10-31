import 'dart:io';

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
