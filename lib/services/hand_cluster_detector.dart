import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Finds the pointing hand in a live NV21 camera frame by splitting its
/// chroma (color) samples into two clusters, rather than matching against a
/// fixed skin-tone range. A hand held up against a painting occupies a
/// small part of the frame and differs sharply in color from the artwork
/// behind it, so the smaller, distinctly-colored cluster is treated as the
/// hand. This works regardless of skin tone or lighting, unlike a
/// hardcoded skin-hue threshold.
///
/// NV21 frames are already in YCbCr: a full-resolution Y plane followed by
/// a half-resolution, interleaved V/U (Cr/Cb) plane. Clustering directly on
/// those chroma samples avoids any RGB conversion.
class HandClusterDetector {
  HandClusterDetector({
    this.sampleStride = 4,
    this.iterations = 5,
    this.minHandSamples = 25,
    this.maxHandFraction = 0.35,
    this.minColorSeparation = 20.0,
  });

  /// Step size (in chroma samples) between pixels that get sampled. Larger
  /// values are faster but coarser; 4 keeps this cheap enough to run on
  /// every frame on a mid-range phone.
  final int sampleStride;

  /// Number of Lloyd's-algorithm refinement passes over the two cluster
  /// centers. A handful of passes is enough to converge on a two-color
  /// scene like a hand against a painting.
  final int iterations;

  /// Minimum number of samples the minority cluster needs before it's
  /// trusted as a hand rather than incidental noise.
  final int minHandSamples;

  /// Above this fraction of the frame, the "minority" cluster is too big to
  /// plausibly be a hand (e.g. the frame is evenly split between two large
  /// regions), so detection is rejected.
  final double maxHandFraction;

  /// Minimum Euclidean distance (in Cr/Cb units) between the two cluster
  /// centers. Below this, the frame is close to a single color and there's
  /// no confident hand/background split.
  final double minColorSeparation;

  /// Returns the centroid of the detected hand cluster in image pixel
  /// coordinates, or null if no hand is confidently in view.
  Offset? detect(CameraImage image) {
    if (image.planes.length != 1) return null;

    final bytes = image.planes.first.bytes;
    final width = image.width;
    final height = image.height;
    final ySize = width * height;
    final chromaWidth = width ~/ 2;
    final chromaHeight = height ~/ 2;

    if (bytes.length < ySize + chromaWidth * chromaHeight * 2) return null;

    final List<int> xs = [];
    final List<int> ys = [];
    final List<int> crs = [];
    final List<int> cbs = [];

    for (int cy = 0; cy < chromaHeight; cy += sampleStride) {
      final rowOffset = ySize + cy * chromaWidth * 2;
      for (int cx = 0; cx < chromaWidth; cx += sampleStride) {
        final idx = rowOffset + cx * 2;
        if (idx + 1 >= bytes.length) continue;
        crs.add(bytes[idx]);
        cbs.add(bytes[idx + 1]);
        xs.add(cx * 2);
        ys.add(cy * 2);
      }
    }

    return _cluster(xs, ys, crs, cbs);
  }

  /// Same as [detect], for a decoded RGB picture — the web build has no live
  /// NV21 stream, only still pictures. Samples the same grid as [detect]
  /// (every `sampleStride * 2` pixels) and derives Cr/Cb from RGB.
  Offset? detectRgb(img.Image image) {
    final step = sampleStride * 2;
    final List<int> xs = [];
    final List<int> ys = [];
    final List<int> crs = [];
    final List<int> cbs = [];

    for (int y = 0; y < image.height; y += step) {
      for (int x = 0; x < image.width; x += step) {
        final p = image.getPixel(x, y);
        final r = p.r, g = p.g, b = p.b;
        crs.add((128 + 0.5 * r - 0.418688 * g - 0.081312 * b).round());
        cbs.add((128 - 0.168736 * r - 0.331264 * g + 0.5 * b).round());
        xs.add(x);
        ys.add(y);
      }
    }

    return _cluster(xs, ys, crs, cbs);
  }

  Offset? _cluster(List<int> xs, List<int> ys, List<int> crs, List<int> cbs) {
    final n = xs.length;
    if (n < minHandSamples * 2) return null;

    // Seed the two cluster centers using the overall color mean and the
    // sample farthest from it — the farthest point is a good representative
    // of a small, sharply-different-colored region (the hand), while the
    // mean is a good stand-in for the large, more uniform background.
    double meanCr = 0, meanCb = 0;
    for (int i = 0; i < n; i++) {
      meanCr += crs[i];
      meanCb += cbs[i];
    }
    meanCr /= n;
    meanCb /= n;

    int farthestIndex = 0;
    double farthestDist = -1;
    for (int i = 0; i < n; i++) {
      final d = _sqDist(crs[i].toDouble(), cbs[i].toDouble(), meanCr, meanCb);
      if (d > farthestDist) {
        farthestDist = d;
        farthestIndex = i;
      }
    }

    double centerACr = crs[farthestIndex].toDouble();
    double centerACb = cbs[farthestIndex].toDouble();
    double centerBCr = meanCr;
    double centerBCb = meanCb;

    final assignment = List<bool>.filled(n, false);

    for (int iter = 0; iter < iterations; iter++) {
      double sumACr = 0, sumACb = 0, sumBCr = 0, sumBCb = 0;
      int countA = 0, countB = 0;

      for (int i = 0; i < n; i++) {
        final cr = crs[i].toDouble();
        final cb = cbs[i].toDouble();
        final dA = _sqDist(cr, cb, centerACr, centerACb);
        final dB = _sqDist(cr, cb, centerBCr, centerBCb);
        final isA = dA <= dB;
        assignment[i] = isA;
        if (isA) {
          sumACr += cr;
          sumACb += cb;
          countA++;
        } else {
          sumBCr += cr;
          sumBCb += cb;
          countB++;
        }
      }

      if (countA > 0) {
        centerACr = sumACr / countA;
        centerACb = sumACb / countA;
      }
      if (countB > 0) {
        centerBCr = sumBCr / countB;
        centerBCb = sumBCb / countB;
      }
    }

    final separation = _sqDist(centerACr, centerACb, centerBCr, centerBCb);
    if (separation < minColorSeparation * minColorSeparation) {
      return null;
    }

    int countA = 0;
    for (final isA in assignment) {
      if (isA) countA++;
    }
    final countB = n - countA;

    final handIsA = countA <= countB;
    final handCount = handIsA ? countA : countB;
    final handFraction = handCount / n;

    if (handCount < minHandSamples || handFraction > maxHandFraction) {
      return null;
    }

    double sumX = 0, sumY = 0;
    for (int i = 0; i < n; i++) {
      if (assignment[i] == handIsA) {
        sumX += xs[i];
        sumY += ys[i];
      }
    }

    return Offset(sumX / handCount, sumY / handCount);
  }

  double _sqDist(double cr1, double cb1, double cr2, double cb2) {
    final dCr = cr1 - cr2;
    final dCb = cb1 - cb2;
    return dCr * dCr + dCb * dCb;
  }
}
