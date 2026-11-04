/// How much route detail is recorded beside the clean route.
///
/// Every mode collects and decides the same fixes: the accepted path, the
/// held and rejected fixes kept as hidden evidence, distance, stops, steps
/// and uploads are identical. The modes differ only in the output-only
/// detail stored next to them.
///
/// * [full] also stores every continuity gap (with its visibility), the
///   quality runs, coordinate-free motion evidence and diagnostic health
///   events, and keeps the journaled activity readings of completed routes.
/// * [clean] stores only the gap rows that mark segment boundaries, none of
///   them visible, no quality runs, motion evidence or diagnostic health
///   events, and clears the journaled activity readings of a route once it is
///   completed or failed.
/// * [automatic], the default, is [full] in debug builds and [clean] in
///   profile and release builds.
///
/// Each route keeps the mode it was started with ([Track.recordingDetail]);
/// an app built in another mode never reinterprets it.
///
/// This is a class with constant values rather than an enum, so a value
/// added later does not break exhaustive switches in host code.
final class RouteRecordingDetail {
  const RouteRecordingDetail._(this.name);

  /// [full] in debug builds, [clean] in profile and release builds.
  static const automatic = RouteRecordingDetail._('automatic');

  /// Only the clean route, its stops and its segment boundaries.
  static const clean = RouteRecordingDetail._('clean');

  /// Everything, including gaps, quality runs and diagnostics.
  static const full = RouteRecordingDetail._('full');

  /// Every mode, in declaration order.
  static const values = <RouteRecordingDetail>[automatic, clean, full];

  /// Stable name, also the stored and channel value.
  final String name;

  /// The mode named [name], or null when it is unknown.
  static RouteRecordingDetail? tryParse(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  /// The mode a route stored as [name] was recorded with; routes stored
  /// without one, or with an unknown one, were recorded in [full].
  static RouteRecordingDetail stored(Object? name) =>
      name == clean.name ? clean : full;

  @override
  String toString() => 'RouteRecordingDetail.$name';
}
