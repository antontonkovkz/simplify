import 'dart:async';
import '../domain/library_item.dart';
import '../domain/queue_engine.dart';
import '../l10n/app_message.dart';
import 'diagnostics.dart';
import 'ports.dart';
import 'playback_ports.dart';
import 'playback_recovery.dart';

/// Owns source loading, cancellation generations, retries and recovery.
/// The app and lock-screen commands share this one state machine.
class PlaybackCoordinator {
  PlaybackCoordinator({
    required this.queue,
    required this.audio,
    required this.libraryProvider,
    required this.downloadsProvider,
    required this.prefetchProvider,
    required this.importedPath,
    required this.streamAllowed,
    required this.changed,
    required this.notifyListeners,
    required this.message,
    required this.statusReader,
    required this.statusWriter,
    required this.next,
    required this.pause,
    required this.resume,
    required this.applyNormalization,
    required this.reportUnavailable,
    required this.resetSkipped,
    PlaybackRecovery? recovery,
    this.retryDelay = const Duration(seconds: 8),
    this.sourceTimeout = const Duration(seconds: 4),
    this.audioLoadTimeout = const Duration(seconds: 30),
  }) : playbackRecovery = recovery ?? PlaybackRecovery();
  final QueueEngine queue;
  final PlaybackAudio audio;
  final PlaybackLibrary? Function() libraryProvider;
  final PlaybackDownloads? Function() downloadsProvider;
  final PlaybackPrefetch? Function() prefetchProvider;
  final String? Function(LibraryItem) importedPath;
  final bool Function() streamAllowed;
  final void Function() changed, notifyListeners, resetSkipped;
  final void Function(Object) message;
  final Object? Function() statusReader;
  final void Function(Object?) statusWriter;
  final Future<void> Function(bool) next;
  final Future<void> Function() pause, resume;
  final Future<void> Function(LibraryItem) applyNormalization;
  final void Function(LibraryItem) reportUnavailable;
  final PlaybackRecovery playbackRecovery;
  final Duration retryDelay, sourceTimeout, audioLoadTimeout;
  PlaybackLibrary? get library => libraryProvider();
  PlaybackDownloads? get downloads => downloadsProvider();
  PlaybackPrefetch? get preloader => prefetchProvider();
  bool get canStream => streamAllowed();
  Object? get status => statusReader();
  set status(Object? value) => statusWriter(value);
  bool wantsPlayback = false, waitingForNetwork = false, loadedFromFile = false;
  String? loadedEntry, convertedSession, lastFailureEntry;
  PlaybackLibrary? _convertedLibrary;
  int operation = 0,
      restoredPosition = 0,
      failurePosition = 0,
      recoveryAttempts = 0;
  Timer? retryTimer;
  Future<void> start(
    QueueEntry? first, {
    Duration position = Duration.zero,
  }) async {
    if (first == null) return;
    final generation = ++operation;
    final api = library;
    final requestedPosition = position;
    final cache = preloader;
    if (cache is PlaybackStreamingCache) {
      (cache as PlaybackStreamingCache).activate(first.track.id);
    } else {
      cache?.cancelPending();
    }
    waitingForNetwork = false;
    retryTimer?.cancel();
    loadedEntry = null;
    audio.publishQueue(queue, position: position);
    notifyListeners();
    unawaited(releaseStream());
    await audio.pause();
    QueueEntry? entry = first;
    var serverUnavailable = false;
    var hadUsableLocal = false;
    final attempted = <String>{};
    while (entry != null && attempted.add(entry.id)) {
      if (generation != operation) return;
      if (cache is PlaybackStreamingCache) {
        (cache as PlaybackStreamingCache).activate(entry.track.id);
      }
      audio.publishQueue(queue, position: position);
      notifyListeners();
      final speculative = preloader?.localPath(entry.track.id);
      final local = entry.track.isLocal
          ? importedPath(entry.track)
          : downloads?.localPath(entry.track.id) ?? speculative;
      String? requestedSession;
      var resolvingSource = true;
      try {
        final fileState = local == null
            ? LocalFileState.missing
            : await playbackRecovery.inspect(
                local,
                (downloads?.localPath(entry.track.id) == local
                    ? downloads?.expectedBytes(entry.track.id)
                    : null),
              );
        final hasLocal =
            fileState == LocalFileState.healthy ||
            fileState == LocalFileState.unreadable;
        if (local != null && !hasLocal && !entry.track.isLocal) {
          if (local == speculative) {
            await preloader?.invalidate(entry.track.id);
          } else {
            await downloads?.invalidate(entry.track.id);
          }
          if (generation != operation) return;
        }
        if (!hasLocal &&
            (entry.track.isLocal ||
                api == null ||
                !canStream ||
                serverUnavailable)) {
          throw const AppFailure(AppMessage.noConnection);
        }
        final source = hasLocal
            ? null
            : await (cache is PlaybackStreamingCache
                      ? (cache as PlaybackStreamingCache).resolve(entry.track)
                      : api!.resolvePlayback(entry.track, position: position))
                  .timeout(sourceTimeout);
        resolvingSource = false;
        requestedSession = source?.playSessionId;
        if (generation != operation) {
          if (requestedSession != null) {
            unawaited(api?.releaseStream(requestedSession));
          }
          return;
        }
        final loading = audio.load(
          hasLocal ? Uri.file(local!) : source!.uri,
          hasLocal ? {} : source!.headers,
          position: position,
        );
        if (hasLocal) {
          await loading;
        } else {
          await loading.timeout(audioLoadTimeout);
        }
        if (generation != operation) {
          if (requestedSession != null) {
            unawaited(api?.releaseStream(requestedSession));
          }
          return;
        }
        // The source is still paused: apply the new track's gain before its
        // first audible sample, even when the previous track had metadata.
        await applyNormalization(entry.track);
        if (generation != operation) {
          if (requestedSession != null) {
            unawaited(api?.releaseStream(requestedSession));
          }
          return;
        }
        convertedSession = requestedSession;
        _convertedLibrary = api;
        loadedEntry = entry.id;
        loadedFromFile = hasLocal;
        restoredPosition = position.inMilliseconds;
        resetSkipped();
        status = null;
        if (wantsPlayback) audio.start();
        changed();
        return;
      } on Object catch (error) {
        Diagnostics.record('audio-load', error);
        if (local == null && resolvingSource && error is TimeoutException) {
          serverUnavailable = true;
        }
        if (requestedSession != null) {
          unawaited(api?.releaseStream(requestedSession));
        }
        if (generation != operation) return;
        if (local == null && !resolvingSource && error is TimeoutException) {
          recoveryAttempts = lastFailureEntry == entry.id
              ? recoveryAttempts + 1
              : 1;
          lastFailureEntry = entry.id;
          if (recoveryAttempts < 3 && wantsPlayback) {
            restoredPosition = position.inMilliseconds;
            waitingForNetwork = true;
            status = AppMessage.playbackRetrying;
            scheduleRetry();
            notifyListeners();
            return;
          }
        }
        if (local != null) {
          final action = await playbackRecovery.failed(
            entry.id,
            local,
            expectedBytes: (downloads?.localPath(entry.track.id) == local
                ? downloads?.expectedBytes(entry.track.id)
                : null),
          );
          if (generation != operation) return;
          if (action == RecoveryAction.discard) {
            if (local == speculative) {
              await preloader?.invalidate(entry.track.id);
            } else if (!entry.track.isLocal &&
                downloads?.contains(entry.track.id) == true) {
              await downloads!.invalidate(entry.track.id);
            }
            if (!entry.track.isLocal) {
              attempted.remove(entry.id);
              continue;
            }
          } else if (action == RecoveryAction.retry) {
            hadUsableLocal = true;
            waitingForNetwork = true;
            status = AppMessage.playbackRetrying;
            scheduleRetry();
            notifyListeners();
            return;
          } else {
            hadUsableLocal = true;
          }
        }
        if (!entry.track.isLocal &&
            api != null &&
            canStream &&
            !serverUnavailable) {
          SourceAvailability available;
          try {
            available = await api
                .availability(entry.track)
                .timeout(sourceTimeout);
          } on Object catch (probeError) {
            Diagnostics.record('audio-load-probe', probeError);
            available = SourceAvailability.unreachable;
          }
          if (generation != operation) return;
          if (available == SourceAvailability.unauthorized) {
            await pause();
            status = AppMessage.yourSessionExpiredSignInToYour;
            message(status!);
            return;
          }
          serverUnavailable = available == SourceAvailability.unreachable;
        }
        if (serverUnavailable || !canStream) {
          // Unreachable songs were not played: do not consume their shuffle
          // visits/history while looking for a usable local successor.
          entry = queue.next(eligible: _hasLocalSource);
        } else {
          reportUnavailable(entry.track);
          entry = queue.next();
        }
        position = Duration.zero;
      }
    }
    await audio.stop();
    loadedEntry = null;
    status = serverUnavailable || !canStream
        ? AppMessage.noConnectionDownloadedMusicIsAvailable
        : AppMessage.noAvailableTracks;
    if (api != null &&
        !hadUsableLocal &&
        !first.track.isLocal &&
        (!canStream || serverUnavailable) &&
        wantsPlayback) {
      if (queue.current?.id != first.id) queue.select(first.id);
      restoredPosition = requestedPosition.inMilliseconds;
      waitingForNetwork = true;
      scheduleRetry();
    } else {
      wantsPlayback = false;
    }
    changed();
    message(status!);
  }

  bool _hasLocalSource(LibraryItem track) => track.isLocal
      ? importedPath(track) != null
      : downloads?.localPath(track.id) != null ||
            preloader?.localPath(track.id) != null;

  Future<void> connectionLost() async {
    if (!wantsPlayback || loadedFromFile || loadedEntry == null) return;
    // The stable local source can keep serving its prefix after network loss.
    // Only an actual buffer underrun/error should interrupt this playback.
    final cache = preloader;
    final trackId = queue.current?.track.id;
    if (cache is PlaybackStreamingCache &&
        trackId != null &&
        (cache as PlaybackStreamingCache).serves(trackId)) {
      return;
    }
    final entry = queue.current;
    if (entry == null) return;
    final generation = operation;
    restoredPosition = audio.position.inMilliseconds;
    waitingForNetwork = true;
    await audio.pause();
    if (generation != operation || !wantsPlayback) return;
    await _advanceOffline(entry, generation);
  }

  void onError(Object error) {
    Diagnostics.record('audio-stream', error);
    if (!wantsPlayback || waitingForNetwork || loadedEntry == null) return;
    restoredPosition = audio.position.inMilliseconds;
    if (lastFailureEntry == loadedEntry &&
        (restoredPosition - failurePosition).abs() < 2000) {
      recoveryAttempts++;
    } else {
      playbackRecovery.reset();
      recoveryAttempts = 1;
    }
    lastFailureEntry = loadedEntry;
    failurePosition = restoredPosition;
    waitingForNetwork = true;
    status = AppMessage.connectionInterruptedWaitingToReconnect;
    unawaited(audio.pause());
    unawaited(_recoverSource());
    notifyListeners();
  }

  Future<void> _recoverSource() async {
    final entry = queue.current;
    final generation = operation;
    if (entry == null) return;
    final local = entry.track.isLocal
        ? importedPath(entry.track)
        : downloads?.localPath(entry.track.id) ??
              preloader?.localPath(entry.track.id);
    if (entry.track.isLocal || loadedFromFile) {
      final action = local == null
          ? RecoveryAction.discard
          : await playbackRecovery.failed(
              entry.id,
              local,
              expectedBytes: (downloads?.localPath(entry.track.id) == local
                  ? downloads?.expectedBytes(entry.track.id)
                  : null),
            );
      if (generation != operation || !wantsPlayback) return;
      if (action == RecoveryAction.discard && !entry.track.isLocal) {
        if (downloads?.localPath(entry.track.id) == local) {
          await downloads!.invalidate(entry.track.id);
        } else {
          await preloader?.invalidate(entry.track.id);
        }
        if (generation == operation) {
          await start(
            entry,
            position: Duration(milliseconds: restoredPosition),
          );
        }
      } else if (action == RecoveryAction.retry) {
        status = AppMessage.playbackRetrying;
        scheduleRetry();
      } else {
        waitingForNetwork = false;
        reportUnavailable(entry.track);
        await next(false);
      }
      return;
    }
    if (library == null) return;
    if (!canStream) {
      await _advanceOffline(entry, generation);
      return;
    }
    SourceAvailability available;
    try {
      available = await library!
          .availability(entry.track)
          .timeout(sourceTimeout);
    } on Object catch (error) {
      Diagnostics.record('audio-recovery-probe', error);
      if (generation != operation || !wantsPlayback) return;
      scheduleRetry();
      notifyListeners();
      return;
    }
    if (generation != operation || !wantsPlayback) return;
    if (available == SourceAvailability.unreachable) {
      await _advanceOffline(entry, generation);
      return;
    }
    if (available == SourceAvailability.missing ||
        (available == SourceAvailability.available && recoveryAttempts >= 3)) {
      waitingForNetwork = false;
      reportUnavailable(entry.track);
      await next(false);
    } else if (available == SourceAvailability.unauthorized) {
      await pause();
      status = AppMessage.yourSessionExpiredSignInToYour;
      message(status!);
    } else {
      scheduleRetry();
    }
  }

  Future<void> _advanceOffline(QueueEntry entry, int generation) async {
    final successor = queue.next(eligible: _hasLocalSource);
    if (successor != null) {
      waitingForNetwork = false;
      await start(successor);
    } else if (generation == operation && wantsPlayback) {
      status = AppMessage.noConnectionDownloadedMusicIsAvailable;
      message(status!);
      scheduleRetry();
      notifyListeners();
    }
  }

  void scheduleRetry() {
    retryTimer?.cancel();
    retryTimer = Timer(retryDelay, () {
      if (wantsPlayback &&
          waitingForNetwork &&
          (canStream ||
              queue.current?.track.isLocal == true ||
              (queue.current != null &&
                  downloads?.localPath(queue.current!.track.id) != null))) {
        unawaited(resume());
      } else if (wantsPlayback && waitingForNetwork) {
        scheduleRetry();
      }
    });
  }

  Future<void> releaseStream() async {
    final session = convertedSession;
    convertedSession = null;
    final owner = _convertedLibrary;
    _convertedLibrary = null;
    if (session != null) await owner?.releaseStream(session);
  }
}
