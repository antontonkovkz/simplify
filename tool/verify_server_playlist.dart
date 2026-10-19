// Explicit live contract check. Only the user-authorized `_test` playlist may
// be changed. Session JSON must be outside the repository; never print tokens.
import 'dart:convert';
import 'dart:io';

import 'package:simplefy/infrastructure/jellyfin_library.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/verify_server_playlist.dart <private-session.json>',
    );
    exitCode = 64;
    return;
  }
  final file = File(args.single).absolute;
  if (file.path.startsWith('${Directory.current.absolute.path}/')) {
    throw ArgumentError('Keep the session outside the repository');
  }
  final config = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final auth = config['authorization'] as String? ?? '';
  final deviceId = RegExp(r'DeviceId="([^"]+)"').firstMatch(auth)?.group(1);
  if (deviceId == null) {
    throw ArgumentError('Session must contain its diagnostic DeviceId');
  }
  final api = JellyfinLibrary(
    ServerSession.fromJson(config),
    deviceId: deviceId,
  );
  try {
    final playlists = (await api.playlists())
        .where((item) => item.name == '_test')
        .toList();
    if (playlists.length != 1) {
      throw StateError('Expected exactly one _test playlist');
    }
    final target = playlists.single;
    if (!await api.canEditPlaylist(target.id)) {
      stdout.writeln(
        '_test: read access works; editing permission denied; no writes performed.',
      );
      exitCode = 2;
      return;
    }
    final before = await api.get('/Playlists/${target.id}');
    final original = await api.playlistIds(target.id);
    final tracks = await api.tracks(target);
    if (tracks.length < 2) {
      throw StateError('_test needs at least two audio tracks');
    }
    final proposed = [tracks[1].id, tracks[0].id, tracks[1].id];
    await api.validatePlaylistTracks(proposed);
    final backup = File(
      '${file.parent.path}/simplefy-playlist-backup-${DateTime.now().millisecondsSinceEpoch}.json',
    );
    await backup.writeAsString(
      jsonEncode({'id': target.id, 'details': before}),
    );
    stdout.writeln(
      '_test: edit permission confirmed; backup saved outside repository.',
    );
    try {
      await api.replacePlaylist(target.id, proposed);
      final actual = await api.playlistIds(target.id);
      if (jsonEncode(actual.map(JellyfinLibrary.normalizeItemId).toList()) !=
          jsonEncode(proposed.map(JellyfinLibrary.normalizeItemId).toList())) {
        throw StateError('Order or repeated occurrences were not preserved');
      }
      final after = await api.get('/Playlists/${target.id}');
      for (final key in ['OpenAccess', 'Shares']) {
        if (jsonEncode(after[key]) != jsonEncode(before[key])) {
          throw StateError('Playlist sharing changed');
        }
      }
      if ((await api.item(target.id)).name != '_test') {
        throw StateError('Playlist name changed');
      }
      stdout.writeln(
        '_test: reordered/repeated entries verified; name and sharing preserved.',
      );
    } finally {
      await api.replacePlaylist(target.id, original);
      final restored = await api.playlistIds(target.id);
      if (jsonEncode(restored.map(JellyfinLibrary.normalizeItemId).toList()) !=
          jsonEncode(original.map(JellyfinLibrary.normalizeItemId).toList())) {
        throw StateError(
          'Restore mismatch. Original snapshot retained outside repository.',
        );
      }
      stdout.writeln(
        '_test: original contents and order restored and verified.',
      );
    }
  } finally {
    api.close();
  }
}
