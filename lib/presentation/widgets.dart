import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_item.dart';

const motionDuration = Duration(milliseconds: 260);
final libraryRouteObserver = RouteObserver<PageRoute<dynamic>>();

Route<T> slideRoute<T>(Widget page) =>
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
  });
  final LibraryItem item;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final bool filenames;
  final bool downloaded;
  final bool active;
  final double? progress;
  final Widget? trailing;

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
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
            if (!item.isTrack && onMenu == null)
              const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

/// Open a context menu after pointer-up; the next tap must remain available.
class ItemGestures extends StatelessWidget {
  const ItemGestures({
    super.key,
    required this.onTap,
    this.onMenu,
    required this.child,
  });
  final VoidCallback onTap;
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
  late List<T> _visible = List.of(widget.items);
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final _scroll = ScrollController();
  final Set<String> _exiting = {};
  final Map<String, int> _exitPositions = {};
  final Map<String, Timer> _exitTimers = {};
  int _removalSerial = 0;

  @override
  void didUpdateWidget(covariant AnimatedRows<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.onReorder == null) != (widget.onReorder == null)) {
      for (final timer in _exitTimers.values) {
        timer.cancel();
      }
      _exitTimers.clear();
      _exiting.clear();
      _exitPositions.clear();
      _visible = List.of(widget.items);
      _listKey = GlobalKey<AnimatedListState>();
    } else if (widget.onReorder == null) {
      _updateAnimatedList();
    } else {
      _updateReorderable();
    }
  }

  Widget _removed(T item, Animation<double> animation) => SizeTransition(
    key: ValueKey('removed-${widget.idOf(item)}-${_removalSerial++}'),
    sizeFactor: animation,
    child: FadeTransition(
      opacity: animation,
      child: IgnorePointer(child: widget.builder(context, item, -1)),
    ),
  );

  void _updateAnimatedList() {
    final state = _listKey.currentState;
    if (state == null) {
      _visible = List.of(widget.items);
      return;
    }
    final desired = widget.items.map(widget.idOf).toSet();
    for (var i = _visible.length - 1; i >= 0; i--) {
      if (!desired.contains(widget.idOf(_visible[i]))) {
        final removed = _visible.removeAt(i);
        state.removeItem(
          i,
          (_, animation) => _removed(removed, animation),
          duration: motionDuration,
        );
      }
    }
    for (var i = 0; i < widget.items.length; i++) {
      final wanted = widget.items[i];
      final id = widget.idOf(wanted);
      if (i < _visible.length && widget.idOf(_visible[i]) == id) {
        _visible[i] = wanted;
        continue;
      }
      final previous = _visible.indexWhere((e) => widget.idOf(e) == id);
      if (previous >= 0) {
        final moved = _visible.removeAt(previous);
        state.removeItem(
          previous,
          (_, animation) => _removed(moved, animation),
          duration: motionDuration,
        );
      }
      _visible.insert(i, wanted);
      state.insertItem(i, duration: motionDuration);
    }
  }

  void _updateReorderable() {
    final desired = widget.items.map(widget.idOf).toSet();
    final positions = {
      for (var i = 0; i < _visible.length; i++) widget.idOf(_visible[i]): i,
    };
    for (final id in List.of(_exiting)) {
      if (desired.contains(id)) {
        _exitTimers.remove(id)?.cancel();
        _exiting.remove(id);
        _exitPositions.remove(id);
      }
    }
    final removed = _visible
        .where((e) => !desired.contains(widget.idOf(e)))
        .toList();
    _visible = List.of(widget.items);
    for (final item in removed) {
      final id = widget.idOf(item);
      final position = _exitPositions.putIfAbsent(id, () => positions[id] ?? 0);
      _visible.insert(position.clamp(0, _visible.length), item);
      if (_exiting.add(id)) {
        _exitTimers[id] = Timer(motionDuration, () {
          if (!mounted) return;
          setState(() {
            _visible.removeWhere((e) => widget.idOf(e) == id);
            _exiting.remove(id);
            _exitPositions.remove(id);
            _exitTimers.remove(id);
          });
        });
      }
    }
  }

  Widget _dragRow(BuildContext context, int index) {
    final item = _visible[index];
    final id = widget.idOf(item);
    return TweenAnimationBuilder<double>(
      key: ValueKey(id),
      tween: Tween(begin: 0, end: _exiting.contains(id) ? 0 : 1),
      duration: motionDuration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => ClipRect(
        child: Align(
          heightFactor: value,
          child: Opacity(opacity: value.clamp(0, 1), child: child),
        ),
      ),
      child: IgnorePointer(
        ignoring: _exiting.contains(id),
        child: widget.builder(
          context,
          item,
          widget.items.indexWhere((e) => widget.idOf(e) == id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.onReorder == null
      ? AnimatedList(
          key: _listKey,
          controller: _scroll,
          initialItemCount: _visible.length,
          itemBuilder: (context, index, animation) {
            final item = _visible[index];
            return SizeTransition(
              key: ValueKey(widget.idOf(item)),
              sizeFactor: animation,
              child: FadeTransition(
                opacity: animation,
                child: widget.builder(context, item, index),
              ),
            );
          },
        )
      : ReorderableListView.builder(
          scrollController: _scroll,
          itemCount: _visible.length,
          buildDefaultDragHandles: false,
          itemBuilder: _dragRow,
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
    for (final timer in _exitTimers.values) {
      timer.cancel();
    }
    _scroll.dispose();
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
