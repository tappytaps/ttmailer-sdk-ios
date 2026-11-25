# TTMailer SDK for iOS

For apps without their own backend: registers the installation and its push token in TTMailer, signs the user up to
the newsletter (TTMailer sends a confirmation e-mail), links the app's account and reports opened pushes. No
dependencies, iOS 15+.

**📖 Full guide: [docs/integration.md](docs/integration.md)**: the setup in TTMailer, push, accounts, the newsletter,
privacy (App Store), troubleshooting and the API reference.

## Install

### Swift Package Manager (recommended)

In Xcode: File → Add Package Dependencies… → `https://github.com/tappytaps/ttmailer-sdk-ios`. Choose *Up to Next Minor
Version* from `0.4.0` and add the `TTMailer` library to the app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tappytaps/ttmailer-sdk-ios", from: "0.4.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "TTMailer", package: "ttmailer-sdk-ios")]),
]
```

### CocoaPods

```ruby
pod 'TTMailer', :git => 'https://github.com/tappytaps/ttmailer-sdk-ios.git', :tag => '0.4.0'
```

The SDK includes its privacy manifest (`PrivacyInfo.xcprivacy`).

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

// A tap on a notification: reports the open and does the push's action (browser, in-app browser, in-app message).
// It returns the link only when the app should open it itself:
func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let userInfo = response.notification.request.content.userInfo
    await MainActor.run {
        if let link = TTMailer.handle(userInfo) {
            // open the link (deep link or web)
        }
    }
}
// Deep links tapped in an in-app message (set at launch; without it the SDK opens them through the system):
TTMailer.onDeepLink = { url in /* route the deep link */ }

// The user deleted their account (GDPR):
try await TTMailer.deleteContact()

// The app's own language, tags for audiences:
TTMailer.setLanguage("de")
TTMailer.addTags(["sportovec"])

// Premium: read from StoreKit 2 (off by default) …
TTMailer.enableAutomaticPurchases()
// … or reported by the app (e.g. from RevenueCat):
TTMailer.setPremium(until: expirationDate, kind: "paid")
```

### Taps on pushes (0.4.0)

In TTMailer, a push says what a tap does ("Po klepnutí"); `handle` carries it out:

- **Otevřít aplikaci** (the default, and pushes from other sources): `handle` returns the link and the app opens it.
- **Prohlížeč**: a system open (Safari, or the app of a universal link).
- **Prohlížeč v aplikaci**: `SFSafariViewController`; App Store / Google Play links open the store.
- **Zpráva v aplikaci**: a full-screen message written in TTMailer (a `WKWebView` with JavaScript off, a close button,
  "Try again" when it cannot load). Its web links open in `SFSafariViewController`, store links in the store; a link
  with the app's own scheme closes it and goes to `onDeepLink`, other schemes (`mailto:`, `tel:`…) open through the
  system.

`opened(_:)` still works (it reports the open and returns the link, ignoring the action), but is deprecated in favour of
`handle`. App Store review: only public APIs (`SFSafariViewController`, `WKWebView`, `UIApplication.open`), no
entitlements and no `LSApplicationQueriesSchemes`. Details: [docs/integration.md](docs/integration.md#taps).

### What the SDK sends

- On launch, on every change (token, switch, user id) and when the app becomes active (at most once a day when nothing
  changed): the installation id (a random UUID kept in the app), the push token, the switch, the user id, the device
  language, time zone, app version, iOS version and the SDK's version.
- Opens: the push's `ttmToken`, with the time of the tap. Kept while offline and sent later.
- Failed calls are retried with a growing pause while the app runs, and again on the next launch.

`TTMailer.reset()` removes this installation from TTMailer and starts a new one (e.g. a "reset app" button).

## Develop

```sh
swift test                                                   # unit tests (macOS)
xcodebuild -scheme TTMailer -destination 'generic/platform=iOS' build
xcodebuild -scheme TTMailer -destination 'platform=iOS Simulator,name=<simulator>' test   # + UIKit/WebKit tests
pod lib lint --allow-warnings
```
