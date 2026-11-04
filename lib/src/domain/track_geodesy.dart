import 'dart:math' as math;

/// Distance and longitude helpers shared by measurement, quality, and derived
/// geometry.
///
/// Stored distances are fixed by the algorithm that produced them. A new
/// algorithm gets a new identifier instead of changing an existing one.
abstract final class TrackGeodesy {
  /// Identifier of [sphericalHaversineMeters].
  static const sphericalHaversineId = 'spherical_haversine_r6371008_8_v1';

  /// IUGG mean Earth radius used by [sphericalHaversineMeters].
  static const meanEarthRadiusMeters = 6371008.8;

  /// Great-circle distance between two coordinates on a sphere of
  /// [meanEarthRadiusMeters].
  static double sphericalHaversineMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    final lat1 = latitude1 * math.pi / 180;
    final lat2 = latitude2 * math.pi / 180;
    final deltaLatitude = (latitude2 - latitude1) * math.pi / 180;
    final deltaLongitude = (longitude2 - longitude1) * math.pi / 180;
    final a = math.sin(deltaLatitude / 2) * math.sin(deltaLatitude / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLongitude / 2) *
            math.sin(deltaLongitude / 2);
    return meanEarthRadiusMeters *
        2 *
        math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// [to] minus [from] in degrees, the short way across the antimeridian.
  static double longitudeDelta(double from, double to) {
    final delta = to - from;
    if (delta > 180) return delta - 360;
    if (delta < -180) return delta + 360;
    return delta;
  }

  /// [longitude] moved by a full turn when it is more than 180 degrees from
  /// [reference], so the two can be interpolated. Nearby values are returned
  /// unchanged, bit for bit.
  static double unwrapLongitude(double reference, double longitude) {
    final delta = longitude - reference;
    if (delta > 180) return longitude - 360;
    if (delta < -180) return longitude + 360;
    return longitude;
  }

  /// [longitude] wrapped back into [-180, 180]; values already inside are
  /// returned unchanged.
  static double wrapLongitude(double longitude) {
    if (longitude > 180) return longitude - 360;
    if (longitude < -180) return longitude + 360;
    return longitude;
  }
}
