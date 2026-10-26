import 'server_http_client.dart';
import '../application/playback_ports.dart';
import 'jellyfin_playback.dart';
import '../l10n/l10n.dart';
import '../domain/item_id.dart';
import '../application/app_build.dart';
import 'dart:io';
import 'dart:async';
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
  factory ServerSession.fromJson(Map<String, dynamic> json) {
    final server = json['server'];
    final token = json['token'];
    final uri = server is String ? Uri.tryParse(server) : null;
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        token is! String ||
        token.isEmpty ||
        json['username'] is! String) {
      throw const FormatException('Invalid saved session');
    }
    return ServerSession(
      server as String,
      serverItemId(json['userId']),
      token,
      json['username'] as String,
    );
  }
}

class JellyfinLibrary
    implements MusicLibrary, ManagedPlaylists, PlaybackLibrary {
  JellyfinLibrary(
    this.session, {
    http.Client? client,
    this.deviceId = 'simplefy-ios',
    bool? android,
  }) : android = android ?? Platform.isAndroid,
       _client = ServerHttpClient(client ?? http.Client());
  final ServerSession session;
  final String deviceId;
  final bool android;
  late final _playback = JellyfinPlayback(
    server: session.server,
    userId: session.userId,
    deviceId: deviceId,
    headers: () => headers,
    client: _client,
    android: android,
  );
  Future<void> prepareDownload(LibraryItem track, {http.Client? transport}) =>
      _playback.prepareDownload(track, transport: transport);
  @override
  Future<RemotePlayback> resolvePlayback(
    LibraryItem track, {
    Duration position = Duration.zero,
    http.Client? transport,
  }) => _playback.resolve(track, position: position, transport: transport);
  final ServerHttpClient _client;
  static String get clientAuthorization =>
      'MediaBrowser Client="Simplefy", Device="${Platform.isAndroid ? 'Android' : 'iPhone'}", DeviceId="simplefy-ios", Version="${AppBuild.version}"';

  @override
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
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final input = server.trim().replaceAll(RegExp(r'/+$'), '');
    final normalized = input.contains('://') ? input : 'https://$input';
    final parsed = Uri.tryParse(normalized);
    if (parsed == null ||
        parsed.host.isEmpty ||
        !['http', 'https'].contains(parsed.scheme) ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw const AppFailure(AppMessage.enterYourJellyfinServerAddress);
    }
    final transport = client ?? http.Client();
    try {
      final response = await transport
          .post(
            Uri.parse('$normalized/Users/AuthenticateByName'),
            headers: {
              'Authorization': authorizationFor(deviceId),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'Username': username.trim(), 'Pw': password}),
          )
          .timeout(timeout);
      if (response.statusCode == 401) {
        throw const AppFailure(
          AppMessage.incorrectUsernameOrPassword,
          status: 401,
        );
      }
      if (response.statusCode != 200) {
        throw AppFailure(AppMessage.serverUnavailable(response.statusCode));
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw const AppFailure(AppMessage.invalidServerResponse);
      }
      if (decoded is! Map ||
          decoded['User'] is! Map ||
          decoded['AccessToken'] is! String ||
          (decoded['AccessToken'] as String).isEmpty) {
        throw const AppFailure(AppMessage.invalidServerResponse);
      }
      final user = decoded['User'] as Map;
      String id;
      try {
        id = serverItemId(user['Id']);
      } on FormatException {
        throw const AppFailure(AppMessage.invalidServerResponse);
      }
      return ServerSession(
        normalized,
        id,
        decoded['AccessToken'] as String,
        username.trim(),
      );
    } on HandshakeException {
      throw const AppFailure(AppMessage.serverCertificateError);
    } on TimeoutException {
      throw const AppFailure(AppMessage.serverConnectionTimeout);
    } on SocketException {
      throw const AppFailure(AppMessage.noServerConnection);
    } finally {
      if (client == null) transport.close();
    }
  }

  bool get serverUnavailable => _client.unavailable;
  set onConnectionChanged(void Function(bool)? callback) =>
      _client.onConnectionChanged = callback;
  void allowConnectionRetry() => _client.allowRetry();
  Future<bool> checkConnection() async {
    _client.allowRetry();
    try {
      await get('/System/Info/Public');
      return !serverUnavailable;
    } on Object {
      return false;
    }
  }

  Future<void> logout() async {
    final response = await _client
        .post(uri('/Sessions/Logout'), headers: headers)
        .timeout(const Duration(seconds: 8));
    if (![200, 204, 401].contains(response.statusCode)) {
      throw AppFailure(
        AppMessage.serverError(response.statusCode),
        status: response.statusCode,
      );
    }
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
        AppMessage.yourSessionExpiredOpenConnectionSettingsTo,
        status: 401,
      );
    }
    if (response.statusCode != 200) {
      throw AppFailure(
        AppMessage.serverError(response.statusCode),
        status: response.statusCode,
      );
    }
    final text = response.body;
    Map<String, dynamic> decode() =>
        Map<String, dynamic>.from(jsonDecode(text) as Map);
    return text.length < 32768 ? decode() : Isolate.run(decode);
  }

  /// Owners and explicitly shared editors may update a playlist. Public access
  /// and administrator status alone do not grant this permission.
  @override
  Future<bool> canEditPlaylist(String id) async {
    try {
      final permission = await get(
        '/Playlists/${serverItemId(id)}/Users/${serverItemId(session.userId)}',
      );
      return permission['CanEdit'] == true;
    } on AppFailure catch (error) {
      if (error.status == 403 || error.status == 404) return false;
      rethrow;
    }
  }

  @override
  Future<List<String>> playlistIds(String id) async {
    final data = await get('/Playlists/${serverItemId(id)}');
    final ids = data['ItemIds'];
    if (ids is! List || ids.any((id) => id is! String)) {
      throw const AppFailure(
        AppMessage.thisServerDoesNotSupportSavingPlaylists,
      );
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
        throw const AppFailure(AppMessage.someTracksAreUnavailableOnTheServer);
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
          uri('/Playlists/${serverItemId(id)}'),
          headers: headers,
          body: await Isolate.run(() => jsonEncode({'Ids': ids})),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 403) {
      throw const AppFailure(
        AppMessage.youDoNotHavePermissionToEdit,
        status: 403,
      );
    }
    if (response.statusCode == 401) {
      throw const AppFailure(
        AppMessage.yourSessionExpiredSignInAgain,
        status: 401,
      );
    }
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw AppFailure(
        AppMessage.couldNotSaveThePlaylist(response.statusCode),
        status: response.statusCode,
      );
    }
  }

  @override
  Future<LibraryItem> createPlaylist(
    String name,
    List<String> ids, {
    required bool Function() isCurrent,
  }) async {
    final userId = session.userId;
    final body = await Isolate.run(
      () => jsonEncode({
        'Name': name,
        'Ids': ids,
        'UserId': userId,
        'MediaType': 'Audio',
        'IsPublic': false,
      }),
    );
    if (!isCurrent()) throw const AppFailure(AppMessage.theAccountHasChanged);
    final http.Response response;
    try {
      response = await _client
          .post(uri('/Playlists'), headers: headers, body: body)
          .timeout(const Duration(seconds: 30));
    } on IOException {
      throw const AppFailure(AppMessage.playlistCreationUncertain);
    } on http.ClientException {
      throw const AppFailure(AppMessage.playlistCreationUncertain);
    } on TimeoutException {
      throw const AppFailure(AppMessage.playlistCreationUncertain);
    }
    if (response.statusCode == 401) {
      throw const AppFailure(
        AppMessage.yourSessionExpiredSignInAgain,
        status: 401,
      );
    }
    if (response.statusCode == 403) {
      throw const AppFailure(
        AppMessage.cannotCreateServerPlaylist,
        status: 403,
      );
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw AppFailure(
        response.statusCode >= 500
            ? AppMessage.playlistCreationUncertain
            : AppMessage.couldNotSaveThePlaylist(response.statusCode),
        status: response.statusCode,
      );
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final id = data['Id'];
      if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
        throw const FormatException();
      }
      return LibraryItem(id: id, name: name, kind: ItemKind.playlist);
    } on Object catch (_) {
      throw const AppFailure(AppMessage.playlistCreationUncertain);
    }
  }

  @override
  Future<void> deletePlaylist(
    LibraryItem item, {
    required bool Function() isCurrent,
  }) async {
    // DELETE /Items can delete media too. Check both the requested model and
    // the current server type before ever sending this endpoint a playlist ID.
    if (!item.isPlaylist ||
        item.isLocalPlaylist ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(item.id)) {
      throw const AppFailure(AppMessage.onlyPlaylistsCanBeDeleted);
    }
    Map<String, dynamic> data;
    try {
      data = await get('/Items/${serverItemId(item.id)}', {
        'UserId': session.userId,
      });
    } on AppFailure catch (error) {
      if (error.status == 404) return;
      if (error.status == 403) {
        throw const AppFailure(
          AppMessage.cannotDeleteServerPlaylist,
          status: 403,
        );
      }
      rethrow;
    }
    if (data['Type'] != 'Playlist' ||
        normalizeItemId(data['Id'] as String? ?? '') !=
            normalizeItemId(item.id)) {
      throw const AppFailure(AppMessage.onlyPlaylistsCanBeDeleted);
    }
    if (data['CanDelete'] == false) {
      throw const AppFailure(
        AppMessage.cannotDeleteServerPlaylist,
        status: 403,
      );
    }
    if (!isCurrent()) throw const AppFailure(AppMessage.theAccountHasChanged);
    final response = await _client
        .delete(uri('/Items/${serverItemId(item.id)}'), headers: headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401 || response.statusCode == 403) {
      // Jellyfin may return 401 for CanDelete=false, not just an expired token.
      throw AppFailure(
        AppMessage.cannotDeleteServerPlaylist,
        status: response.statusCode,
      );
    }
    if (![200, 204, 404].contains(response.statusCode)) {
      throw AppFailure(
        AppMessage.couldNotDeletePlaylist(response.statusCode),
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
      id: serverItemId(item['Id']),
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
      items.addAll(
        raw.length <= 32
            ? raw.map(parse).toList()
            : await Isolate.run(() => raw.map(parse).toList()),
      );
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
      data = await get('/Users/${serverItemId(session.userId)}/Views');
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
      ? await _items('/Playlists/${serverItemId(parent.id)}/Items', {})
      : (await _items('/Items', {
          'ParentId': parent.id,
          'Recursive': 'false',
        }, sort: true)).map((e) => e.withParent(parent.id)).toList();

  Future<LibraryItem> item(String id) async => parse(
    await get('/Items/${serverItemId(id)}', {
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
        throw const AppFailure(AppMessage.trackCountUnavailable);
      }
      return count.toInt();
    }
    // The playlist endpoint has no Audio filter. Read only lightweight entries
    // and count their types so mixed-media playlists and repeats stay correct.
    var offset = 0;
    var count = 0;
    while (true) {
      final page = await get('/Playlists/${serverItemId(parent.id)}/Items', {
        'UserId': session.userId,
        'StartIndex': '$offset',
        'Limit': '300',
        'EnableImages': 'false',
        'EnableUserData': 'false',
      });
      final items = page['Items'];
      if (items is! List) {
        throw const AppFailure(AppMessage.trackCountUnavailable);
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

  @override
  bool requiresConversion(LibraryItem track) =>
      _playback.requiresConversion(track);

  @override
  Uri streamUri(LibraryItem track, {String? playSessionId}) =>
      requiresConversion(track)
      ? uri('/Audio/${serverItemId(track.id)}/stream.mp3', {
          'AudioCodec': 'mp3',
          'AudioBitRate': '320000',
          'Static': 'false',
          'DeviceId': deviceId,
          'PlaySessionId': ?playSessionId,
        })
      : uri('/Audio/${serverItemId(track.id)}/stream', {'static': 'true'});
  Uri downloadUri(LibraryItem track) => requiresConversion(track)
      ? uri('/Audio/${serverItemId(track.id)}/stream.mp3', {
          'AudioCodec': 'mp3',
          'AudioBitRate': '320000',
          'Static': 'false',
        })
      : uri('/Items/${serverItemId(track.id)}/Download');
  void close() => _client.close();

  @override
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
    } on Object catch (_) {
      /* The server also cleans up abandoned playback sessions. */
    }
  }

  @override
  Future<SourceAvailability> availability(LibraryItem track) async {
    try {
      final response = await _client
          .head(
            uri('/Audio/${serverItemId(track.id)}/stream', {'static': 'true'}),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 401) return SourceAvailability.unauthorized;
      if ([403, 404, 410].contains(response.statusCode)) {
        return SourceAvailability.missing;
      }
      if (response.statusCode >= 500) return SourceAvailability.unreachable;
      return SourceAvailability.available;
    } on Object catch (_) {
      return SourceAvailability.unreachable;
    }
  }
}
