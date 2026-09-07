import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  test('sanitized multi-day fixture preserves counts without geography', () {
    final fixture = jsonDecode(readFixture('multiday_sparse_route_v1.json'))
        as Map<String, Object?>;
    final privacy = fixture['privacy']! as Map<String, Object?>;
    final legs =
        (fixture['legs']! as List<Object?>).cast<Map<String, Object?>>();
    final activity = fixture['acceptedActivity']! as Map<String, Object?>;

    expect(privacy['containsRealCoordinates'], isFalse);
    expect(privacy['containsOwnerIdentifiers'], isFalse);
    expect(legs, hasLength(6));
    expect(legs.fold<int>(0, (sum, leg) => sum + (leg['raw']! as int)), 61);
    expect(
      legs.fold<int>(
        0,
        (sum, leg) => sum + (leg['accepted']! as int),
      ),
      30,
    );
    expect(61 - 30, fixture['rejectedPointCount']);
    expect(legs.where((leg) => leg['drawable'] == true), hasLength(3));
    expect(
      activity.values.cast<int>().fold<int>(0, (sum, value) => sum + value),
      30,
    );
    expect(fixture['durableGapCount'], 29);
    expect(fixture['earlierHistorySnapshotGapCount'], 27);
    expect(
      (fixture['shape']! as Map<String, Object?>)
          .containsKey('containsPrivateGeography'),
      isTrue,
    );
    expect(fixture.toString(), isNot(contains('latitude')));
    expect(fixture.toString(), isNot(contains('longitude')));
  });
}
