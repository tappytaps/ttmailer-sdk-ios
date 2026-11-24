Pod::Spec.new do |s|
  s.name             = 'TTMailer'
  s.version          = '0.3.0'
  s.summary          = 'TTMailer SDK: push token registration, newsletter sign-up with confirmation and push open reports.'
  s.description      = <<-DESC
    Small, dependency-free SDK for apps without their own backend: registers the installation and its APNs token in
    TTMailer, signs the user up to the newsletter (TTMailer sends a confirmation e-mail), links the app's account id
    and reports opened pushes.
  DESC
  s.homepage         = 'https://mailer.tappytaps.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright TappyTaps s.r.o.' }
  s.author           = { 'TappyTaps' => 'dev@tappytaps.com' }
  s.source           = { :git => 'https://github.com/tappytaps/ttmailer-sdk-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9']
  s.source_files     = 'Sources/TTMailer/**/*.swift'
  s.resource_bundles = { 'TTMailer_Privacy' => ['Sources/TTMailer/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation'
end
