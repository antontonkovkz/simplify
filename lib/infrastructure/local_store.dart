import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LocalStore {
  LocalStore(this.directory);
  final Directory directory;
  final _secure = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  Future<String>? _installation;
  int _backupSerial = 0;
  Future<void> _pending = Future.value();

  static Future<LocalStore> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return LocalStore(dir);
  }

  Future<Map<String, dynamic>> read(String key) async {
    final file = File(p.join(directory.path, '$key.json'));
    if (!await file.exists()) return {};
    final text = await file.readAsString();
    try {
      return text.length < 32768
          ? _decodeSnapshot(text)
          : await compute(_decodeSnapshot, text);
    } on Object catch (error) {
      if (error is! FormatException &&
          error is! UnsupportedError &&
          error is! TypeError) {
        rethrow;
      }
      // Keep the damaged file for recovery; never turn it into a deletion plan.
      var backup = File('${file.path}.damaged');
      while (true) {
        try {
          await backup.create(exclusive: true);
          break;
        } on FileSystemException {
          if (!await backup.exists()) rethrow;
          backup = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}-${_backupSerial++}.damaged',
          );
        }
      }
      await backup.writeAsString(text, flush: true);
      return {};
    }
  }

  Future<void> write(String key, Map<String, dynamic> value) {
    // Encode a detached snapshot before joining the serialized write chain.
    final small = value.values.every(
      (v) =>
          v == null ||
          v is bool ||
          v is num ||
          (v is String && v.length < 8192),
    );
    final snapshot = small
        ? Future.value(_encodeSnapshot(value))
        : compute(_encodeSnapshot, value);
    final next = _pending.then((_) async {
      final file = File(p.join(directory.path, '$key.json'));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(await snapshot, flush: true);
      await temp.rename(file.path);
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<String?> readSession() => _secure.read(key: 'session');
  Future<String> installationId() => _installation ??= _createInstallationId()
      .catchError((Object error, StackTrace stack) {
        _installation = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<String> _createInstallationId() async {
    final data = await read('installation');
    final existing = data['deviceId'];
    if (existing is String && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final id =
        'simplefy-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    await write('installation', {...data, 'deviceId': id});
    return id;
  }

  Future<void> saveSession(String value) =>
      _secure.write(key: 'session', value: value);
  Future<void> deleteSession() => _secure.delete(key: 'session');
}

Map<String, dynamic> _decodeSnapshot(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('Invalid snapshot object');
  final value = Map<String, dynamic>.from(decoded);
  if (!value.containsKey('schemaVersion')) {
    return value; // Initial development snapshots.
  }
  if (value['schemaVersion'] != 1) {
    throw UnsupportedError('Unsupported local data version');
  }
  if (value['data'] is! Map) {
    throw const FormatException('Invalid snapshot data');
  }
  return Map<String, dynamic>.from(value['data'] as Map);
}

String _encodeSnapshot(Map<String, dynamic> value) =>
    jsonEncode({'schemaVersion': 1, 'data': value});
