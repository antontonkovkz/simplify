import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import '../application/playback_ports.dart';
import '../application/ports.dart';
import '../domain/item_id.dart';
import '../domain/library_item.dart';
import '../l10n/app_message.dart';

/// Negotiates audio codecs/containers with the server. URLs and tokens are
/// ephemeral; the bounded cache retains only a conversion decision per ID.
class JellyfinPlayback {
  JellyfinPlayback({
    required this.server,
    required this.userId,
    required this.deviceId,
    required this.headers,
    required this.client,
    required this.android,
  });
  final String server, userId, deviceId;
  final Map<String, String> Function() headers;
  final http.Client client;
  final bool android;
  final _conversions = <String, bool>{};
  final _pending = <String, Future<void>>{};

  String get containers => android
      ? 'mp3,aac,m4a,mp4,flac,wav,ogg,oga,opus,webm,mka'
      : 'mp3,aac,m4a,mp4,alac,flac,wav,aif,aiff,caf';
  Map<String, Object> get profile => {
    'Name': android ? 'Simplefy Android' : 'Simplefy iOS',
    'MaxStreamingBitrate': 20000000,
    'DirectPlayProfiles': [
      {
        'Type': 'Audio',
        'Container': containers,
        'AudioCodec': android
            ? 'mp3,aac,flac,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le'
            : 'mp3,aac,alac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be,pcm_s24be',
      },
    ],
    'TranscodingProfiles': [
      {
        'Type': 'Audio',
        'Container': 'mp3',
        'AudioCodec': 'mp3',
        'Protocol': 'http',
        'Context': 'Streaming',
        'MaxAudioChannels': '2',
      },
    ],
  };
  bool requiresConversion(LibraryItem track) =>
      _conversions[track.id] ?? fallbackConversion(track);
  bool fallbackConversion(LibraryItem track) {
    final extension = track.fileName.split('.').last.toLowerCase();
    return track.fileName.contains('.') &&
        !containers.split(',').contains(extension);
  }

  void _remember(String id, bool converted) {
    _conversions.remove(id);
    _conversions[id] = converted;
    if (_conversions.length > 64) _conversions.remove(_conversions.keys.first);
  }

  Uri _uri(String path, [Map<String, String> query = const {}]) => Uri.parse(
    '$server$path',
  ).replace(queryParameters: query.isEmpty ? null : query);

  Future<void> prepareDownload(LibraryItem track, {http.Client? transport}) {
    if (_conversions.containsKey(track.id)) return Future.value();
    return _pending[track.id] ??= resolve(track, transport: transport)
        .then<void>((_) {})
        .whenComplete(() {
          unawaited(_pending.remove(track.id));
        });
  }

  Future<RemotePlayback> resolve(
    LibraryItem track, {
    Duration position = Duration.zero,
    http.Client? transport,
  }) async {
    final id = serverItemId(track.id);
    final response = await (transport ?? client)
        .post(
          _uri('/Items/$id/PlaybackInfo'),
          headers: headers(),
          body: jsonEncode({
            'UserId': serverItemId(userId),
            'DeviceProfile': profile,
            'MaxStreamingBitrate': 20000000,
            'StartTimeTicks': position.inMicroseconds * 10,
            'EnableDirectPlay': true,
            'EnableDirectStream': true,
            'EnableTranscoding': true,
            'AutoOpenLiveStream': false,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if ([404, 405, 501].contains(response.statusCode)) {
      final converted = fallbackConversion(track);
      _remember(id, converted);
      final session = converted
          ? 'simplefy-${DateTime.now().microsecondsSinceEpoch}'
          : null;
      return RemotePlayback(
        converted
            ? _uri('/Audio/$id/stream.mp3', {
                'AudioCodec': 'mp3',
                'AudioBitRate': '320000',
                'Static': 'false',
                'DeviceId': deviceId,
                'PlaySessionId': session!,
              })
            : _uri('/Audio/$id/stream', {'static': 'true'}),
        headers(),
        playSessionId: session,
      );
    }
    if (response.statusCode != 200) {
      throw AppFailure(
        AppMessage.serverError(response.statusCode),
        status: response.statusCode,
      );
    }
    final Object? decoded;
    try {
      final text = response.body;
      decoded = text.length < 32768
          ? jsonDecode(text)
          : await Isolate.run(() => jsonDecode(text));
    } on FormatException {
      throw const AppFailure(AppMessage.invalidServerResponse);
    }
    if (decoded is! Map || decoded['MediaSources'] is! List) {
      throw const AppFailure(AppMessage.invalidServerResponse);
    }
    final sources = (decoded['MediaSources'] as List).whereType<Map>();
    for (final source in sources) {
      if (source['SupportsDirectPlay'] == true) {
        _remember(id, false);
        return RemotePlayback(
          _uri('/Audio/$id/stream', {
            'static': 'true',
            if (source['Id'] is String) 'MediaSourceId': source['Id'] as String,
          }),
          headers(),
        );
      }
      if (source['TranscodingUrl'] is String) {
        final root = Uri.parse(server);
        final raw = source['TranscodingUrl'] as String;
        var url = raw.startsWith('/')
            ? root.resolve(raw)
            : Uri.parse('$server/').resolve(raw);
        if (url.scheme != root.scheme ||
            url.host != root.host ||
            url.port != root.port ||
            url.userInfo.isNotEmpty) {
          throw const AppFailure(AppMessage.invalidServerResponse);
        }
        // HTTP audio requests authenticate through headers; unlike HLS, there
        // are no child segment requests that need a token in the URL.
        if (!url.path.toLowerCase().endsWith('.m3u8')) {
          final query = Map<String, String>.of(url.queryParameters)
            ..remove('api_key')
            ..remove('access_token');
          url = url.replace(queryParameters: query);
        }
        _remember(id, true);
        return RemotePlayback(
          url,
          headers(),
          playSessionId: decoded['PlaySessionId'] is String
              ? decoded['PlaySessionId'] as String
              : null,
        );
      }
    }
    throw AppFailure(AppMessage.trackIsUnavailable(track.title));
  }
}
