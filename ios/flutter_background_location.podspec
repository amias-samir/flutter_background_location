Pod::Spec.new do |s|
  s.name             = 'flutter_background_location'
  s.version          = '0.1.0'
  s.summary          = 'Battery-aware background location and motion tracking for Flutter.'
  s.description      = <<-DESC
Native iOS support for continuous Core Location updates, Core Motion activity
classification, pause/resume, and best-effort simulated-location detection.
                       DESC
  s.homepage         = 'https://pub.dev/packages/flutter_background_location'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'flutter_background_location contributors'
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_background_location/Sources/flutter_background_location/**/*.swift'
  s.resource_bundles = {
    'flutter_background_location_privacy' => ['flutter_background_location/Sources/flutter_background_location/PrivacyInfo.xcprivacy']
  }
  s.dependency 'Flutter'
  s.frameworks = 'CoreLocation', 'CoreMotion'
  s.libraries = 'sqlite3'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
