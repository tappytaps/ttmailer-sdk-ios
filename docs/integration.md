# TTMailer iOS SDK – integration guide

This guide walks through adding the TTMailer SDK to an iOS app, from the setup in TTMailer to release. For a quick
overview see the [README](../README.md).

- [1. What the SDK does](#1-what-the-sdk-does)
- [2. Set up the app in TTMailer](#2-set-up-the-app-in-ttmailer)
- [3. Add the SDK to the project](#3-add-the-sdk-to-the-project)
- [4. Start the SDK](#4-start-the-sdk)
- [5. Push notifications](#5-push-notifications)
- [6. User accounts](#6-user-accounts)
- [7. Newsletter sign-up](#7-newsletter-sign-up)
- [8. Reset and account deletion](#8-reset-and-account-deletion)
- [9. How the SDK behaves](#9-how-the-sdk-behaves)
- [10. Privacy](#10-privacy)
- [11. Testing and troubleshooting](#11-testing-and-troubleshooting)
- [12. API reference](#12-api-reference)
- [13. The server API](#13-the-server-api)

## 1. What the SDK does

TTMailer sends e-mails and push notifications to a project's contacts. Apps that have their own backend sync their users
to TTMailer from that backend. Apps without a backend use this SDK instead:

- **The installation.** Each installation of the app is a contact in TTMailer, with a device that holds the push token.
  The contact needs no e-mail address, so pushes work right after the first launch.
- **The push switch.** The app's notification setting decides whether the contact gets pushes of the app's push topic.
- **The account.** Apps with sign-in pass their account id, so all devices of one user become one contact.
- **The newsletter.** The user enters an e-mail address in the app and TTMailer sends a confirmation e-mail. Only after
  the confirmation does the address join the installation's contact. Without a confirmation nothing is joined, so
  nobody can attach someone else's address.
- **Push opens.** A tap on a TTMailer push is reported back, so open rates and automations work.

The SDK has no dependencies, supports iOS 15+ (macOS 12+ for tests) and works with both APNs and Firebase Messaging
tokens.

## 2. Set up the app in TTMailer

Someone with access to the TTMailer project does this once per app (iOS and Android are two separate apps):

1. **Push notifications** (Nastavení → Push notifikace): the project needs APNs credentials for the app's bundle id.
   Without them the device is registered but pushes cannot be delivered.
2. **Push topic** (Nastavení → Témata odběru): a topic with the channel *push*, e.g. "App notifications". The app's
   notification switch writes this topic.
3. **Sign-up form** (Nastavení → Formuláře), only for the in-app newsletter: a form with **confirmation turned on**. It
   sets the newsletter topics, the confirmation e-mail and its texts. A form without confirmation cannot be used.
4. **The app** (Nastavení → Aplikace (SDK)) → Add:
   - name: e.g. "Storky iOS";
   - platform: iOS;
   - bundle id: e.g. `com.tappytaps.storky`, exactly as in Xcode;
   - the form and the push topic from steps 2 and 3.

   TTMailer shows the app key `tta_…`.

The app key is **not a secret**. It ships inside the app and anyone can extract it, so it is fine in source code and
in public repositories. It only lets the app write its own installation, and the address always needs the
confirmation. If a key is abused, use *Rotate key* in TTMailer and release an app update with the new key; the old key
stops working at once. *Disable* stops an app without deleting it.

## 3. Add the SDK to the project

### Swift Package Manager (recommended)

Xcode → File → Add Package Dependencies… → `https://github.com/tappytaps/ttmailer-sdk-ios`. Choose *Up to Next Minor
Version* from `0.1.1` and add the `TTMailer` library to the app target.

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tappytaps/ttmailer-sdk-ios", from: "0.1.1"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "TTMailer", package: "ttmailer-sdk-ios")]),
]
```

### CocoaPods

```ruby
pod 'TTMailer', :git => 'https://github.com/tappytaps/ttmailer-sdk-ios.git', :tag => '0.1.1'
```

### Xcode capabilities

- *Push Notifications*.
- *Background Modes → Remote notifications* only if the app handles silent pushes; the SDK does not need it.

## 4. Start the SDK

Call `configure` once, as early as possible:

```swift
import TTMailer

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        TTMailer.configure(appKey: "tta_XXXXXXXXXXXXXXXXXXXXXXXX")
        UNUserNotificationCenter.current().delegate = self
        return true
    }
}
```

In a SwiftUI app, use `@UIApplicationDelegateAdaptor` with the same delegate.

`configure` parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `appKey` | — | The app key from TTMailer. |
| `baseURL` | `https://mailer.tappytaps.com` | The TTMailer server; change it only for a test server. |
| `linkKey` | `redirectUrl` | The push data key that holds the push's link. It must match the project's push format in TTMailer. |

From then on the SDK keeps itself up to date: it sends the installation at launch and when the app becomes active.
Every other method may be called from any thread, before or after the network is available.

## 5. Push notifications

### The token

Ask for permission when it suits the app, then register for remote notifications and pass the token on:

```swift
let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
TTMailer.setPushEnabled(granted)
if granted { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }

func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    TTMailer.setPushToken(deviceToken)   // APNs token, sent as hex
}
```

Register for remote notifications **at every launch** when permission is granted: iOS may change the token, and the SDK
sends it only when it changed.

**With Firebase Messaging on iOS**, pass the FCM token string instead. The TTMailer project must then send this app's
pushes through FCM.

```swift
func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    if let fcmToken { TTMailer.setPushToken(fcmToken) }
}
```

### The switch

`setPushEnabled` tells TTMailer whether the user wants notifications. It subscribes or unsubscribes the contact from
the app's push topic. This is the user's own choice, so it also overrides an earlier unsubscribe.

Call it:
- after the permission prompt;
- when the user flips the app's own switch;
- at launch with the current system state, since the user may have turned notifications off in Settings:

```swift
let settings = await UNUserNotificationCenter.current().notificationSettings()
TTMailer.setPushEnabled(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
```

If the app has its own in-app switch, send `appSwitch && systemAllowed`.

### Taps

TTMailer pushes carry `ttmToken` (for the open report) and usually a link under `redirectUrl`. When the user taps one:

```swift
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let link = TTMailer.opened(response.notification.request.content.userInfo) {
            await MainActor.run { Router.open(link) }   // a deep link (storky://…) or https
        }
    }

    // Optional: show pushes while the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
```

`opened` returns the link at once and reports the open in the background. Pushes from other sources (no `ttmToken`)
are not reported; `opened` returns their link if they have one under the same key. An open made offline is kept and
sent later (the last 100 at most).

## 6. User accounts

Skip this section if the app has no sign-in.

```swift
TTMailer.setUserId(account.id)   // after sign-in, and at launch while signed in
TTMailer.setUserId(nil)          // after sign-out
```

- **The first sign-in.** The installation's anonymous contact becomes the user's contact, and it keeps a confirmed
  address and its consents. If the user already has a contact (another phone), this device moves to it, so pushes go
  to all of the user's devices.
- **Sign-out.** The installation starts a new anonymous contact. The user's contact keeps nothing of this phone.
- **The id must be unguessable**, e.g. an account UUID, never an e-mail address or a sequential number. Anyone with the
  app key and a user's id could move a device to that user.
- Calling it repeatedly with the same id is free: nothing is sent when nothing changed.

## 7. Newsletter sign-up

```swift
func signUp(_ email: String) async {
    do {
        try await TTMailer.subscribe(email: email)
        showMessage("Check your inbox and confirm the subscription.")
    } catch TTMailerError.invalidEmail {
        showMessage("This doesn't look like an e-mail address.")
    } catch TTMailerError.rateLimited {
        showMessage("Too many attempts. Try again in a while.")
    } catch {
        showMessage("Something went wrong. Try again later.")
    }
}
```

- TTMailer always answers the same way, whatever the address (already subscribed, unsubscribed, new), so the app
  cannot learn who is subscribed. Show "check your inbox" every time.
- The confirmation e-mail uses the device language. Pass `language:` (e.g. `"cs"`) to choose another one.
- **After the confirmation** the address joins the contact this installation belongs to at that moment, also after a
  sign-in in the meantime. From then on e-mails and pushes go to one contact.
- If the address already belonged to someone in TTMailer before this sign-up (web form, import, another app user), it
  is only subscribed and never merged into the installation. So the app key can never take over a known person.
- `noForm` and `formWithoutConfirmation` are setup errors (section 2): the app has no form, or the form does not confirm.

## 8. Reset and account deletion

```swift
try await TTMailer.deleteContact()   // the user deleted their account in the app (GDPR erasure)
try await TTMailer.reset()           // a "reset app" / "sign out everywhere" action, or opting out of TTMailer
```

- `deleteContact()` erases the installation's contact in TTMailer: its address, devices, consents and history. It only
  erases contacts the SDK writes, never one that a backend syncs.
- `reset()` removes this device. It also removes the anonymous contact when that has no address. A signed-in user's
  contact stays.
- Both start a new installation (a new id) and forget the token, the switch and the user id. Call `setPushToken` /
  `setPushEnabled` again if the app keeps running with pushes.
- Both throw on network errors (`TTMailerError.network`), so the app can retry. Nothing changes locally until TTMailer
  confirms.

## 9. How the SDK behaves

- **When it sends.**
  - The installation is sent at launch, on every change and when the app becomes active.
  - It holds the installation id (a random UUID), the token, the switch, the user id, the device language, time zone,
    app version and iOS version.
  - It is not sent when nothing changed and the last send is less than a day old. The daily send keeps "last active in
    the app" on the contact.
- **Offline.**
  - Updates never fail from the app's point of view; the SDK keeps the state and sends it later.
  - A failed send is retried on the next change or activation.
  - Opens are queued.
- **An unknown or disabled key** (404) is retried after a day, not on every launch.
- **Storage.** A `UserDefaults` suite `com.tappytaps.ttmailer.sdk`.
  - Deleting the app clears it; a reinstall is a new installation.
  - TTMailer removes the old device when the new installation sends the same push token, so a push never arrives twice.
- **Threads.** The state lives in an actor; the public methods are safe from any thread. `subscribe`, `reset` and
  `deleteContact` are `async throws`.
- **Size.** No dependencies, no background tasks, no swizzling: the app calls the SDK where it wants to.

## 10. Privacy

The SDK sends only what is listed in section 9, plus an e-mail address the user types for the newsletter. It does not
use the IDFA and does not track across apps.

For the App Store privacy details:

| Data | Linked to the user | Used for tracking | Purpose |
|---|---|---|---|
| Device ID (the installation id and push token) | yes | no | App functionality |
| Email address (only with the newsletter) | yes | no | App functionality, developer's marketing |
| User ID (only with `setUserId`) | yes | no | App functionality |
| Product interaction (push opens) | yes | no | Analytics |

The SDK ships a privacy manifest (`PrivacyInfo.xcprivacy`) with these data types and its one required-reason API:
`UserDefaults` (reason `CA92.1`, its own state). Xcode merges it into the app's privacy report.

## 11. Testing and troubleshooting

- **Does TTMailer see the installation?** In TTMailer → Kontakty, find the contact with external id
  `sdk:i:<installation id>`, or `sdk:u:<user id>` after a sign-in. It should have a device `sdk:<installation id>`. The
  installation id is in `await TTMailer.installationId()`; log it in debug builds.
- **No device on the contact.** The app did not pass a token. Check that `registerForRemoteNotifications()` is called
  and that `didRegisterForRemoteNotificationsWithDeviceToken` runs; it does not run in the Simulator before iOS 16 or
  without the Push Notifications capability.
- **The device is there, but pushes do not arrive.**
  - Check the project's APNs credentials and the bundle id of the app in TTMailer.
  - A development build gets sandbox tokens: TTMailer must send it through the APNs sandbox.
- **The push arrives, but the open is not counted.** `UNUserNotificationCenter.current().delegate` must be set before
  `application(_:didFinishLaunchingWithOptions:)` returns, and `didReceive` must call `TTMailer.opened`.
- **`subscribe` fails with `noForm` / `formWithoutConfirmation`.** Fix the app's form in TTMailer (section 2).
- **Everything fails with a 404 in the log.** The key is wrong, rotated or disabled, or the project is archived.
- **A test server.** `TTMailer.configure(appKey:baseURL:)` with its URL and a key from that server.

## 12. API reference

| Method | Description |
|---|---|
| `configure(appKey:baseURL:linkKey:)` | Starts the SDK. Call once at launch. |
| `setPushToken(_: Data)` | The APNs device token. |
| `setPushToken(_: String)` | A token as text (FCM). |
| `setPushEnabled(_: Bool)` | The user's notification choice; writes the app's push topic. |
| `setUserId(_: String?)` | The account id after sign-in; `nil` after sign-out. |
| `subscribe(email:language:) async throws -> Bool` | The newsletter sign-up with a confirmation e-mail. |
| `opened(_: [AnyHashable: Any]) -> URL?` | Reports a tap on a push; returns its link. |
| `reset() async throws` | Removes this installation and starts a new one. |
| `deleteContact() async throws` | Erases the user's contact (account deletion). |
| `installationId() async -> String?` | The current installation id. |

`TTMailerError`:

| Case | When |
|---|---|
| `notConfigured` | `configure` was not called. |
| `invalidEmail` | Not a valid address. |
| `noForm` | The app has no sign-up form in TTMailer, or it is disabled. |
| `formWithoutConfirmation` | The app's form does not confirm. |
| `rateLimited` | Too many requests from this network. |
| `network` | No connection or a timeout. |
| `server(status:code:)` | Any other answer. |

## 13. The server API

The SDK is a thin client of TTMailer's public SDK API. Every call carries the header `X-TTMailer-App-Key`.

| Call | Used by |
|---|---|
| `PUT /sdk/v1/installations/{installationId}` with `{pushToken, pushEnabled, language, timeZone, appVersion, osVersion, userId}` | sync |
| `POST /sdk/v1/installations/{installationId}/subscribe` with `{email, language}` | `subscribe` |
| `DELETE /sdk/v1/installations/{installationId}` | `reset` |
| `DELETE /sdk/v1/installations/{installationId}/contact` | `deleteContact` |
| `POST /p/open` with `{t: ttmToken, at}` (no key) | `opened` |

Limits:
- 300 calls per IP address and minute;
- 20,000 new installations per app and day (`429`).

An unknown or disabled key answers `404`.
