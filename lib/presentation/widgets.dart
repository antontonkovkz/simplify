import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_item.dart';
import 'group_play_button.dart';

const motionDuration = Duration(milliseconds: 260);
final libraryRouteObserver = RouteObserver<PageRoute<dynamic>>();

CupertinoPageRoute<T> slideRoute<T>(Widget page) =>
    CupertinoPageRoute<T>(builder: (_) => page);

Future<T?> appDialog<T>(BuildContext context, Widget dialog) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: Colors.black54,
      transitionDuration: motionDuration,
      pageBuilder: (_, animation, secondaryAnimation) => dialog,
      transitionBuilder: (_, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, .06), end: Offset.zero)
                  .animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: child,
            ),
          ),
    );

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = 'Удалить',
}) async =>
    await appDialog<bool>(
      context,
      AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

String timeLabel(Duration duration) {
  final minutes = duration.inMinutes;
  return '$minutes:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}

String trackCountLabel(int count) {
  final tens = count % 100;
  final suffix = tens >= 11 && tens <= 14
      ? 'композиций'
      : switch (count % 10) {
          1 => 'композиция',
          2 || 3 || 4 => 'композиции',
          _ => 'композиций',
        };
  return '$count $suffix';
}

class EmptyState extends StatelessWidget {
  const EmptyState(
    this.title, {
    super.key,
    this.subtitle,
    this.icon = Icons.music_note_rounded,
    this.action,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
        ),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(subtitle!, textAlign: TextAlign.center),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    ),
  );
}

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onMenu,
    this.filenames = false,
    this.downloaded = false,
    this.active = false,
    this.progress,
    this.trailing,
    this.onPlay,
  });
  final LibraryItem item;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final bool filenames;
  final bool downloaded;
  final bool active;
  final double? progress;
  final Widget? trailing;
  final Future<void> Function()? onPlay;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final title = item.isTrack
        ? (filenames ? item.filenameTitle : item.title)
        : item.name;
    return ItemGestures(
      onTap: onTap,
      onMenu: onMenu,
      child: ListTile(
        contentPadding: EdgeInsets.only(
          left: 16,
          right: onPlay == null ? 16 : 8,
        ),
        minTileHeight: item.isTrack && !filenames && item.subtitle.isNotEmpty
            ? 64
            : 56,
        minVerticalPadding: 8,
        minLeadingWidth: 24,
        horizontalTitleGap: 12,
        leading: Icon(
          active
              ? Icons.graphic_eq_rounded
              : switch (item.kind) {
                  ItemKind.track => Icons.music_note_rounded,
                  ItemKind.playlist => Icons.queue_music_rounded,
                  _ => Icons.folder_rounded,
                },
          color: active ? color.primary : color.onSurfaceVariant,
        ),
        title: AnimatedSwitcher(
          duration: motionDuration,
          child: Align(
            key: ValueKey(title),
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: active ? color.primary : null),
            ),
          ),
        ),
        subtitle: item.isTrack && !filenames && item.subtitle.isNotEmpty
            ? Text(item.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress != null)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress! > 0 ? progress : null,
                ),
              ),
            if (downloaded && progress == null)
              const Icon(Icons.offline_pin_rounded, size: 18),
            ?trailing,
            if (item.isTrack &&
                onMenu != null &&
                trailing == null &&
                item.durationMs > 0)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  timeLabel(Duration(milliseconds: item.durationMs)),
                  style: TextStyle(color: color.onSurfaceVariant),
                ),
              ),
            if (!item.isTrack && onPlay != null)
              GroupPlayButton(name: item.name, onPlay: onPlay!),
            if (!item.isTrack && onMenu == null && onPlay == null)
              const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

/// Open a context menu after pointer-up; the next tap must remain available.
class ItemGestures extends StatelessWidget {
  const ItemGestures({super.key, this.onTap, this.onMenu, required this.child});
  final VoidCallback? onTap;
  final VoidCallback? onMenu;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    onLongPress: onMenu,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressEnd: onMenu == null
          ? null
          : (_) {
              Feedback.forLongPress(context);
              onMenu!();
            },
      child: child,
    ),
  );
}

/// Stable keyed rows animate insertion/removal. Reordering uses Flutter's
/// native drag animation; removed rows shrink while their old data is retained.
class AnimatedRows<T> extends StatefulWidget {
  const AnimatedRows({
    super.key,
    required this.items,
    required this.idOf,
    required this.builder,
    this.onReorder,
  });
  final List<T> items;
  final String Function(T) idOf;
  final Widget Function(BuildContext, T, int) builder;
  final void Function(int, int)? onReorder;
  @override
  State<AnimatedRows<T>> createState() => _AnimatedRowsState<T>();
}

class _AnimatedRowsState<T> extends State<AnimatedRows<T>> {
  final _scroll = ScrollController();
  late List<({String id, T item})> _visible;
  Map<String, int> _positions = {};
  Map<Key, int> _visibleIndices = {};
  final Set<String> _mounted = {};
  final Set<String> _entering = {};
  final Set<String> _exiting = {};
  Timer? _transitionTimer;

  @override
  void initState() {
    super.initState();
    _updateRows(animate: false);
  }

  @override
  void didUpdateWidget(covariant AnimatedRows<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateRows();
  }

  void _indexVisible() {
    _visibleIndices = {
      for (var i = 0; i < _visible.length; i++) ValueKey(_visible[i].id): i,
    };
  }

  /// Linear reconciliation, including large replacements and server reorders.
  /// Only mounted rows animate; a batch shares one cleanup timer.
  void _updateRows({bool animate = true}) {
    final desired = [
      for (final item in widget.items) (id: widget.idOf(item), item: item),
    ];
    final positions = {
      for (var i = 0; i < desired.length; i++) desired[i].id: i,
    };
    if (!animate) {
      _visible = desired;
      _positions = positions;
      _indexVisible();
      return;
    }
    var changed = false;
    final oldIds = {for (final row in _visible) row.id};
    _entering.removeWhere((id) => !positions.containsKey(id));
    for (final row in desired) {
      final restored = _exiting.remove(row.id);
      if (!oldIds.contains(row.id) ||
          restored ||
          (widget.onReorder == null &&
              _positions[row.id] != positions[row.id])) {
        _entering.add(row.id);
        changed = true;
      }
    }
    final merged = <({String id, T item})>[];
    var next = 0;
    for (var i = 0; i < _visible.length; i++) {
      final row = _visible[i];
      if (positions.containsKey(row.id) || !_mounted.contains(row.id)) continue;
      while (next < desired.length && merged.length < i) {
        merged.add(desired[next++]);
      }
      merged.add(row);
      if (_exiting.add(row.id)) changed = true;
    }
    merged.addAll(desired.skip(next));
    _visible = merged;
    _positions = positions;
    _indexVisible();
    if (changed) {
      _transitionTimer?.cancel();
      _transitionTimer = Timer(motionDuration, () {
        if (!mounted) return;
        setState(() {
          _visible.removeWhere((row) => _exiting.contains(row.id));
          _exiting.clear();
          _entering.clear();
          _indexVisible();
        });
      });
    }
  }

  Widget _row(BuildContext context, int index) {
    final row = _visible[index];
    final exiting = _exiting.contains(row.id);
    final child = widget.builder(context, row.item, _positions[row.id] ?? -1);
    return _MountedRow(
      key: ValueKey(row.id),
      onMount: () => _mounted.add(row.id),
      onUnmount: () => _mounted.remove(row.id),
      child: TweenAnimationBuilder<double>(
        tween: Tween(
          begin: exiting || !_entering.contains(row.id) ? 1 : 0,
          end: exiting ? 0 : 1,
        ),
        duration: motionDuration,
        curve: Curves.easeOutCubic,
        // Arriving scroll rows must always occupy their full height.
        // A zero-height entrance causes the viewport to build the tail.
        builder: (context, value, child) => ClipRect(
          child: Align(
            heightFactor: exiting ? value : 1,
            child: Opacity(opacity: value.clamp(0, 1), child: child),
          ),
        ),
        child: IgnorePointer(ignoring: exiting, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.onReorder == null
      ? ListView.builder(
          controller: _scroll,
          itemCount: _visible.length,
          findChildIndexCallback: (key) => _visibleIndices[key],
          itemBuilder: _row,
        )
      : ReorderableListView.builder(
          scrollController: _scroll,
          itemCount: _visible.length,
          buildDefaultDragHandles: false,
          itemBuilder: _row,
          onReorderItem: (oldIndex, newIndex) {
            if (_exiting.isEmpty) {
              widget.onReorder!(
                oldIndex,
                newIndex > oldIndex ? newIndex + 1 : newIndex,
              );
            }
          },
        );

  @override
  void dispose() {
    _transitionTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }
}

/// Track mounted rows so bulk removal retains only viewport exit animations.
class _MountedRow extends StatefulWidget {
  const _MountedRow({
    super.key,
    required this.onMount,
    required this.onUnmount,
    required this.child,
  });
  final VoidCallback onMount;
  final VoidCallback onUnmount;
  final Widget child;
  @override
  State<_MountedRow> createState() => _MountedRowState();
}

class _MountedRowState extends State<_MountedRow> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => widget.child;
  @override
  void dispose() {
    widget.onUnmount();
    super.dispose();
  }
}

List<String> occurrenceKeys(List<LibraryItem> items) {
  final counts = <String, int>{};
  return items.map((item) {
    final number = counts.update(item.id, (n) => n + 1, ifAbsent: () => 0);
    return '${item.id}-$number';
  }).toList();
}
