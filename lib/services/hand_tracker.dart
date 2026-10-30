import 'dart:math';

class HandTracker {
  DateTime? _dwellStartTime;
  Point<double>? _lastPoint;

  /// Radius threshold in pixels to consider the finger "stationary"
  final double dwellRadius;

  /// Time threshold in milliseconds to consider the finger "dwelling"
  final int dwellDurationMs;

  HandTracker({this.dwellRadius = 30.0, this.dwellDurationMs = 800});

  /// Update the last seen raw coordinate stream without triggering a dwell check.
  void updateCoordinates(double x, double y) {
    final currentPoint = Point<double>(x, y);

    if (_lastPoint == null) {
      _lastPoint = currentPoint;
      _dwellStartTime = DateTime.now();
      return;
    }

    final distance = _calculateDistance(_lastPoint!, currentPoint);
    if (distance > dwellRadius) {
      _dwellStartTime = null;
    }

    _lastPoint = currentPoint;
  }

  /// 1. Check if the index finger stays in a 30px radius for > 800ms
  bool hasDweled(double x, double y) {
    final currentPoint = Point<double>(x, y);

    if (_lastPoint == null) {
      _lastPoint = currentPoint;
      _dwellStartTime = DateTime.now();
      return false;
    }

    final distance = _calculateDistance(_lastPoint!, currentPoint);

    if (distance > dwellRadius) {
      _lastPoint = currentPoint;
      _dwellStartTime = null;
      return false;
    }

    _lastPoint = currentPoint;

    if (_dwellStartTime == null) {
      _dwellStartTime = DateTime.now();
      return false;
    }

    final elapsed = DateTime.now().difference(_dwellStartTime!).inMilliseconds;
    return elapsed >= dwellDurationMs;
  }

  /// 2. Check if finger has moved > 100px away from the point where the image was captured
  bool hasMovedAway(
    double currentX,
    double currentY,
    double lastX,
    double lastY, {
    double distanceThreshold = 100.0,
  }) {
    final p1 = Point<double>(currentX, currentY);
    final p2 = Point<double>(lastX, lastY);
    return _calculateDistance(p1, p2) > distanceThreshold;
  }

  /// Reset internal timer state
  void resetDwellTimer() {
    _dwellStartTime = null;
    _lastPoint = null;
  }

  double _calculateDistance(Point<double> p1, Point<double> p2) {
    return sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2));
  }
}
