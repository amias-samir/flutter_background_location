import '../domain/route_geometry.dart';
import '../domain/route_map.dart';
import '../domain/route_review.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/track_stop.dart';
import '../domain/trip.dart';
import '../domain/tracking_continuity.dart';
import '../domain/tracking_start.dart';
import '../storage/route_map_repository.dart';
import 'route_geometry_assembler.dart';

/// Optional facade capability: routes and Trips ready to draw on a map.
///
/// Loading a map never writes to the route database or takes its write
/// lock, reads in bounded pages whatever the route's length, and can be
/// cancelled. Details a map lacks (a review or stops of a route recorded
/// under older rules, the cleaned view of a completed route) are prepared
/// in the background; the map reports [RouteMap.preparing] meanwhile.
abstract interface class TrackingMapController {
  /// [trackId] drawn in [view] when the route offers it, else in its first
  /// view ([RouteMap.views]). [isCancelled] is checked between reads; a
  /// cancelled load throws `route_map_cancelled`.
  Future<RouteMap> loadTrackMap(
    String trackId, {
    RouteGeometryView? view,
    RouteGeometryContinuity continuity =
        RouteGeometryContinuity.mergeAutomaticCallbackGaps,
    bool Function()? isCancelled,
  });

  /// [tripId]'s days drawn in [view] when the Trip offers it, else in its
  /// first view. Days without a review or cleaned view are drawn as
  /// recorded. [continuity] defaults to the Trip's route presentation.
  Future<RouteMap> loadTripMap(
    String tripId, {
    RouteGeometryView? view,
    RouteGeometryContinuity? continuity,
    bool Function()? isCancelled,
  });
}

/// A map and the routes whose details should be prepared for it.
final class RouteMapRead {
  const RouteMapRead(this.map, {this.prepare = const <String>[]});

  final RouteMap map;

  /// Routes to review, derive stops for, or clean in the background.
  final List<String> prepare;
}

/// Builds [RouteMap]s from [RouteMapRepository] reads. Internal.
final class RouteMapReader {
  RouteMapReader(
    this.store, {
    required this.now,
    this.pageSize = 1000,
    this.liveRefreshPoints = 300,
    this.liveRefreshInterval = const Duration(minutes: 15),
  });

  final RouteMapRepository store;
  final DateTime Function() now;
  final int pageSize;

  /// A recording route's cleaned view is refreshed once this many points
  /// have arrived since it was derived ...
  final int liveRefreshPoints;

  /// ... and at most this often.
  final Duration liveRefreshInterval;

  Future<RouteMapRead> loadTrack({
    required TrackingOwner owner,
    required String trackId,
    required RouteGeometryView? view,
    required RouteGeometryContinuity continuity,
    required void Function() checkpoint,
  }) async {
    final leg = await store.routeMapLeg(owner, trackId);
    checkpoint();
    final views = <RouteGeometryView>[
      if (leg.reviewRunId != null) RouteGeometryView.reviewed,
      RouteGeometryView.cleaned,
      RouteGeometryView.raw,
    ];
    final shown = views.contains(view) ? view! : views.first;
    final drawn = await _readLeg(leg, shown, legNumber: 1, checkpoint);
    checkpoint();
    final report = _assemble(
      drawn.parts,
      gaps: leg.gaps,
      continuity: continuity,
      cleaned: drawn.cleaned,
    );
    final prepare = _preparation(leg, shown);
    return RouteMapRead(
      RouteMap(
        geometry: report,
        view: shown,
        views: views,
        stops: leg.stops,
        routeSummary: leg.summary,
        preparing: prepare.preparing,
      ),
      prepare: <String>[if (prepare.enqueue) trackId],
    );
  }

  Future<RouteMapRead> loadTrip({
    required TrackingOwner owner,
    required String tripId,
    required RouteGeometryView? view,
    required RouteGeometryContinuity? continuity,
    required void Function() checkpoint,
  }) async {
    final trip = await store.routeMapTrip(owner, tripId);
    checkpoint();
    final legs = <(int, RouteMapLegSource)>[];
    for (final leg in trip.legs) {
      legs.add((leg.legNumber, await store.routeMapLeg(owner, leg.trackId)));
      checkpoint();
    }
    final views = <RouteGeometryView>[
      if (legs.any((leg) => leg.$2.reviewRunId != null))
        RouteGeometryView.reviewed,
      RouteGeometryView.cleaned,
      RouteGeometryView.raw,
    ];
    final shown = views.contains(view) ? view! : views.first;
    final parts = <RouteGeometrySourcePart>[];
    final cleaned = <String, (double, double)>{};
    final stops = <TrackStop>[];
    final prepare = <String>[];
    var preparing = false;
    for (final (legNumber, leg) in legs) {
      final drawn =
          await _readLeg(leg, shown, legNumber: legNumber, checkpoint);
      checkpoint();
      parts.addAll(drawn.parts);
      cleaned.addAll(drawn.cleaned);
      stops.addAll(leg.stops);
      final needs = _preparation(leg, shown);
      preparing = preparing || needs.preparing;
      if (needs.enqueue) prepare.add(leg.track.id);
    }
    stops.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final report = _assemble(
      parts,
      gaps: trip.gaps,
      continuity: continuity ?? trip.trip.routePresentation.geometryContinuity,
      cleaned: cleaned,
    );
    return RouteMapRead(
      RouteMap(
        geometry: report,
        view: shown,
        views: views,
        stops: stops,
        tripSummary: trip.summary,
        preparing: preparing,
      ),
      prepare: prepare,
    );
  }

  /// [leg]'s source parts in [view], read page by page, and the cleaned
  /// coordinates of the points that have them.
  Future<_DrawnLeg> _readLeg(
    RouteMapLegSource leg,
    RouteGeometryView view,
    void Function() checkpoint, {
    required int legNumber,
  }) async {
    final reviewRunId =
        view == RouteGeometryView.reviewed ? leg.reviewRunId : null;
    final cleanedRunId =
        view == RouteGeometryView.cleaned ? leg.cleanedRun?.id : null;
    final bySegment = <String, List<TrackPoint>>{};
    final cleaned = <String, (double, double)>{};
    var after = 0;
    while (after < leg.upperSequence) {
      final rows = await store.routeMapPointPage(
        trackId: leg.track.id,
        afterSequence: after,
        upperSequence: leg.upperSequence,
        limit: pageSize,
        cleanedRunId: cleanedRunId,
        reviewRunId: reviewRunId,
      );
      checkpoint();
      for (final row in rows) {
        var point = row.point;
        // A review's view is the route with exactly its kept fixes accepted.
        if (reviewRunId != null && !point.accepted) {
          point = point.withAcceptance(
            accepted: true,
            rejectionReason: RouteReview.notKeptReason,
          );
        }
        (bySegment[point.segmentId] ??= <TrackPoint>[]).add(point);
        if (row.hasCleaned) {
          cleaned[point.id] = (row.cleanedLatitude!, row.cleanedLongitude!);
        }
      }
      if (rows.length < pageSize) break;
      after = rows.last.point.sequence;
    }
    return _DrawnLeg(
      parts: <RouteGeometrySourcePart>[
        for (final segment in leg.segments)
          RouteGeometrySourcePart(
            legNumber: legNumber,
            segment: segment,
            points: bySegment[segment.id] ?? const <TrackPoint>[],
            legacyAutomaticGapEligible:
                leg.legacyAutomaticAfterSegmentIds.contains(segment.id),
          ),
      ],
      cleaned: cleaned,
    );
  }

  /// The one topology policy over the recorded points; cleaned coordinates
  /// replace recorded ones by point afterwards, so topology and connectors
  /// are those of the recorded route.
  static RouteGeometryReport _assemble(
    Iterable<RouteGeometrySourcePart> parts, {
    required Iterable<TrackingContinuityGap> gaps,
    required RouteGeometryContinuity continuity,
    required Map<String, (double, double)> cleaned,
  }) {
    final report = const RouteGeometryAssembler().assemble(
      sourceParts: parts,
      gaps: gaps,
      continuity: continuity,
    );
    if (cleaned.isEmpty) return report;
    return RouteGeometryReport(
      continuity: report.continuity,
      parts: <RouteGeometryPart>[
        for (final part in report.parts)
          RouteGeometryPart(
            partNumber: part.partNumber,
            points: <TrackPoint>[
              for (final point in part.points)
                switch (cleaned[point.id]) {
                  (final latitude, final longitude) => point.withCoordinates(
                      latitude: latitude,
                      longitude: longitude,
                    ),
                  null => point,
                },
            ],
            sourceSegmentIds: part.sourceSegmentIds,
            sourceLegNumbers: part.sourceLegNumbers,
          ),
      ],
      inferredConnectors: report.inferredConnectors,
      sourceSegmentCount: report.sourceSegmentCount,
      gapCount: report.gapCount,
      gaps: report.gaps,
    );
  }

  /// Whether [leg] waits for details in [view], and whether to prepare it.
  ({bool preparing, bool enqueue}) _preparation(
    RouteMapLegSource leg,
    RouteGeometryView view,
  ) {
    final track = leg.track;
    final ended = track.status == TrackStatus.completed ||
        track.status == TrackStatus.failed;
    final details = ended && (leg.awaitsReview || leg.stopsPending);
    var cleaning = false;
    var liveCleaning = false;
    if (view == RouteGeometryView.cleaned && track.acceptedPointCount > 0) {
      final run = leg.cleanedRun;
      final covered = run?.sourceMaximumSequence ?? 0;
      if (ended) {
        cleaning = covered < leg.upperSequence;
      } else {
        liveCleaning = leg.upperSequence - covered >= liveRefreshPoints &&
            (run == null ||
                !now().isBefore(run.createdAt.add(liveRefreshInterval)));
      }
    }
    return (
      preparing: details || cleaning,
      enqueue: details || cleaning || liveCleaning,
    );
  }
}

final class _DrawnLeg {
  const _DrawnLeg({required this.parts, required this.cleaned});

  final List<RouteGeometrySourcePart> parts;
  final Map<String, (double, double)> cleaned;
}
