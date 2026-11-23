# TTMailer SDK for iOS

For apps without their own backend: registers the installation and its push token in TTMailer, signs the user up to
the newsletter (TTMailer sends a confirmation e-mail), links the app's account and reports opened pushes. No
dependencies, iOS 15+. The server API is described in `docs/sdk-api.md` of the TTMailer repository.

## Install

**Swift Package Manager:** File → Add Package Dependencies… → `https://github.com/tappytaps/ttmailer-sdk-ios` (the repository
location is still to be decided), product `TTMailer`.

**CocoaPods:**

```ruby
pod 'TTMailer', :git => 'https://github.com/tappytaps/ttmailer-sdk-ios.git', :tag => '0.1.0'
```

## Use

The app key comes from TTMailer: Nastavení → Aplikace (SDK). It is public (it ships in the app).

```swift
import TTMailer
import UserNotifications

// application(_:didFinishLaunchingWithOptions:)
TTMailer.configure(appKey: "tta_…")

// After the user allowed notifications and the app registered for remote notifications:
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    TTMailer.setPushToken(deviceToken)
}

// The app's notification switch, or the system permission:
TTMailer.setPushEnabled(true)

// Signed in / signed out (only for apps with accounts; use an unguessable id such as an account UUID):
TTMailer.setUserId(account.id)
TTMailer.setUserId(nil)

// Newsletter sign-up (TTMailer sends a confirmation e-mail in the device's language):
do {
    try await TTMailer.subscribe(email: email)
    // show "Check your inbox"
} catch TTMailerError.invalidEmail {
    // show "Invalid address"
} catch {
    // show "Try again later"
}

// A tap on a notification:
func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    if let link = TTMailer.opened(response.notification.request.content.userInfo) {
        // open the link (deep link or web)
    }
}

// The user deleted their account (GDPR):
try await TTMailer.deleteContact()
```

### What the SDK sends

- On launch, on every change (token, switch, user id) and when the app becomes active (at most once a day when nothing
  changed): the installation id (a random UUID kept in the app), the push token, the switch, the user id, the device
  language, time zone, app version and iOS version.
- Opens: the push's `ttmToken`, with the time of the tap. Kept while offline and sent later.
- Failed calls are retried with a growing pause while the app runs, and again on the next launch.

`TTMailer.reset()` removes this installation from TTMailer and starts a new one (e.g. a "reset app" button).

## Develop

```sh
swift test                                                   # unit tests (macOS)
xcodebuild -scheme TTMailer -destination 'generic/platform=iOS' build
pod lib lint --allow-warnings
```
