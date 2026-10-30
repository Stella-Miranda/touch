import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:direct_pointing_assistant/services/hand_cluster_detector.dart';

/// Builds a fake NV21 [CameraImage] of [width]x[height] whose chroma plane
/// is entirely one color, except for a differently-colored rectangle
/// spanning chroma columns [handCx, handCx + handSize) and rows
/// [handCy, handCy + handSize).
CameraImage _buildNv21Image({
  required int width,
  required int height,
  int? handCx,
  int? handCy,
  int handSize = 0,
}) {
  final ySize = width * height;
  final chromaWidth = width ~/ 2;
  final chromaHeight = height ~/ 2;
  final bytes = Uint8List(ySize + chromaWidth * chromaHeight * 2);

  // Y plane content is irrelevant to color clustering.
  bytes.fillRange(0, ySize, 128);

  // Chroma plane defaults to a uniform "background" color.
  for (int i = ySize; i < bytes.length; i += 2) {
    bytes[i] = 200; // Cr
    bytes[i + 1] = 200; // Cb
  }

  if (handCx != null && handCy != null) {
    for (int cy = handCy; cy < handCy + handSize; cy++) {
      for (int cx = handCx; cx < handCx + handSize; cx++) {
        final idx = ySize + (cy * chromaWidth + cx) * 2;
        bytes[idx] = 150; // Cr, far from the background's 200
        bytes[idx + 1] = 100; // Cb, far from the background's 200
      }
    }
  }

  return CameraImage.fromPlatformInterface(
    CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.nv21, raw: 0),
      width: width,
      height: height,
      planes: [CameraImagePlane(bytes: bytes, bytesPerRow: width)],
    ),
  );
}

void main() {
  group('HandClusterDetector', () {
    test('returns null when the frame is a single uniform color', () {
      final detector = HandClusterDetector();
      final image = _buildNv21Image(width: 64, height: 64);

      expect(detector.detect(image), isNull);
    });

    test('returns the centroid of the differently-colored region', () {
      final detector = HandClusterDetector(sampleStride: 1);
      final image = _buildNv21Image(
        width: 64,
        height: 64,
        handCx: 10,
        handCy: 10,
        handSize: 10,
      );

      final point = detector.detect(image);

      expect(point, isNotNull);
      // The hand block spans chroma columns/rows 10-19, i.e. pixel
      // coordinates 20-38, so the centroid should land near (29, 29).
      expect(point!.dx, closeTo(29, 2));
      expect(point.dy, closeTo(29, 2));
    });

    test('ignores a color patch too small to trust as a hand', () {
      final detector = HandClusterDetector(sampleStride: 1);
      final image = _buildNv21Image(
        width: 64,
        height: 64,
        handCx: 10,
        handCy: 10,
        handSize: 2,
      );

      expect(detector.detect(image), isNull);
    });
  });
}
