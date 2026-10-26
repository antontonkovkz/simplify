import 'shuffle_button.dart';
import '../l10n/l10n.dart';
import 'package:flutter/material.dart' hide RepeatMode;

import '../application/app_controller.dart';
import '../domain/queue_engine.dart';
import 'actions.dart';

class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final pause = app.isPlaying || app.waitingForNetwork || app.wantsPlayback;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        ShuffleButton(app: app),
        _button(
          tooltip: context.l10n.previous,
          icon: Icons.skip_previous_rounded,
          size: 32,
          onPressed: app.queue.canPrevious
              ? () => perform(app, app.previous)
              : null,
        ),
        Tooltip(
          message: pause ? context.l10n.pause : context.l10n.continueAction,
          child: SizedBox.square(
            dimension: 72,
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              onPressed: () => perform(app, pause ? app.pause : app.resume),
              child: Icon(
                pause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 42,
              ),
            ),
          ),
        ),
        _button(
          tooltip: context.l10n.next,
          icon: Icons.skip_next_rounded,
          size: 32,
          onPressed: () => perform(app, () => app.next(false)),
        ),
        _button(
          tooltip: switch (app.queue.repeat) {
            RepeatMode.off => context.l10n.repeatOff,
            RepeatMode.all => context.l10n.repeatQueue,
            RepeatMode.one => context.l10n.repeatTrack,
          },
          icon: app.queue.repeat == RepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          selected: app.queue.repeat != RepeatMode.off,
          onPressed: () => app.setRepeat(
            RepeatMode.values[(app.queue.repeat.index + 1) % 3],
          ),
        ),
      ],
    );
  }

  Widget _button({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool? selected,
    double size = 24,
  }) => IconButton(
    tooltip: tooltip,
    isSelected: selected,
    iconSize: size,
    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
    style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    padding: const EdgeInsets.all(6),
    onPressed: onPressed,
    icon: Icon(icon),
  );
}
