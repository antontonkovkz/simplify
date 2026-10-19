import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../domain/library_item.dart';
import 'widgets.dart';

class TrackCountBadge extends StatefulWidget {
  const TrackCountBadge({super.key, required this.app, required this.item});
  final AppController app;
  final LibraryItem item;

  @override
  State<TrackCountBadge> createState() => _TrackCountBadgeState();
}

class _TrackCountBadgeState extends State<TrackCountBadge> {
  late Future<int?> _count;
  late String _stamp;
  String get stamp =>
      '${widget.app.libraryIdentity}|${widget.app.countRevision}|${widget.app.localRevision}|${widget.app.offline}|${widget.item.id}';

  void _load() {
    _stamp = stamp;
    _count = widget.app.trackCount(widget.item);
  }

  @override
  void initState() {
    super.initState();
    _load();
    widget.app.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant TrackCountBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_changed);
      widget.app.addListener(_changed);
    }
    if (oldWidget.app != widget.app || _stamp != stamp) _load();
  }

  void _changed() {
    if (mounted && _stamp != stamp) setState(_load);
  }

  @override
  void dispose() {
    widget.app.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<int?>(
    future: _count,
    initialData: widget.app.knownTrackCount(widget.item),
    builder: (context, snapshot) {
      final count = snapshot.data;
      final text =
          count?.toString() ??
          (snapshot.connectionState == ConnectionState.done ? '—' : '…');
      return Semantics(
        label: count == null
            ? 'Количество композиций недоступно'
            : 'Композиции: $count${widget.item.isPlaylist ? '' : ', включая вложенные папки'}',
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: AnimatedSwitcher(
              duration: motionDuration,
              child: Text(
                text,
                key: ValueKey(text),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
