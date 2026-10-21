import 'dart:io';
import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../application/ports.dart';
import '../domain/library_item.dart';

class ServerSession {
  const ServerSession(this.server, this.userId, this.token, this.username);
  final String server;
  final String userId;
  final String token;
  final String username;
  Map<String, dynamic> toJson() => {
    'server': server,
    'userId': userId,
    'token': token,
    'username': username,
  };
  factory ServerSession.fromJson(Map<String, dynamic> json) => ServerSession(
    json['server'] as String,
    json['userId'] as String,
    json['token'] as String,
    json['username'] as String,
  );
}

class JellyfinLibrary implements MusicLibrary, ServerPlaylists {
  JellyfinLibrary(
    this.session, {
    http.Client? client,
    this.deviceId = 'simplefy-ios',
  }) : _client = client ?? http.Client();
  final ServerSession session;
  final String deviceId;
  final http.Client _client;
  static final clientAuthorization =
      'MediaBrowser Client="Simplefy", Device="${Platform.isAndroid ? 'Android' : 'iPhone'}", DeviceId="simplefy-ios", Version="0.6.5"';

  Map<String, String> get headers => {
    'Authorization': '${authorizationFor(deviceId)}, Token="${session.token}"',
    'Content-Type': 'application/json',
  };
  static String authorizationFor(String deviceId) => clientAuthorization
      .replaceFirst('DeviceId="simplefy-ios"', 'DeviceId="$deviceId"');

  Uri uri(String path, [Map<String, String> query = const {}]) => Uri.parse(
    '${session.server}$path',
  ).replace(queryParameters: query.isEmpty ? null : query);

  static Future<ServerSession> login(
    String server,
    String username,
    String password, {
    String deviceId = 'simplefy-ios',
  }) async {
    final input = server.trim().replaceAll(RegExp(r'/+$'), '');
    final normalized = input.contains('://') ? input : 'https://$input';
    final parsed = Uri.tryParse(normalized);
    if (parsed == null ||
        parsed.host.isEmpty ||
        !['http', 'https'].contains(parsed.scheme)) {
      throw const AppFailure('Укажите адрес сервера Jellyfin');
    }
    final response = await http
        .post(
          Uri.parse('$normalized/Users/AuthenticateByName'),
          headers: {
            'Authorization': authorizationFor(deviceId),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'Username': username.trim(), 'Pw': password}),
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode == 401) {
      throw const AppFailure('Неверный логин или пароль', status: 401);
    }
    if (response.statusCode != 200) {
      throw AppFailure('Сервер недоступен (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return ServerSession(
      normalized,
      data['User']['Id'] as String,
      data['AccessToken'] as String,
      username.trim(),
    );
  }

  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final response = await _client
        .get(uri(path, query), headers: headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401) {
      throw const AppFailure(
        'Сессия истекла. Войдите в настройки подключения.',
        status: 401,
      );
    }
    if (response.statusCode != 200) {
      throw AppFailure(
        'Ошибка сервера (${response.statusCode})',
        status: response.statusCode,
      );
    }
    final text = response.body;
    return Isolate.run(
      () => Map<String, dynamic>.from(jsonDecode(text) as Map),
    );
  }

  /// Owners and explicitly shared editors may update a playlist. Public access
  /// and administrator status alone do not grant this permission.
  @override
  Future<bool> canEditPlaylist(String id) async {
    try {
      final permission = await get('/Playlists/$id/Users/${session.userId}');
      return permission['CanEdit'] == true;
    } on AppFailure catch (error) {
      if (error.status == 403 || error.status == 404) return false;
      rethrow;
    }
  }

  @override
  Future<List<String>> playlistIds(String id) async {
    final data = await get('/Playlists/$id');
    final ids = data['ItemIds'];
    if (ids is! List || ids.any((id) => id is! String)) {
      throw const AppFailure('Сервер не поддерживает сохранение плейлистов');
    }
    return ids.cast<String>();
  }

  /// Validate all IDs before updating: Jellyfin silently skips unavailable IDs.
  @override
  Future<void> validatePlaylistTracks(List<String> ids) async {
    final unique = ids.toSet().toList();
    for (var start = 0; start < unique.length; start += 150) {
      final batch = unique.skip(start).take(150).toList();
      final data = await get('/Items', {
        'UserId': session.userId,
        'Ids': batch.join(','),
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'Limit': '${batch.length}',
        'EnableImages': 'false',
        'EnableUserData': 'false',
      });
      final available = (data['Items'] as List? ?? [])
          .whereType<Map>()
          .where((item) => item['Type'] == 'Audio')
          .map((item) => normalizeItemId(item['Id'] as String))
          .toSet();
      if (batch.any((id) => !available.contains(normalizeItemId(id)))) {
        throw const AppFailure(
          'Некоторые композиции недоступны на сервере. Удалите их из сохраняемого списка или сохраните локальный плейлист.',
        );
      }
    }
  }

  @override
  Future<void> replacePlaylist(String id, List<String> ids) async {
    // Omit Name, Users and IsPublic: null/absent fields keep existing metadata.
    // One update request avoids a client-side delete/add sequence. The server
    // does not promise a transaction, so callers verify the resulting contents.
    final response = await _client
        .post(
          uri('/Playlists/$id'),
          headers: headers,
          body: await Isolate.run(() => jsonEncode({'Ids': ids})),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 403) {
      throw const AppFailure(
        'Нет права редактировать этот плейлист',
        status: 403,
      );
    }
    if (response.statusCode == 401) {
      throw const AppFailure('Сессия истекла. Войдите снова.', status: 401);
    }
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw AppFailure(
        'Не удалось сохранить плейлист (${response.statusCode})',
        status: response.statusCode,
      );
    }
  }

  static String normalizeItemId(String id) =>
      id.replaceAll('-', '').toLowerCase();

  static LibraryItem parse(Map<String, dynamic> item) {
    final path = item['Path'] as String? ?? '';
    final fileName = path.replaceAll('\\', '/').split('/').last;
    final type = item['Type'];
    final kind = switch (type) {
      'Audio' => ItemKind.track,
      'Playlist' => ItemKind.playlist,
      'CollectionFolder' || 'UserView' => ItemKind.collection,
      _ => ItemKind.folder,
    };
    return LibraryItem(
      id: item['Id'] as String,
      name: kind == ItemKind.folder && fileName.isNotEmpty
          ? fileName
          : item['Name'] as String? ?? fileName,
      kind: kind,
      parentId: item['ParentId'] as String?,
      fileName: fileName,
      artist: (item['Artists'] as List? ?? []).join(', '),
      durationMs: ((item['RunTimeTicks'] as num? ?? 0) / 10000).round(),
      path: path,
      normalizationGainDb: finiteGain(item['NormalizationGain']),
      albumNormalizationGainDb: finiteGain(item['AlbumNormalizationGain']),
    );
  }

  Future<List<LibraryItem>> _items(
    String endpoint,
    Map<String, String> query, {
    bool sort = false,
  }) async {
    final items = <LibraryItem>[];
    var offset = 0;
    while (true) {
      final data = await get(endpoint, {
        'UserId': session.userId,
        'Fields': 'Path,ParentId,DateModified',
        ...query,
        'StartIndex': '$offset',
        'Limit': '300',
      });
      final raw = (data['Items'] as List? ?? []).cast<Map<String, dynamic>>();
      items.addAll(await Isolate.run(() => raw.map(parse).toList()));
      offset += raw.length;
      if (raw.isEmpty ||
          offset >= (data['TotalRecordCount'] as int? ?? offset)) {
        break;
      }
    }
    if (sort) items.sort(compareItems);
    return items;
  }

  @override
  Future<List<LibraryItem>> collections() async {
    Map<String, dynamic> data;
    try {
      data = await get('/UserViews', {'UserId': session.userId});
    } on AppFailure catch (e) {
      if (e.status != 404) rethrow;
      data = await get('/Users/${session.userId}/Views');
    }
    return (data['Items'] as List)
        .cast<Map<String, dynamic>>()
        .where((e) => e['CollectionType'] == 'music')
        .map(parse)
        .toList()
      ..sort(compareItems);
  }

  @override
  Future<List<LibraryItem>> playlists() => _items('/Items', {
    'Recursive': 'true',
    'IncludeItemTypes': 'Playlist',
  }, sort: true);

  @override
  Future<List<LibraryItem>> children(LibraryItem parent) async =>
      parent.isPlaylist
      ? await _items('/Playlists/${parent.id}/Items', {})
      : (await _items('/Items', {
          'ParentId': parent.id,
          'Recursive': 'false',
        }, sort: true)).map((e) => e.withParent(parent.id)).toList();

  Future<LibraryItem> item(String id) async => parse(
    await get('/Items/$id', {
      'UserId': session.userId,
      'Fields': 'Path,ParentId',
    }),
  );

  @override
  Future<List<LibraryItem>> tracks(
    LibraryItem parent, {
    bool recursive = true,
  }) async {
    if (parent.isTrack) return [parent];
    if (parent.isPlaylist) {
      return (await children(parent)).where((e) => e.isTrack).toList();
    }
    final items = await _items('/Items', {
      'ParentId': parent.id,
      'Recursive': '$recursive',
      'IncludeItemTypes': 'Audio',
    });
    items.sort(
      (a, b) => (recursive ? a.path : a.fileName).toLowerCase().compareTo(
        (recursive ? b.path : b.fileName).toLowerCase(),
      ),
    );
    return recursive
        ? items
        : items.map((e) => e.withParent(parent.id)).toList();
  }

  /// Count only playable Audio items; playlist occurrences are not deduplicated.
  Future<int> trackCount(LibraryItem parent) async {
    if (parent.isTrack) return 1;
    if (!parent.isPlaylist) {
      final result = await get('/Items', {
        'UserId': session.userId,
        'ParentId': parent.id,
        'Recursive': 'true',
        'IncludeItemTypes': 'Audio',
        'EnableTotalRecordCount': 'true',
        'EnableImages': 'false',
        'EnableUserData': 'false',
        'Limit': '0',
      });
      final count = result['TotalRecordCount'];
      if (count is! num || count < 0) {
        throw const AppFailure('Количество композиций недоступно');
      }
      return count.toInt();
    }
    // The playlist endpoint has no Audio filter. Read only lightweight entries
    // and count their types so mixed-media playlists and repeats stay correct.
    var offset = 0;
    var count = 0;
    while (true) {
      final page = await get('/Playlists/${parent.id}/Items', {
        'UserId': session.userId,
        'StartIndex': '$offset',
        'Limit': '300',
        'EnableImages': 'false',
        'EnableUserData': 'false',
      });
      final items = page['Items'];
      if (items is! List) {
        throw const AppFailure('Количество композиций недоступно');
      }
      count += items.where((e) => e is Map && e['Type'] == 'Audio').length;
      offset += items.length;
      final total = page['TotalRecordCount'] as num?;
      if (items.isEmpty ||
          (total != null && offset >= total) ||
          (total == null && items.length < 300)) {
        break;
      }
    }
    return count;
  }

  Future<List<LibraryItem>> folderTree(LibraryItem parent) => _items('/Items', {
    'ParentId': parent.id,
    'Recursive': 'true',
    'Filters': 'IsFolder',
  }, sort: true);

  bool requiresConversion(LibraryItem track) => const [
    'ape',
    'ogg',
    'opus',
    'wma',
  ].contains(track.fileName.split('.').last.toLowerCase());

  Uri streamUri(LibraryItem track, {String? playSessionId}) =>
      requiresConversion(track)
      ? uri('/Audio/${track.id}/main.m3u8', {
          'TranscodingContainer': 'ts',
          'SegmentContainer': 'ts',
          'AudioCodec': 'aac',
          'AudioBitRate': '320000',
          'DeviceId': deviceId,
          'PlaySessionId': ?playSessionId,
          // HLS child requests must authenticate independently. This URI stays
          // in the audio adapter; queue snapshots and MediaItem IDs never use it.
          'api_key': session.token,
        })
      : uri('/Audio/${track.id}/stream', {'static': 'true'});
  Uri downloadUri(LibraryItem track) => requiresConversion(track)
      ? uri('/Audio/${track.id}/stream.mp3', {
          'AudioCodec': 'mp3',
          'AudioBitRate': '320000',
          'Static': 'false',
        })
      : uri('/Items/${track.id}/Download');
  void close() => _client.close();

  Future<void> releaseStream(String playSessionId) async {
    try {
      await _client
          .delete(
            uri('/Videos/ActiveEncodings', {
              'DeviceId': deviceId,
              'PlaySessionId': playSessionId,
            }),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      /* The server also cleans up abandoned playback sessions. */
    }
  }

  Future<SourceAvailability> availability(LibraryItem track) async {
    try {
      final response = await _client
          .head(
            uri('/Audio/${track.id}/stream', {'static': 'true'}),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 401) return SourceAvailability.unauthorized;
      if ([403, 404, 410].contains(response.statusCode)) {
        return SourceAvailability.missing;
      }
      if (response.statusCode >= 500) return SourceAvailability.unreachable;
      return SourceAvailability.available;
    } catch (_) {
      return SourceAvailability.unreachable;
    }
  }
}
