import 'dart:convert';

import 'location_sample.dart';
import 'tracker_status.dart';

/// A nested payload value, also accepted as JSON text: Android journal rows
/// store nested values as JSON strings.
Object? _inflated(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

/// How completely the native step counter counted a capture generation.
///
/// A string-backed value rather than an enum, so a state a newer native side
/// reports survives as itself instead of breaking an exhaustive switch.
final class StepCoverageState {
  const StepCoverageState._(this.name);

  /// The state a native side named [name]; unknown names are kept.
  factory StepCoverageState.fromName(String name) {
    for (final known in values) {
      if (known.name == name) return known;
    }
    return StepCoverageState._(name);
  }

  /// The counter rose when steps were taken.
  static const counting = StepCoverageState._('counting');

  /// The device walked for a while without the count rising; native code is
  /// flushing or re-registering the counter.
  static const suspect = StepCoverageState._('suspect');

  /// The counter stopped counting while the device walked and repairs
  /// failed: steps after `lastRiseAt` are missing, never estimated.
  static const stalled = StepCoverageState._('stalled');

  /// No step counter, or no permission to read it.
  static const unavailable = StepCoverageState._('unavailable');

  /// Capture ended without a final flush; the count stands at the last
  /// checkpoint.
  static const endedUnflushed = StepCoverageState._('ended_unflushed');

  /// The states this package knows, in no particular order.
  static const values = <StepCoverageState>[
    counting,
    suspect,
    stalled,
    unavailable,
    endedUnflushed,
  ];

  /// The native name, such as `counting` or `ended_unflushed`.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is StepCoverageState && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// What the native step counter reports about its own completeness, on
/// location events and status (`stepCoverage`). Holds no step count.
final class StepCoverage {
  const StepCoverage({
    required this.state,
    this.countedThrough,
    this.lastRiseAt,
    this.uncounted = Duration.zero,
    this.sensor,
    this.reregistrations = 0,
  });

  final StepCoverageState state;

  /// Steps up to this time are in the count.
  final DateTime? countedThrough;

  /// When the count last rose.
  final DateTime? lastRiseAt;

  /// Walking time the counter is known to have missed.
  final Duration uncounted;

  /// The sensor counting, such as `step_counter_wakeup`, `step_counter` or
  /// `pedometer`.
  final String? sensor;

  /// How often native code re-registered a silent counter in this
  /// generation.
  final int reregistrations;

  /// Whether steps after [lastRiseAt] are known to be missing.
  bool get stalled => state == StepCoverageState.stalled;

  /// Decodes a native `stepCoverage` map; null when absent or without a
  /// state.
  static StepCoverage? fromPayload(Object? payload) {
    final value = _inflated(payload);
    if (value is! Map) return null;
    final state = value['state'];
    if (state is! String || state.trim().isEmpty) return null;
    return StepCoverage(
      state: StepCoverageState.fromName(state.trim()),
      countedThrough: _time(value['countedThrough']),
      lastRiseAt: _time(value['lastRiseAt']),
      uncounted: Duration(
        milliseconds: switch (value['uncountedMs']) {
          final num ms when ms.isFinite && ms > 0 => ms.toInt(),
          _ => 0,
        },
      ),
      sensor: switch (value['sensor']) {
        final String sensor when sensor.trim().isNotEmpty => sensor.trim(),
        _ => null,
      },
      reregistrations: switch (value['reregistrations']) {
        final num count when count.isFinite && count > 0 => count.toInt(),
        _ => 0,
      },
    );
  }

  static DateTime? _time(Object? value) => switch (value) {
        final num ms when ms.isFinite && ms > 0 =>
          DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true),
        _ => null,
      };
}

/// A capture generation's final step count, read from the counter as capture
/// stopped (`stepFinal` in status), so steps after the generation's newest
/// fix count too.
final class StepFinal {
  const StepFinal({
    required this.captureGenerationId,
    required this.stepCount,
    this.coverage,
  });

  final String captureGenerationId;

  /// Steps counted in the whole generation.
  final int stepCount;

  final StepCoverage? coverage;

  /// Decodes a native `stepFinal` map; null when absent or malformed.
  static StepFinal? fromPayload(Object? payload) {
    final value = _inflated(payload);
    if (value is! Map) return null;
    final generation = value['captureGenerationId'];
    final steps = stepCountFromPayload(value['stepCount']);
    if (generation is! String || generation.isEmpty || steps == null) {
      return null;
    }
    return StepFinal(
      captureGenerationId: generation,
      stepCount: steps,
      coverage: StepCoverage.fromPayload(value['stepCoverage']),
    );
  }
}

/// A switch between the native moving and stationary sampling profiles that
/// a journaled fix reports (`profileTransitions`), so the switches survive a
/// route drained from the journal long after capture.
final class SamplingProfileTransition {
  const SamplingProfileTransition({
    required this.sequence,
    required this.at,
    required this.from,
    required this.to,
    this.reason,
  });

  /// Arrival number within the capture generation, shared with the journaled
  /// activity readings.
  final int sequence;

  final DateTime at;
  final SamplingProfile from;
  final SamplingProfile to;

  /// Coordinate-free reason, such as `still_episode` or `doppler`.
  final String? reason;

  /// Decodes a native `profileTransitions` list, skipping malformed entries.
  static List<SamplingProfileTransition> listFromPayload(Object? payload) {
    final value = _inflated(payload);
    if (value is! List) return const <SamplingProfileTransition>[];
    final transitions = <SamplingProfileTransition>[];
    for (final item in value) {
      final entry = _inflated(item);
      if (entry is! Map) continue;
      final sequence = entry['seq'];
      final at = entry['at'];
      final from = _profile(entry['from']);
      final to = _profile(entry['to']);
      if (sequence is! num ||
          at is! num ||
          !at.isFinite ||
          at <= 0 ||
          from == null ||
          to == null) {
        continue;
      }
      transitions.add(
        SamplingProfileTransition(
          sequence: sequence.toInt(),
          at: DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true),
          from: from,
          to: to,
          reason: switch (entry['reason']) {
            final String reason when reason.trim().isNotEmpty => reason.trim(),
            _ => null,
          },
        ),
      );
    }
    return List<SamplingProfileTransition>.unmodifiable(transitions);
  }

  static SamplingProfile? _profile(Object? value) => switch (value) {
        'moving' => SamplingProfile.moving,
        'stationary' => SamplingProfile.stationary,
        _ => null,
      };
}

/// Optional controller capability: the native step counter's count-free
/// diagnostics ([StepCounterDiagnostic]), oldest first, to find out why a
/// phone's counter fell silent. Empty when the native side keeps none.
abstract interface class StepCounterDiagnosticsController {
  Future<List<StepCounterDiagnostic>> stepCounterDiagnostics();
}

/// One entry of the native step counter's diagnostics ring
/// (`getStepCounterDiagnostics`): what the counter and its watchdog did,
/// with no step counts or coordinates.
final class StepCounterDiagnostic {
  const StepCounterDiagnostic({
    required this.at,
    required this.event,
    this.sensor,
    this.registered,
    this.watchdogState,
    this.sinceDelivery,
    this.sinceRise,
    this.flushCompleted,
    this.replayOutcome,
    this.evidenceSource,
    this.reregistrations,
  });

  final DateTime at;

  /// Such as `start`, `stop`, `transition`, `flush`, `finalize` or
  /// `heartbeat`.
  final String event;
  final String? sensor;
  final bool? registered;
  final String? watchdogState;
  final Duration? sinceDelivery;
  final Duration? sinceRise;

  /// How long a requested flush took; null when it timed out or none ran.
  final Duration? flushCompleted;

  /// Whether the count rose after the event: `rose`, `same` or `none`.
  final String? replayOutcome;
  final String? evidenceSource;
  final int? reregistrations;

  /// Decodes one ring entry; null when it has no time or event.
  static StepCounterDiagnostic? fromPayload(Object? value) {
    if (value is! Map) return null;
    final at = value['at'];
    final event = value['event'];
    if (at is! num || !at.isFinite || event is! String || event.isEmpty) {
      return null;
    }
    Duration? duration(Object? raw) => switch (raw) {
          final num ms when ms.isFinite && ms >= 0 =>
            Duration(milliseconds: ms.toInt()),
          _ => null,
        };
    String? text(Object? raw) => switch (raw) {
          final String value when value.isNotEmpty => value,
          _ => null,
        };
    return StepCounterDiagnostic(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true),
      event: event,
      sensor: text(value['sensor']),
      registered:
          value['registered'] is bool ? value['registered']! as bool : null,
      watchdogState: text(value['watchdogState']),
      sinceDelivery: duration(value['sinceDeliveryMs']),
      sinceRise: duration(value['sinceRiseMs']),
      flushCompleted: duration(value['flushCompletedMs']),
      replayOutcome: text(value['replayOutcome']),
      evidenceSource: text(value['evidenceSource']),
      reregistrations: switch (value['reregistrations']) {
        final num count when count.isFinite && count >= 0 => count.toInt(),
        _ => null,
      },
    );
  }
}
