import 'dart:io';

enum LocalFileState { healthy, missing, empty, changed, unreadable }

enum RecoveryAction { discard, retry, skip }

typedef FileProbe =
    Future<LocalFileState> Function(String path, int? expectedBytes);

Future<LocalFileState> inspectAudioFile(String path, int? expectedBytes) async {
  try {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return LocalFileState.missing;
    }
    if (stat.type != FileSystemEntityType.file) {
      return LocalFileState.unreadable;
    }
    if (stat.size == 0) return LocalFileState.empty;
    if (expectedBytes != null &&
        expectedBytes > 0 &&
        stat.size != expectedBytes) {
      return LocalFileState.changed;
    }
    return LocalFileState.healthy;
  } on FileSystemException {
    // Access/session/disk errors do not prove that bytes were lost.
    return LocalFileState.unreadable;
  }
}

/// Source recovery policy, independent of widgets, Jellyfin and the audio engine.
/// Decoder/time-out/session failures never establish physical file corruption.
class PlaybackRecovery {
  PlaybackRecovery({FileProbe? probe, this.maximumAttempts = 3})
    : inspect = probe ?? inspectAudioFile;
  final FileProbe inspect;
  final int maximumAttempts;
  String? _entry;
  int _attempts = 0;
  Future<RecoveryAction> failed(
    String entry,
    String path, {
    int? expectedBytes,
  }) async {
    final state = await inspect(path, expectedBytes);
    if ({
      LocalFileState.missing,
      LocalFileState.empty,
      LocalFileState.changed,
    }.contains(state)) {
      return RecoveryAction.discard;
    }
    if (_entry != entry) {
      _entry = entry;
      _attempts = 0;
    }
    return ++_attempts < maximumAttempts
        ? RecoveryAction.retry
        : RecoveryAction.skip;
  }

  void reset() {
    _entry = null;
    _attempts = 0;
  }
}
