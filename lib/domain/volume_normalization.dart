import 'dart:math';

import 'library_item.dart';

enum VolumeNormalizationMode {
  off,
  track,
  album;

  /// Existing installations and unknown future values enable track mode too.
  static VolumeNormalizationMode restore(Object? value) =>
      values.firstWhere((mode) => mode.name == value, orElse: () => track);
}

/// Jellyfin gains are in dB relative to its loudness reference. This first
/// implementation attenuates only; positive gain never amplifies the signal.
double normalizedVolume(LibraryItem? track, VolumeNormalizationMode mode) {
  if (track == null || mode == VolumeNormalizationMode.off) return 1;
  final gain = mode == VolumeNormalizationMode.album
      ? track.albumNormalizationGainDb ?? track.normalizationGainDb
      : track.normalizationGainDb;
  if (gain == null || !gain.isFinite || gain >= 0) return 1;
  return pow(10, gain / 20).toDouble().clamp(0.0, 1.0);
}
