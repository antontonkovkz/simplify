import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Unknown rows use estimates; only viewport rows are laid out and measured.
/// Prefix offsets contain numbers, never eagerly built widgets or text layouts.
class RowExtents {
  List<String> _ids = const [];
  final Map<String, double> _heights = {};
  List<double>? _offsets;
  double estimate = 64;

  void order(List<String> ids) {
    _ids = ids;
    final retained = ids.toSet();
    _heights.removeWhere((id, _) => !retained.contains(id));
    _offsets = null;
  }

  void reset(double value) {
    estimate = value;
    _heights.clear();
    _offsets = null;
  }

  double at(int index) => _heights[_ids[index]] ?? estimate;
  double offset(int index) {
    final offsets = _offsets ??= () {
      final result = <double>[0];
      for (var i = 0; i < _ids.length; i++) {
        result.add(result.last + at(i));
      }
      return result;
    }();
    return offsets[index];
  }

  bool measure(String id, double height) {
    final safe = height.clamp(.1, double.infinity);
    if (_heights[id] == safe) return false;
    _heights[id] = safe;
    _offsets = null;
    return true;
  }
}

class MeasureRow extends SingleChildRenderObjectWidget {
  const MeasureRow({
    super.key,
    required this.onHeight,
    required this.generation,
    required super.child,
  });
  final ValueChanged<double> onHeight;
  final Object? generation;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureRow(onHeight, generation);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    final measured = renderObject as _MeasureRow;
    measured.onHeight = onHeight;
    if (measured.generation != generation) {
      measured.generation = generation;
      measured.resetMeasurement();
    }
  }
}

class _MeasureRow extends RenderProxyBox {
  _MeasureRow(this.onHeight, this.generation);
  Object? generation;
  void resetMeasurement() {
    _last = null;
    markNeedsLayout();
  }

  ValueChanged<double> onHeight;
  double? _last;
  @override
  void performLayout() {
    super.performLayout();
    if (size.height == _last) return;
    _last = size.height;
    final height = size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(height);
    });
  }
}
