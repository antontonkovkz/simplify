/// Server IDs are opaque path segments, never file names or relative paths.
String serverItemId(Object? value) {
  if (value is! String || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid server item identifier');
  }
  return value;
}

String libraryItemId(Object? value) {
  if (value is String &&
      value.startsWith('local:') &&
      !value.contains('\u0000')) {
    return value; // System-imported IDs contain relative paths and Unicode.
  }
  if (value is String && value.startsWith('local-playlist:')) {
    serverItemId(value.substring('local-playlist:'.length));
    return value;
  }
  return serverItemId(value);
}
