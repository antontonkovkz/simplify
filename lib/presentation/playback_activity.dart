import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../application/app_controller.dart';
import '../l10n/l10n.dart';
import 'widgets.dart';

/// Native buffering does not change `playing`; observe it independently.
class PlaybackActivity extends StatelessWidget {
  const PlaybackActivity({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => StreamBuilder<PlayerState>(
      stream: app.audio.player.playerStateStream,
      initialData: PlayerState(app.isPlaying, app.audio.player.processingState),
      builder: (context, snapshot) {
        final state = snapshot.data;
        final waiting = app.waitingForNetwork;
        final busy =
            waiting ||
            (app.wantsPlayback &&
                (!app.hasLoadedCurrent ||
                    state?.processingState == ProcessingState.loading ||
                    state?.processingState == ProcessingState.buffering));
        final label = waiting
            ? (app.status ?? context.l10n.waitingForAConnection)
            : context.l10n.bufferingAudio;
        return AnimatedSize(
          duration: motionDuration,
          child: busy
              ? Semantics(
                  liveRegion: true,
                  label: label,
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              label,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    ),
  );
}
