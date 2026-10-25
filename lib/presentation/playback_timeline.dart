import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../application/app_controller.dart';
import 'actions.dart';
import 'widgets.dart';

/// Position ticks rebuild only the timeline, never the surrounding music list.
class PlaybackTimeline extends StatefulWidget {
  const PlaybackTimeline({super.key, required this.app, this.compact = false});
  final AppController app;
  final bool compact;
  @override
  State<PlaybackTimeline> createState() => _PlaybackTimelineState();
}

class _PlaybackTimelineState extends State<PlaybackTimeline> {
  double? _seeking;
  String? _entry;
  int _operation = 0;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) {
      final app = widget.app;
      final entry = app.queue.current?.id;
      if (_entry != entry) {
        _entry = entry;
        _seeking = null;
        _operation++;
      }
      return StreamBuilder<Duration?>(
        stream: app.audio.player.durationStream,
        initialData: app.audio.player.duration,
        builder: (context, durationSnapshot) => StreamBuilder<Duration>(
          stream: app.audio.player.positionStream,
          initialData: app.position,
          builder: (context, positionSnapshot) {
            final native = app.hasLoadedCurrent ? durationSnapshot.data : null;
            final duration = native != null && native > Duration.zero
                ? native
                : Duration(
                    milliseconds: app.queue.current?.track.durationMs ?? 0,
                  );
            final known = duration > Duration.zero;
            final max = known ? duration.inMilliseconds.toDouble() : 1.0;
            final actual = app.hasLoadedCurrent
                ? positionSnapshot.data ?? app.position
                : app.position;
            final milliseconds = (_seeking ?? actual.inMilliseconds.toDouble())
                .clamp(0.0, known ? max : double.infinity)
                .toDouble();
            final elapsed = timeLabel(
              Duration(milliseconds: milliseconds.round()),
            );
            final total = known ? timeLabel(duration) : '--:--';
            final slider = Semantics(
              label: context.l10n.playbackPosition,
              child: Slider(
                value: known ? milliseconds.clamp(0, max) : 0,
                max: max,
                semanticFormatterCallback: (value) =>
                    timeLabel(Duration(milliseconds: value.round())),
                onChangeStart: known
                    ? (_) {
                        _operation++;
                      }
                    : null,
                onChanged: known
                    ? (value) => setState(() => _seeking = value)
                    : null,
                onChangeEnd: known
                    ? (value) async {
                        if (!mounted || app.queue.current?.id != entry) return;
                        final operation = ++_operation;
                        await perform(
                          app,
                          () => app.seek(Duration(milliseconds: value.round())),
                        );
                        if (mounted &&
                            operation == _operation &&
                            app.queue.current?.id == entry) {
                          setState(() => _seeking = null);
                        }
                      }
                    : null,
              ),
            );
            final style = Theme.of(context).textTheme.labelSmall;
            if (widget.compact) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text(elapsed, style: style),
                    Expanded(child: slider),
                    Text(total, style: style),
                  ],
                ),
              );
            }
            return Column(
              children: [
                slider,
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text(elapsed), Text(total)],
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );
}
