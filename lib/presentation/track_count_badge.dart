import '../l10n/l10n.dart';
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
      final availability = widget.app.offlineAvailability(
        widget.item,
        total: snapshot.data,
      );
      final count = availability.total;
      final partial = availability.available > 0 && !availability.complete;
      final text = partial
          ? '${availability.available}/${count ?? '…'}'
          : count?.toString() ??
                (snapshot.connectionState == ConnectionState.done ? '—' : '…');
      final status = availability.failed
          ? context.l10n.downloadError
          : availability.downloading
          ? context.l10n.downloading
          : availability.available > 0
          ? context.l10n.onDeviceAvailability(
              (availability.available).toString(),
              (count == null
                      ? ''
                      : context.l10n.ofTotalSuffix((count).toString()))
                  .toString(),
            )
          : '';
      return Semantics(
        label: count == null
            ? context.l10n.trackCountUnavailable2((status).toString())
            : context.l10n.tracks(
                (count).toString(),
                (widget.item.isPlaylist ? '' : context.l10n.includingSubfolders)
                    .toString(),
                (status).toString(),
              ),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: AnimatedSwitcher(
              duration: motionDuration,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                key: ValueKey('$text$status'),
                children: [
                  if (availability.downloading)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    )
                  else if (availability.failed || availability.available > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        availability.failed
                            ? Icons.error_outline_rounded
                            : availability.complete
                            ? Icons.offline_pin_rounded
                            : Icons.downloading_rounded,
                        size: 16,
                      ),
                    ),
                  Text(
                    text,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
