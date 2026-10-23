import '../l10n/l10n.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_item.dart';
import 'group_play_button.dart';
import 'indexed_rows.dart';

const motionDuration = Duration(milliseconds: 260);
final libraryRouteObserver = RouteObserver<PageRoute<dynamic>>();

CupertinoPageRoute<T> slideRoute<T>(Widget page) =>
    CupertinoPageRoute<T>(builder: (_) => page);

Future<T?> appDialog<T>(BuildContext context, WidgetBuilder builder) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: context.l10n.close,
      barrierColor: Colors.black54,
      transitionDuration: motionDuration,
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          builder(dialogContext),
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
  required String action,
}) async =>
    await appDialog<bool>(
      context,
      (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
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

String trackCountLabel(BuildContext context, int count) =>
    context.l10n.trackCount(count);

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
    this.unavailable = false,
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
  final bool unavailable;
  final double? progress;
  final Widget? trailing;
  final Future<void> Function()? onPlay;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final title = item.isTrack
        ? (filenames ? item.filenameTitle : item.title)
        : item.displayName;
    return AnimatedOpacity(
      opacity: unavailable ? .45 : 1,
      duration: motionDuration,
      child: ItemGestures(
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
              ? Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
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
                GroupPlayButton(name: item.displayName, onPlay: onPlay!),
              if (!item.isTrack && onMenu == null && onPlay == null)
                const Icon(Icons.chevron_right_rounded),
            ],
          ),
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
    this.indexed = false,
    this.followId,
    this.followScope,
    this.animateFollow = true,
    this.physics,
  });
  final List<T> items;
  final String Function(T) idOf;
  final Widget Function(BuildContext, T, int) builder;
  final void Function(int, int)? onReorder;
  final bool indexed;
  final String? followId;
  final Object? followScope;
  final bool animateFollow;
  final ScrollPhysics? physics;
  @override
  State<AnimatedRows<T>> createState() => _AnimatedRowsState<T>();
}

class _AnimatedRowsState<T> extends State<AnimatedRows<T>> {
  late final ScrollController _scroll;
  final _extents = RowExtents();
  int _followGeneration = 0;
  bool _following = false;
  bool _measuring = false;
  bool _dragging = false;
  double _opacity = 1;
  Object? _layout;
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
    final index = _positions[widget.followId];
    _scroll = ScrollController(
      initialScrollOffset: widget.indexed && index != null
          ? _extents.offset(index)
          : 0,
    );
    _requestFollow(animate: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.indexed) return;
    final layout = (
      MediaQuery.sizeOf(context).width,
      MediaQuery.textScalerOf(context),
      Theme.of(context).textTheme,
    );
    if (_layout != layout) {
      _layout = layout;
      _extents.reset(64 * MediaQuery.textScalerOf(context).scale(14) / 14);
      _requestFollow(animate: false);
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedRows<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousIndex = _positions[oldWidget.followId];
    if (!identical(widget.items, oldWidget.items)) _updateRows();
    if (oldWidget.followId != widget.followId ||
        oldWidget.followScope != widget.followScope ||
        (previousIndex == null && _positions[widget.followId] != null)) {
      _requestFollow(animate: widget.animateFollow);
    }
  }

  void _requestFollow({required bool animate}) {
    if (!widget.indexed) return;
    final generation = ++_followGeneration;
    if (widget.followId == null) {
      _following = false;
      _opacity = 1;
      return;
    }
    _opacity = 1;
    _following = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _followGeneration) {
        _reveal(generation, animate: animate);
      }
    });
  }

  Future<void> _reveal(int generation, {bool animate = false}) async {
    if (!mounted ||
        !_following ||
        generation != _followGeneration ||
        _dragging ||
        !_scroll.hasClients ||
        widget.followId == null) {
      return;
    }
    final index = _visibleIndices[ValueKey<String>(widget.followId!)];
    if (index == null) return;
    final top = _extents.offset(index);
    final bottom = top + _extents.at(index);
    final position = _scroll.position;
    if (top >= position.pixels &&
        bottom <= position.pixels + position.viewportDimension) {
      return;
    }
    final target = (top - position.viewportDimension * .2).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (animate &&
        (target - position.pixels).abs() > position.viewportDimension * 2) {
      setState(() => _opacity = 0);
      await Future<void>.delayed(const Duration(milliseconds: 130));
      if (!mounted || generation != _followGeneration || !_following) return;
      _scroll.jumpTo(target);
      setState(() => _opacity = 1);
    } else if (animate) {
      await _scroll.animateTo(
        target,
        duration: motionDuration,
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  void _measure(String id, double height) {
    if (!mounted || !_extents.measure(id, height) || _measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measuring = false;
      setState(() {});
      if (_following) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reveal(_followGeneration);
        });
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _indexVisible() {
    _visibleIndices = {
      for (var i = 0; i < _visible.length; i++) ValueKey(_visible[i].id): i,
    };
    if (widget.indexed) _extents.order(_visible.map((e) => e.id).toList());
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
    final content = _MountedRow(
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
    if (!widget.indexed) return content;
    return KeyedSubtree(
      key: ValueKey(row.id),
      child: ClipRect(
        child: OverflowBox(
          minHeight: 0,
          maxHeight: double.infinity,
          alignment: Alignment.topCenter,
          child: MeasureRow(
            generation: _layout,
            onHeight: (height) => _measure(row.id, height),
            child: content,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.onReorder == null
        ? ListView.builder(
            physics: widget.physics,
            controller: _scroll,
            itemExtentBuilder: widget.indexed
                ? (index, _) =>
                      index < _visible.length ? _extents.at(index) : null
                : null,
            itemCount: _visible.length,
            findChildIndexCallback: (key) => _visibleIndices[key],
            itemBuilder: _row,
          )
        : ReorderableListView.builder(
            physics: widget.physics,
            scrollController: _scroll,
            itemExtentBuilder: widget.indexed
                ? (index, _) =>
                      index < _visible.length ? _extents.at(index) : null
                : null,
            onReorderStart: (_) {
              _dragging = true;
              _following = false;
              _followGeneration++;
              _opacity = 1;
            },
            onReorderEnd: (_) {
              _dragging = false;
              if (_following) _requestFollow(animate: widget.animateFollow);
            },
            itemCount: _visible.length,
            buildDefaultDragHandles: false,
            itemBuilder: _row,
            onReorderItem: (oldIndex, newIndex) {
              if (_exiting.isEmpty) {
                widget.onReorder!(
                  oldIndex,
                  // onReorderItem supplies the final index; the engine accepts
                  // an insertion boundary in the list before removal.
                  newIndex > oldIndex ? newIndex + 1 : newIndex,
                );
              }
            },
          );
    if (!widget.indexed) return list;
    return NotificationListener<ScrollStartNotification>(
      onNotification: (event) {
        if (event.dragDetails != null) {
          _following = false;
          _followGeneration++;
          if (_opacity != 1) setState(() => _opacity = 1);
        }
        return false;
      },
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 130),
        child: list,
      ),
    );
  }

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
