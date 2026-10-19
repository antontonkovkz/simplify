import 'package:flutter/material.dart';

import '../domain/queue_engine.dart';
import 'editable_track_row.dart';

/// Swipe dismissal delegates mutation/animation to the shared queue list.
class QueueRow extends StatelessWidget {
  const QueueRow({
    super.key,
    required this.entry,
    required this.position,
    required this.onTap,
    required this.onMenu,
    required this.onRemove,
    this.active = false,
    this.downloaded = false,
    this.dragHandle,
    this.onMoveUp,
    this.onMoveDown,
  });
  final QueueEntry entry;
  final int? position;
  final VoidCallback onTap;
  final VoidCallback onMenu;
  final Future<bool> Function() onRemove;
  final bool active;
  final bool downloaded;
  final Widget? dragHandle;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) => EditableTrackRow(
    occurrenceId: entry.id,
    track: entry.track,
    position: position,
    onTap: onTap,
    onMenu: onMenu,
    onRemove: onRemove,
    active: active,
    downloaded: downloaded,
    dragHandle: dragHandle,
    onMoveUp: onMoveUp,
    onMoveDown: onMoveDown,
  );
}
