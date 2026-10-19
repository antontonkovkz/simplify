import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/playback_gain.dart';
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/domain/volume_normalization.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';

void main() {
  const song = LibraryItem(
    id: 'a',
    name: 'Song',
    kind: ItemKind.track,
    normalizationGainDb: -6,
    albumNormalizationGainDb: -12,
  );

  test(
    'track mode is enabled for new and existing installations; off survives restart',
    () {
      expect(
        VolumeNormalizationMode.restore(null),
        VolumeNormalizationMode.track,
      );
      expect(
        VolumeNormalizationMode.restore('unknown'),
        VolumeNormalizationMode.track,
      );
      for (final mode in VolumeNormalizationMode.values) {
        expect(VolumeNormalizationMode.restore(mode.name), mode);
      }
    },
  );

  test(
    'track and album dB map to amplitude without altering the system volume',
    () {
      expect(
        normalizedVolume(song, VolumeNormalizationMode.track),
        closeTo(0.501187, 0.000001),
      );
      expect(
        normalizedVolume(song, VolumeNormalizationMode.album),
        closeTo(0.251189, 0.000001),
      );
      expect(normalizedVolume(song, VolumeNormalizationMode.off), 1);
      expect(
        normalizedVolume(
          const LibraryItem(
            id: 'b',
            name: 'B',
            kind: ItemKind.track,
            normalizationGainDb: -6,
          ),
          VolumeNormalizationMode.album,
        ),
        closeTo(0.501187, 0.000001),
      );
    },
  );

  test(
    'missing, invalid and positive gains never amplify or silence a track',
    () {
      for (final gain in [
        null,
        double.nan,
        double.infinity,
        double.negativeInfinity,
        0.0,
        8.0,
      ]) {
        final item = LibraryItem(
          id: 'b',
          name: 'B',
          kind: ItemKind.track,
          normalizationGainDb: gain,
        );
        expect(normalizedVolume(item, VolumeNormalizationMode.track), 1);
        expect(() => jsonEncode(item.toJson()), returnsNormally);
      }
      expect(normalizedVolume(null, VolumeNormalizationMode.track), 1);
      const onlyAlbum = LibraryItem(
        id: 'c',
        name: 'C',
        kind: ItemKind.track,
        albumNormalizationGainDb: -6,
      );
      expect(normalizedVolume(onlyAlbum, VolumeNormalizationMode.track), 1);
    },
  );

  test('Jellyfin gains survive parenting, queue and offline download JSON', () {
    final parsed = JellyfinLibrary.parse({
      'Id': 'a',
      'Name': 'Song',
      'Type': 'Audio',
      'NormalizationGain': -6,
      'AlbumNormalizationGain': -12.0,
    }).withParent('folder');
    final group = DownloadGroup(source: parsed, tracks: [parsed]);
    final restored = DownloadGroup.fromJson(
      jsonDecode(jsonEncode(group.toJson())),
    );
    final queue = QueueEngine()..replace(restored.tracks);
    final reopened = QueueEngine()
      ..restore(jsonDecode(jsonEncode(queue.toJson())));
    expect(reopened.current?.track.normalizationGainDb, -6);
    expect(reopened.current?.track.albumNormalizationGainDb, -12);
    final legacy = LibraryItem.fromJson({
      'id': 'old',
      'name': 'Old',
      'kind': 'track',
    });
    expect(normalizedVolume(legacy, VolumeNormalizationMode.track), 1);
    final malformed = JellyfinLibrary.parse({
      'Id': 'bad',
      'Type': 'Audio',
      'NormalizationGain': 'invalid',
      'AlbumNormalizationGain': double.infinity,
    });
    expect(malformed.normalizationGainDb, null);
    expect(malformed.albumNormalizationGainDb, null);
  });

  test(
    'normalization metadata alone does not prompt a structural download resync',
    () {
      const legacy = LibraryItem(id: 'a', name: 'Song', kind: ItemKind.track);
      const before = DownloadGroup(source: legacy, tracks: [legacy]);
      const after = DownloadGroup(source: song, tracks: [song]);
      expect(before.fingerprint, after.fingerprint);
      expect(
        const DownloadGroup(source: song, tracks: [song, song]).fingerprint,
        isNot(after.fingerprint),
      );
    },
  );

  test(
    'changing modes ramps the gain and a new track cancels the old ramp',
    () async {
      final applied = <double>[];
      final gain = PlaybackGain((value) async => applied.add(value));
      final ramp = gain.set(0.2, smooth: true);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(applied.any((v) => v > 0.2 && v < 1), true);
      await gain.set(0.7);
      await ramp;
      expect(applied.last, 0.7);
      expect(applied.every((value) => value >= 0 && value <= 1), true);
      await gain.set(1, smooth: true);
      expect(applied.last, 1);
    },
  );

  test(
    'cancelling a ramp prevents later writes; invalid targets reset to unity',
    () async {
      final applied = <double>[];
      final gain = PlaybackGain((value) async => applied.add(value));
      final ramp = gain.set(0.1, smooth: true);
      gain.cancel();
      final writes = applied.length;
      await ramp;
      expect(applied.length, writes);
      await gain.set(double.nan);
      expect(applied.last, 1);
    },
  );
}
