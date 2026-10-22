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
  final Duration retryDelay;
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
    // Loading the explicitly selected track always takes priority over a
    // speculative download. Completed cached files remain available.
    preloader?.cancelPending();
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
      audio.publishQueue(queue, position: position);
      notifyListeners();
      final speculative = preloader?.localPath(entry.track.id);
      final local = entry.track.isLocal
          ? importedPath(entry.track)
          : downloads?.localPath(entry.track.id) ?? speculative;
      String? requestedSession;
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
            : await api!.resolvePlayback(entry.track, position: position);
        requestedSession = source?.playSessionId;
        if (generation != operation) {
          if (requestedSession != null) {
            await api?.releaseStream(requestedSession);
          }
          return;
        }
        await audio.load(
          hasLocal ? Uri.file(local!) : source!.uri,
          hasLocal ? {} : source!.headers,
          position: position,
        );
        if (generation != operation) {
          if (requestedSession != null) {
            await api?.releaseStream(requestedSession);
          }
          return;
        }
        // The source is still paused: apply the new track's gain before its
        // first audible sample, even when the previous track had metadata.
        await applyNormalization(entry.track);
        if (generation != operation) {
          if (requestedSession != null) {
            await api?.releaseStream(requestedSession);
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
        if (requestedSession != null) {
          await api?.releaseStream(requestedSession);
        }
        if (generation != operation) return;
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
          final available = await api.availability(entry.track);
          if (generation != operation) return;
          if (available == SourceAvailability.unauthorized) {
            await pause();
            status = AppMessage.yourSessionExpiredSignInToYour;
            message(status!);
            return;
          }
          serverUnavailable = available == SourceAvailability.unreachable;
        }
        reportUnavailable(entry.track);
        entry = queue.next();
        position = Duration.zero;
      }
    }
    await audio.stop();
    loadedEntry = null;
    status = AppMessage.noAvailableTracks;
    if (api != null &&
        !hadUsableLocal &&
        !first.track.isLocal &&
        (!canStream || serverUnavailable) &&
        wantsPlayback) {
      queue.select(first.id);
      waitingForNetwork = true;
      scheduleRetry();
    } else {
      wantsPlayback = false;
    }
    changed();
    message(status!);
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
    final available = await library!.availability(entry.track);
    if (generation != operation || !wantsPlayback) return;
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
