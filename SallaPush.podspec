Pod::Spec.new do |s|
  s.name             = 'SallaPush'
  s.version          = '1.0.4'
  s.summary          = 'SallaPush iOS SDK: push notifications for the iOS apps of Salla stores.'
  s.description      = 'Registers the device with the SallaPush server, links customers, sends tags and events, and handles SallaPush notifications.'
  s.homepage         = 'https://github.com/SallaApp/mobile-push-ios-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'Salla'
  s.source           = { :git => 'https://github.com/SallaApp/mobile-push-ios-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/SallaPush/**/*.swift'
  s.resource_bundles = { 'SallaPush_Privacy' => ['Sources/SallaPush/PrivacyInfo.xcprivacy'] }
  s.dependency 'SallaPushCore', s.version.to_s
  s.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name SallaPush' }
end
