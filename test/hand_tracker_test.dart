import 'package:flutter_test/flutter_test.dart';
import 'package:direct_pointing_assistant/services/hand_tracker.dart';

void main() {
  group('HandTracker', () {
    test(
      'reports dwell only after the finger stays within radius long enough',
      () async {
        final tracker = HandTracker(dwellDurationMs: 50);

        tracker.updateCoordinates(100, 100);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(tracker.hasDweled(100, 100), isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(tracker.hasDweled(100, 100), isTrue);
      },
    );

    test(
      'resets dwell timing when the tracked point moves beyond the radius',
      () async {
        final tracker = HandTracker(dwellDurationMs: 50);

        tracker.updateCoordinates(100, 100);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(tracker.hasDweled(100, 100), isFalse);

        tracker.updateCoordinates(200, 100);
        expect(tracker.hasDweled(200, 100), isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(tracker.hasDweled(200, 100), isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 35));
        expect(tracker.hasDweled(200, 100), isTrue);
      },
    );
  });
}
