Pod::Spec.new do |s|
  s.name             = 'SallaPushExtension'
  s.version          = '1.0.4'
  s.summary          = 'SallaPush for the Notification Service Extension.'
  s.description      = 'Displays SallaPush notifications with their attachments and reports their received events from a Notification Service Extension.'
  s.homepage         = 'https://github.com/SallaApp/mobile-push-ios-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'Salla'
  s.source           = { :git => 'https://github.com/SallaApp/mobile-push-ios-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/SallaPushExtension/**/*.swift'
  s.resource_bundles = { 'SallaPushExtension_Privacy' => ['Sources/SallaPushExtension/PrivacyInfo.xcprivacy'] }
  s.dependency 'SallaPushCore', s.version.to_s
  s.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name SallaPush',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES'
  }
end
