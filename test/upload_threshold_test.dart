import 'package:flutter_background_location_tracker/src/application/upload_threshold.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FIX-05 upload threshold', () {
    bool crosses(int before, int after, [int batch = 50]) =>
        crossesUploadThreshold(
          acceptedBefore: before,
          acceptedAfter: after,
          batchPointCount: batch,
        );

    test('single-point commits trigger exactly at each multiple', () {
      expect(
        [for (var count = 1; count <= 150; count++) count]
            .where((count) => crosses(count - 1, count)),
        <int>[50, 100, 150],
      );
    });

    test('batched commits trigger when they jump across a multiple', () {
      expect(crosses(48, 53), isTrue);
      expect(crosses(98, 151), isTrue);
      expect(crosses(51, 99), isFalse);
    });

    test('unchanged counts and invalid batch sizes never trigger', () {
      expect(crosses(50, 50), isFalse);
      expect(crosses(49, 50, 0), isFalse);
    });
  });
}
