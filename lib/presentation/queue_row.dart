import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../domain/queue_engine.dart';
import 'widgets.dart';

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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final track = entry.track;
    final details = [
      if (track.subtitle.isNotEmpty) track.subtitle,
      if (track.durationMs > 0)
        timeLabel(Duration(milliseconds: track.durationMs)),
    ].join(' · ');
    return Dismissible(
      key: ValueKey('dismiss-${entry.id}'),
      direction: DismissDirection.endToStart,
      resizeDuration: null,
      confirmDismiss: (_) => onRemove(),
      background: ColoredBox(
        color: colors.errorContainer,
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Icon(
              Icons.delete_outline_rounded,
              color: colors.onErrorContainer,
            ),
          ),
        ),
      ),
      child: Semantics(
        selected: active,
        onDismiss: () => unawaited(onRemove()),
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Переместить выше'): ?onMoveUp,
          const CustomSemanticsAction(label: 'Переместить ниже'): ?onMoveDown,
        },
        child: ItemGestures(
          onTap: onTap,
          onMenu: onMenu,
          child: ListTile(
            contentPadding: const EdgeInsets.only(left: 16, right: 8),
            minTileHeight: 64,
            minVerticalPadding: 8,
            minLeadingWidth: 24,
            horizontalTitleGap: 12,
            leading: SizedBox(
              width: 24,
              child: Center(
                child: active
                    ? Icon(
                        Icons.graphic_eq_rounded,
                        size: 22,
                        color: colors.primary,
                      )
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          position?.toString() ?? '',
                          maxLines: 1,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
              ),
            ),
            title: Text(
              track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: active ? colors.primary : null),
            ),
            subtitle: details.isEmpty
                ? null
                : Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (downloaded)
                  Semantics(
                    label: 'На устройстве',
                    child: Icon(
                      Icons.offline_pin_rounded,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ?dragHandle,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
