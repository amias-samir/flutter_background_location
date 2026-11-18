import 'dart:convert';

import 'tracking_config.dart';
import 'tracking_configuration_epoch.dart';

/// Decodes a [TrackingConfig] that this package persisted.
///
/// [TrackingConfig.fromMap] resolves a missing key like the constructor, which
/// is right for host-supplied maps. A stored configuration without
/// `motionPolicyVersion` was written before the key existed, so it keeps
/// [TrackingPolicyVersions.legacyMotionPolicy]: a route that was recording
/// across a package upgrade resumes with the state machine it started with.
/// Likewise one without `turnCaptureDegrees` keeps sampling without turn
/// capture, and one without `samplingPolicyVersion` keeps
/// [TrackingPolicyVersions.legacySamplingPolicy].
TrackingConfig decodePersistedTrackingConfig(String json) {
  // A route's stored configuration is read with every track row, several
  // times per fix; the result is immutable and depends only on the text.
  final cached = _decodedConfigs.remove(json);
  if (cached != null) {
    _decodedConfigs[json] = cached;
    return cached;
  }
  final config = _decode(json);
  _decodedConfigs[json] = config;
  if (_decodedConfigs.length > _decodedConfigCacheSize) {
    _decodedConfigs.remove(_decodedConfigs.keys.first);
  }
  return config;
}

final Map<String, TrackingConfig> _decodedConfigs = <String, TrackingConfig>{};
const _decodedConfigCacheSize = 32;

TrackingConfig _decode(String json) {
  final map = Map<String, Object?>.of(
    (jsonDecode(json) as Map).cast<String, Object?>(),
  )
    ..putIfAbsent(
      'motionPolicyVersion',
      () => TrackingPolicyVersions.legacyMotionPolicy,
    )
    ..putIfAbsent('turnCaptureDegrees', () => 0.0)
    ..putIfAbsent(
      'samplingPolicyVersion',
      () => TrackingPolicyVersions.legacySamplingPolicy,
    );
  return TrackingConfig.fromMap(map);
}
