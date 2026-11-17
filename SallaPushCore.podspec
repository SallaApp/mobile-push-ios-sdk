Pod::Spec.new do |s|
  s.name             = 'SallaPushCore'
  s.version          = '1.1.0'
  s.summary          = 'The shared core of the SallaPush iOS SDK.'
  s.description      = 'Networking, storage, payload parsing and logging shared by SallaPush and SallaPushExtension.'
  s.homepage         = 'https://github.com/SallaApp/mobile-push-ios-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'Salla'
  s.source           = { :git => 'https://github.com/SallaApp/mobile-push-ios-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/SallaPushCore/**/*.swift'
  s.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name SallaPush',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES'
  }
end
