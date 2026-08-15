import CoreLocation
import Foundation

struct TrackingConfiguration {
  let movingIntervalMs: Double
  let movingDistanceFilterMeters: Double
  let stationaryIntervalMs: Double
  let stationaryDistanceFilterMeters: Double
  let stationaryTimeoutMs: Double
  let stationaryProbeDisplacementMeters: Double
  let maximumAcceptedAccuracyMeters: Double
  let movingDesiredAccuracy: CLLocationAccuracy
  let stationaryDesiredAccuracy: CLLocationAccuracy
  let activityType: CLActivityType
  let allowBackgroundLocationUpdates: Bool
  let requireAlwaysAuthorization: Bool
  let showBackgroundLocationIndicator: Bool
  let stationaryConfidenceThreshold: Int
  let movingConfidenceThreshold: Int
  let movingConfirmationCount: Int

  static let defaults = TrackingConfiguration(dictionary: [:])

  init(dictionary: [String: Any]) {
    movingIntervalMs = Self.number(
      dictionary["movingIntervalMs"],
      defaultValue: 15_000,
      minimum: 1_000
    )
    movingDistanceFilterMeters = Self.number(
      dictionary["movingDistanceFilterMeters"],
      defaultValue: 15,
      minimum: 0
    )
    stationaryIntervalMs = Self.number(
      dictionary["stationaryIntervalMs"],
      defaultValue: 120_000,
      minimum: 5_000
    )
    stationaryDistanceFilterMeters = Self.number(
      dictionary["stationaryDistanceFilterMeters"],
      defaultValue: 75,
      minimum: 0
    )
    stationaryTimeoutMs = Self.number(
      dictionary["stationaryTimeoutMs"] ?? dictionary["stationaryConfirmationMs"],
      defaultValue: 90_000,
      minimum: 0
    )
    stationaryProbeDisplacementMeters = Self.number(
      dictionary["stationaryProbeDisplacementMeters"],
      defaultValue: 30,
      minimum: 0
    )
    maximumAcceptedAccuracyMeters = Self.number(
      dictionary["maximumAcceptedAccuracyMeters"],
      defaultValue: 60,
      minimum: 1
    )
    movingDesiredAccuracy = Self.accuracy(
      dictionary["desiredAccuracy"],
      defaultValue: kCLLocationAccuracyBest
    )
    stationaryDesiredAccuracy = Self.accuracy(
      dictionary["stationaryDesiredAccuracy"],
      defaultValue: kCLLocationAccuracyHundredMeters
    )
    activityType = Self.activityType(dictionary["activityType"])
    allowBackgroundLocationUpdates = Self.boolean(
      dictionary["allowBackgroundLocationUpdates"],
      defaultValue: true
    )
    requireAlwaysAuthorization = Self.boolean(
      dictionary["requireAlwaysAuthorization"],
      defaultValue: true
    )
    showBackgroundLocationIndicator = Self.boolean(
      dictionary["showBackgroundLocationIndicator"],
      defaultValue: true
    )
    stationaryConfidenceThreshold = Self.integer(
      dictionary["stationaryConfidenceThreshold"],
      defaultValue: 75,
      minimum: 0,
      maximum: 100
    )
    movingConfidenceThreshold = Self.integer(
      dictionary["movingConfidenceThreshold"],
      defaultValue: 60,
      minimum: 0,
      maximum: 100
    )
    movingConfirmationCount = Self.integer(
      dictionary["movingConfirmationCount"],
      defaultValue: 2,
      minimum: 1,
      maximum: 20
    )
  }

  var dictionary: [String: Any] {
    [
      "movingIntervalMs": movingIntervalMs,
      "movingDistanceFilterMeters": movingDistanceFilterMeters,
      "stationaryIntervalMs": stationaryIntervalMs,
      "stationaryDistanceFilterMeters": stationaryDistanceFilterMeters,
      "stationaryTimeoutMs": stationaryTimeoutMs,
      "stationaryConfirmationMs": stationaryTimeoutMs,
      "stationaryProbeDisplacementMeters": stationaryProbeDisplacementMeters,
      "maximumAcceptedAccuracyMeters": maximumAcceptedAccuracyMeters,
      "desiredAccuracy": movingDesiredAccuracy,
      "stationaryDesiredAccuracy": stationaryDesiredAccuracy,
      "activityType": Self.activityTypeName(activityType),
      "allowBackgroundLocationUpdates": allowBackgroundLocationUpdates,
      "requireAlwaysAuthorization": requireAlwaysAuthorization,
      "showBackgroundLocationIndicator": showBackgroundLocationIndicator,
      "stationaryConfidenceThreshold": stationaryConfidenceThreshold,
      "movingConfidenceThreshold": movingConfidenceThreshold,
      "movingConfirmationCount": movingConfirmationCount,
    ]
  }

  private static func number(
    _ value: Any?,
    defaultValue: Double,
    minimum: Double
  ) -> Double {
    let parsed: Double
    if let number = value as? NSNumber {
      parsed = number.doubleValue
    } else if let string = value as? String, let number = Double(string) {
      parsed = number
    } else {
      parsed = defaultValue
    }
    return parsed.isFinite ? max(parsed, minimum) : defaultValue
  }

  private static func integer(
    _ value: Any?,
    defaultValue: Int,
    minimum: Int,
    maximum: Int
  ) -> Int {
    let parsed: Int
    if let number = value as? NSNumber {
      parsed = number.intValue
    } else if let string = value as? String, let number = Int(string) {
      parsed = number
    } else {
      parsed = defaultValue
    }
    return min(max(parsed, minimum), maximum)
  }

  private static func boolean(_ value: Any?, defaultValue: Bool) -> Bool {
    if let bool = value as? Bool {
      return bool
    }
    if let number = value as? NSNumber {
      return number.boolValue
    }
    if let string = value as? String {
      switch string.lowercased() {
      case "true", "yes", "1": return true
      case "false", "no", "0": return false
      default: break
      }
    }
    return defaultValue
  }

  private static func accuracy(
    _ value: Any?,
    defaultValue: CLLocationAccuracy
  ) -> CLLocationAccuracy {
    if let number = value as? NSNumber {
      let meters = number.doubleValue
      switch meters {
      case kCLLocationAccuracyBestForNavigation,
        kCLLocationAccuracyBest,
        kCLLocationAccuracyNearestTenMeters,
        kCLLocationAccuracyHundredMeters,
        kCLLocationAccuracyKilometer,
        kCLLocationAccuracyThreeKilometers:
        return meters
      default:
        return meters > 0 ? meters : defaultValue
      }
    }

    guard let name = value as? String else {
      return defaultValue
    }
    switch name.replacingOccurrences(of: "_", with: "").lowercased() {
    case "bestfornavigation", "navigation":
      return kCLLocationAccuracyBestForNavigation
    case "best", "high":
      return kCLLocationAccuracyBest
    case "nearesttenmeters", "medium":
      return kCLLocationAccuracyNearestTenMeters
    case "hundredmeters", "low":
      return kCLLocationAccuracyHundredMeters
    case "kilometer", "lowest":
      return kCLLocationAccuracyKilometer
    case "threekilometers":
      return kCLLocationAccuracyThreeKilometers
    default:
      return defaultValue
    }
  }

  private static func activityType(_ value: Any?) -> CLActivityType {
    guard let name = value as? String else {
      return .fitness
    }
    switch name.replacingOccurrences(of: "_", with: "").lowercased() {
    case "automotivenavigation", "automotive": return .automotiveNavigation
    case "othernavigation", "navigation": return .otherNavigation
    case "airbornenavigation", "airborne": return .airborne
    case "other": return .other
    default: return .fitness
    }
  }

  private static func activityTypeName(_ value: CLActivityType) -> String {
    switch value {
    case .automotiveNavigation: return "automotiveNavigation"
    case .otherNavigation: return "otherNavigation"
    case .airborne: return "airborne"
    case .other: return "other"
    default: return "fitness"
    }
  }
}
