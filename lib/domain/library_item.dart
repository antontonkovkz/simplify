import 'item_id.dart';

enum ItemKind { collection, folder, playlist, track }

class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.fileName = '',
    this.artist = '',
    this.durationMs = 0,
    this.path = '',
    this.normalizationGainDb,
    this.albumNormalizationGainDb,
  });

  final String id;
  final String name;
  final ItemKind kind;
  final String? parentId;
  final String fileName;
  final String artist;
  final int durationMs;
  final String path;
  final double? normalizationGainDb;
  final double? albumNormalizationGainDb;

  bool get isTrack => kind == ItemKind.track;
  bool get isLocal => id.startsWith('local:');
  bool get isLocalPlaylist => id.startsWith('local-playlist:');
  bool get isPlaylist => kind == ItemKind.playlist;

  /// Imported playlist files, rather than playlists managed by Jellyfin.
  /// Do not infer this from the display name or the user's edit permissions.
  bool get isFilePlaylist {
    if (!isPlaylist || isLocalPlaylist) return false;
    final source = (path.isNotEmpty ? path : fileName)
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase();
    final dot = source.lastIndexOf('.');
    return dot >= 0 &&
        const {
          '.m3u',
          '.m3u8',
          '.pls',
          '.wpl',
          '.zpl',
          '.asx',
          '.xspf',
        }.contains(source.substring(dot));
  }

  LibraryItem withParent(String? value) => LibraryItem(
    id: id,
    name: name,
    kind: kind,
    parentId: value,
    fileName: fileName,
    artist: artist,
    durationMs: durationMs,
    path: path,
    normalizationGainDb: normalizationGainDb,
    albumNormalizationGainDb: albumNormalizationGainDb,
  );
  String get filenameTitle {
    if (fileName.isEmpty) return name;
    final value = fileName.isEmpty ? name : fileName;
    final dot = value.lastIndexOf('.');
    return dot > 0 ? value.substring(0, dot) : value;
  }

  String get title =>
      name.trim().isNotEmpty && artist.trim().isNotEmpty ? name : filenameTitle;
  String get subtitle =>
      name.trim().isNotEmpty && artist.trim().isNotEmpty ? artist : '';

  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    return isTrack &&
        [fileName, name, artist].any((s) => s.toLowerCase().contains(needle));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'parentId': parentId,
    'fileName': fileName,
    'artist': artist,
    'durationMs': durationMs,
    'path': path,
    if (normalizationGainDb?.isFinite == true)
      'normalizationGainDb': normalizationGainDb,
    if (albumNormalizationGainDb?.isFinite == true)
      'albumNormalizationGainDb': albumNormalizationGainDb,
  };

  factory LibraryItem.fromJson(Map<String, dynamic> json) => LibraryItem(
    id: libraryItemId(json['id']),
    name: json['name'] as String,
    kind: ItemKind.values.byName(json['kind'] as String),
    parentId: json['parentId'] as String?,
    fileName: json['fileName'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    durationMs:
        json['durationMs'] is num &&
            (json['durationMs'] as num).isFinite &&
            (json['durationMs'] as num) >= 0
        ? (json['durationMs'] as num).clamp(0, 1 << 52).toInt()
        : 0,
    path: json['path'] as String? ?? '',
    normalizationGainDb: finiteGain(json['normalizationGainDb']),
    albumNormalizationGainDb: finiteGain(json['albumNormalizationGainDb']),
  );
}

int compareItems(LibraryItem a, LibraryItem b) {
  if (a.isTrack != b.isTrack) return a.isTrack ? 1 : -1;
  final left = a.isTrack ? a.filenameTitle : a.name;
  final right = b.isTrack ? b.filenameTitle : b.name;
  final result = left.toLowerCase().compareTo(right.toLowerCase());
  return result != 0 ? result : a.id.compareTo(b.id);
}

List<LibraryItem> decodeItems(Object? json) {
  if (json is! List) return [];
  final items = <LibraryItem>[];
  for (final raw in json) {
    try {
      if (raw is Map) {
        items.add(LibraryItem.fromJson(Map<String, dynamic>.from(raw)));
      }
    } on FormatException {
      continue;
    } on TypeError {
      continue;
    } on ArgumentError {
      continue;
    }
  }
  return items;
}

/// Missing, malformed or non-finite metadata must not silence playback.
double? finiteGain(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;
