import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import 'actions.dart';
import 'widgets.dart';

/// One timeline per queue occurrence: restored playback can be sought before
/// loading audio, and an older seek must not clear a newer drag preview.
class PlaybackTimeline extends StatefulWidget {
  const PlaybackTimeline({super.key, required this.app});
  final AppController app;
  @override
  State<PlaybackTimeline> createState() => _PlaybackTimelineState();
}

class _PlaybackTimelineState extends State<PlaybackTimeline> {
  double? _seeking;
  int _operation = 0;
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return StreamBuilder<Duration>(
      stream: app.audio.player.positionStream,
      initialData: app.audio.player.position,
      builder: (context, snapshot) {
        final duration =
            (app.hasLoadedCurrent ? app.audio.player.duration : null) ??
            Duration(milliseconds: app.queue.current?.track.durationMs ?? 0);
        final max = duration.inMilliseconds
            .toDouble()
            .clamp(1.0, double.infinity)
            .toDouble();
        final position =
            (_seeking ??
                    (app.hasLoadedCurrent
                            ? snapshot.data ?? Duration.zero
                            : app.position)
                        .inMilliseconds
                        .toDouble())
                .clamp(0.0, max)
                .toDouble();
        return Column(
          children: [
            Slider(
              value: position,
              max: max,
              semanticFormatterCallback: (value) =>
                  timeLabel(Duration(milliseconds: value.round())),
              onChangeStart: (_) {
                _operation++;
              },
              onChanged: duration > Duration.zero
                  ? (value) => setState(() => _seeking = value)
                  : null,
              onChangeEnd: (value) async {
                final operation = ++_operation;
                await perform(
                  app,
                  () => app.seek(Duration(milliseconds: value.round())),
                );
                if (mounted && operation == _operation) {
                  setState(() => _seeking = null);
                }
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(timeLabel(Duration(milliseconds: position.round()))),
                  Text(timeLabel(duration)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
