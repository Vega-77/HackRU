import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/physics_state.dart';

class GrayFrame {
  const GrayFrame(this.pixels, this.width, this.height, this.t);
  final Uint8List pixels;
  final int width;
  final int height;
  final double t;
}

/// A local image match, never an input to physics or a confirmed observation.
class VisualEstimate {
  const VisualEstimate(this.box, this.t, this.score, this.computeMs);
  final PixelRect box;
  final double t;
  final double score;
  final double computeMs;
}

/// Matches the server-selected object's entire outline and adjacent context.
/// The reference stays fixed. Ambiguity or a gap requires server reacquisition.
class LocalVisualTracker {
  static const _grid = 12;
  List<double>? _reference;
  PixelRect? _box;
  double? _time;
  double _mean = 0;

  void clear() {
    _reference = null;
    _box = null;
    _time = null;
  }

  void lose() => _box = null;

  bool anchor(GrayFrame frame, PixelRect box) {
    if (!frame.t.isFinite || box.w < 8 || box.h < 8) return false;
    final patch = _patch(frame, box);
    if (patch == null) return false;
    if (_reference == null) {
      _mean = patch.mean;
      _reference = patch.values;
    } else if (_score(patch) < .9) {
      return false;
    }
    _box = box;
    _time = frame.t;
    return true;
  }

  VisualEstimate? update(GrayFrame frame) {
    final box = _box;
    final time = _time;
    if (box == null || time == null || frame.t <= time) return null;
    final dt = frame.t - time;
    if (dt > .2) {
      _box = null;
      return null;
    }
    final clock = Stopwatch()..start();
    // Bound work and admit large displacement without extrapolating an
    // unobserved position. Coordinates are at 160 px width.
    final radius = (12 + dt * 240).ceil().clamp(14, 40);
    final candidates = <(double, PixelRect)>[];
    for (var dy = -radius; dy <= radius; dy += 2) {
      for (var dx = -radius; dx <= radius; dx += 2) {
        final candidate = PixelRect(box.x + dx, box.y + dy, box.w, box.h);
        final score = _scoreAt(frame, candidate);
        if (score > -1) candidates.add((score, candidate));
      }
    }
    if (candidates.isEmpty) {
      _box = null;
      return null;
    }
    candidates.sort((a, b) => b.$1.compareTo(a.$1));
    var best = candidates.first;
    final coarse = best.$2;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final candidate = PixelRect(coarse.x + dx, coarse.y + dy, box.w, box.h);
        final score = _scoreAt(frame, candidate);
        if (score > best.$1) {
          best = (score, candidate);
        }
      }
    }
    final alternative = candidates.where(
      (c) =>
          (c.$2.centre - best.$2.centre).length > math.max(box.w, box.h) * .75,
    );
    var second = alternative.isEmpty ? -1.0 : alternative.first.$1;
    if (alternative.isNotEmpty) {
      final other = alternative.first.$2;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final score = _scoreAt(
            frame,
            PixelRect(other.x + dx, other.y + dy, box.w, box.h),
          );
          second = math.max(second, score);
        }
      }
    }
    if (best.$1 < .9 || best.$1 - second < .06) {
      _box = null;
      return null;
    }
    _box = best.$2;
    _time = frame.t;
    return VisualEstimate(
      best.$2,
      frame.t,
      best.$1,
      clock.elapsedMicroseconds / 1000,
    );
  }

  double _score(_Patch patch) {
    if ((patch.mean - _mean).abs() > 60) return -1;
    final reference = _reference!;
    var dot = 0.0;
    for (var i = 0; i < reference.length; i++) {
      dot += reference[i] * patch.values[i];
    }
    return dot / reference.length;
  }

  double _scoreAt(GrayFrame frame, PixelRect box) {
    final left = box.x - box.w * .1, top = box.y - box.h * .1;
    final width = box.w * 1.2, height = box.h * 1.2;
    if (left < 0 ||
        top < 0 ||
        left + width >= frame.width ||
        top + height >= frame.height) {
      return -1;
    }
    final reference = _reference!;
    var sum = 0.0, squared = 0.0, dot = 0.0;
    for (var y = 0; y < _grid; y++) {
      final row = (top + (y + .5) * height / _grid).floor() * frame.width;
      for (var x = 0; x < _grid; x++) {
        final value = frame
            .pixels[row + (left + (x + .5) * width / _grid).floor()]
            .toDouble();
        sum += value;
        squared += value * value;
        dot += reference[y * _grid + x] * value;
      }
    }
    final mean = sum / reference.length;
    if ((mean - _mean).abs() > 60) return -1;
    final deviation = math.sqrt(
      math.max(0, squared / reference.length - mean * mean),
    );
    if (deviation < 8) return -1;
    // The centered reference sums to zero, so candidate centering needn't
    // allocate and normalize another patch for every search location.
    return dot / (deviation * reference.length);
  }

  _Patch? _patch(GrayFrame frame, PixelRect box) {
    final left = box.x - box.w * .1;
    final top = box.y - box.h * .1;
    final width = box.w * 1.2;
    final height = box.h * 1.2;
    if (left < 0 ||
        top < 0 ||
        left + width >= frame.width ||
        top + height >= frame.height) {
      return null;
    }
    final values = List<double>.filled(_grid * _grid, 0);
    var sum = 0.0;
    var squared = 0.0;
    for (var y = 0; y < _grid; y++) {
      for (var x = 0; x < _grid; x++) {
        final px = (left + (x + .5) * width / _grid).floor();
        final py = (top + (y + .5) * height / _grid).floor();
        final v = frame.pixels[py * frame.width + px].toDouble();
        values[y * _grid + x] = v;
        sum += v;
        squared += v * v;
      }
    }
    final mean = sum / values.length;
    final deviation = math.sqrt(
      math.max(0, squared / values.length - mean * mean),
    );
    if (deviation < 8) return null;
    for (var i = 0; i < values.length; i++) {
      values[i] = (values[i] - mean) / deviation;
    }
    return _Patch(values, mean);
  }
}

class _Patch {
  const _Patch(this.values, this.mean);
  final List<double> values;
  final double mean;
}
