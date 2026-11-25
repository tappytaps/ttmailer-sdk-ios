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
- [8. Language, tags and premium](#8-language-tags-and-premium)
- [9. Reset and account deletion](#9-reset-and-account-deletion)
- [10. How the SDK behaves](#10-how-the-sdk-behaves)
- [11. Privacy](#11-privacy)
- [12. Testing and troubleshooting](#12-testing-and-troubleshooting)
- [13. API reference](#13-api-reference)
- [14. The server API](#14-the-server-api)

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
- **Push actions.** A push can open its link in the browser or the in-app browser, or show an in-app message written
  in TTMailer (`handle`, since 0.4.0).

The SDK has no dependencies (only Apple's UIKit, WebKit and SafariServices), supports iOS 15+ (macOS 12+ for tests) and works with both APNs and Firebase Messaging
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
Version* from `0.4.0` and add the `TTMailer` library to the app target.

In `Package.swift`:

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

TTMailer pushes carry `ttmToken` (for the open report) and usually a link under `redirectUrl`. Since 0.4.0 a push can
also say what a tap does (`ttmAction`, chosen in TTMailer under "Po klepnutí"). Pass every tap to `handle`:

```swift
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            if let link = TTMailer.handle(userInfo) {
                Router.open(link)   // a deep link (storky://…) or https
            }
        }
    }

    // Optional: show pushes while the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}

// application(_:didFinishLaunchingWithOptions:): deep links tapped in an in-app message.
TTMailer.onDeepLink = { url in Router.open(url) }
```

`handle` reports the open in the background (like `opened`), then does what the push asks for:

| "Po klepnutí" in TTMailer | What `handle` does | Returns |
|---|---|---|
| Otevřít aplikaci (the default) | Nothing: the app opens the link. | the link |
| Prohlížeč | Opens the link through the system: Safari, or the app of a universal link (the system decides). | `nil` |
| Prohlížeč v aplikaci | Opens the link in `SFSafariViewController`; an App Store / Google Play link opens the store. | `nil` |
| Zpráva v aplikaci | Shows the in-app message written in TTMailer full screen, over the app. | `nil` |

- **A push without an action**, or one from another source, works as before: `handle` returns its link, if it has one
  under the link key. A push with an action this SDK version does not know is treated the same way.
- **The presenter.** `handle(_:from:)` presents the in-app browser and the message over the view controller you pass
  (or whatever it already presents), by default over the key window's top view controller. It must be called on the
  main thread (it is `@MainActor`).
- **A cold start.** When the app was launched by the tap and its UI is not on screen yet (or an alert is showing), the
  SDK waits up to 5 seconds for it. If it never comes, the in-app browser link and the message's web version open
  through the system instead.
- **The in-app message** is a web page from TTMailer in a `WKWebView` with JavaScript off, a close button, a loading
  state (announced to VoiceOver) and an error view with "Try again" when the first load fails (no network, HTTP ≥ 400).
  A failure after the message has loaded (e.g. a link offline) keeps the message and shows a short notice. The
  screen's chrome follows dark mode; the page itself follows it when the project's message layout supports it
  (TTMailer's default layout does). Its links:
  - pages of TTMailer (https, its host and the message's host) and its click tracking stay in the message;
  - App Store / Google Play links open the store, the message stays;
  - other web links open in `SFSafariViewController` over the message;
  - a close link (`ttmailer://close`) closes the message;
  - **the app's own schemes** (`CFBundleURLSchemes` in its Info.plist, e.g. `storky://premium`) close the message and
    go to `TTMailer.onDeepLink`; without `onDeepLink` the SDK opens them through the system (the app gets them in its
    usual URL handler);
  - other schemes (`mailto:`, `tel:`, `sms:`, `maps:`, other apps) open through the system, the message stays;
  - `javascript:`, `data:`, `blob:`, `file:` and `about:` links do nothing. Frames inside the page never leave it.
- **Store links** are `apps.apple.com`, `itunes.apple.com`, `play.google.com/store…` and the schemes `itms-apps`,
  `itms-appss` and `market`. They always open the store, from the push and from a message alike.
- **Older SDKs.** Apps with an SDK before 0.4.0 get the same pushes: their `opened` returns the link (for a message, its
  web address), so the app still opens something sensible. TTMailer shows how many devices run 0.4.0 or later.

`opened(_:)` still works and does what it did: it reports the open and returns the link, but ignores the action. It is
deprecated in favour of `handle` and will stay for apps that route all links themselves. An open made offline is kept
and sent later (the last 100 at most); pushes without `ttmToken` are not reported.

#### App Store review

The in-app browser is Apple's `SFSafariViewController` and the message a plain `WKWebView`; the SDK uses only public
APIs, needs no entitlement and no `LSApplicationQueriesSchemes` (it opens URLs with `UIApplication.open` and never asks
`canOpenURL`). The SDK's code for this does not run in app extensions (`handle` is unavailable there).

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

## 8. Language, tags and premium

### The app's own language

```swift
TTMailer.setLanguage("de")   // the user picked German in the app
TTMailer.setLanguage(nil)    // back to the system language
```

TTMailer writes to the user in this language (e-mails and pushes with language variants). Kept between launches.

### Tags

```swift
TTMailer.addTags(["sportovec"])
TTMailer.removeTags(["beta"])
```

Tags of the user's contact, for audiences in TTMailer (e.g. people who use one feature). Keys: a-z, 0-9, `_` and `-`,
40 at most; uppercase is lowered. They wait offline and are sent with the installation. A tag the SDK adds can be
removed by the team in TTMailer and vice versa.

### App activity

TTMailer learns when the user last used the app: the SDK reports it at launch and when the app becomes active, at most
once a day. On by default; audiences in TTMailer can then pick e.g. "used the app in the last 30 days". To turn it off
(e.g. when the user opts out of analytics):

```swift
TTMailer.setActivityTracking(false)
```

Kept between launches. Off, the installation is still sent (when it changes, and once a day so TTMailer keeps it), but
never counts as activity. To make sure the very first launch reports nothing, call it right after `configure`.

### Premium (purchases)

TTMailer keeps the user's premium (until when, its kind, since when) for audiences like "trial ended, did not buy".
Two ways, pick one:

**Automatic (off by default).** The SDK reads the user's purchases from StoreKit 2 at launch, when the app becomes
active and on every new transaction (renewals, refunds, purchases on another device):

```swift
TTMailer.configure(appKey: "tta_…")
TTMailer.enableAutomaticPurchases()
```

An app that also sells add-ons (e.g. a theme pack) names the products that unlock the app:
`enableAutomaticPurchases(lifetimeProductIds: ["pro_lifetime"])`.

- An active auto-renewable subscription: premium until its end, kind `trial` (a free trial) or `paid`.
- A one-time purchase that unlocks the app: a lifetime premium. Without `lifetimeProductIds` that is every
  non-consumable; with it only the products listed.
- Every one-time product owned (non-consumable, non-renewing subscription): a tag `koupeno_<product>` (lowercase, other characters
  `_`), e.g. `koupeno_themes_pack`. A refunded product loses its tag.
- A refund or a revoked subscription ends the premium at once; an expired one ends on its own date.
- Consumables (coins, credits) are not reported.
- The SDK only reads: it never finishes transactions; the app keeps doing that.

**Manual**, e.g. with RevenueCat:

```swift
TTMailer.setPremium(until: info.expirationDate, kind: info.periodType == .trial ? "trial" : "paid", startedAt: info.originalPurchaseDate)
TTMailer.setLifetimePremium()
```

A date in the past says the premium ended. Each is sent once, again only when it changes.

The purchases are not verified with Apple: anyone could send any premium for their own installation (never for another
user). That is fine for marketing audiences; never grant anything because of them.

## 9. Reset and account deletion

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

## 10. How the SDK behaves

- **When it sends.**
  - The installation is sent at launch, on every change and when the app becomes active.
  - It holds the installation id (a random UUID), the token, the switch, the user id, the device language, time zone,
    app version, iOS version and the SDK's version (or the language set with `setLanguage`).
  - It is not sent when nothing changed and the last send is less than a day old. The daily send keeps "last active in
    the app" on the contact.
- **Offline.**
  - Updates never fail from the app's point of view; the SDK keeps the state and sends it later.
  - A failed send is retried on the next change or activation.
  - Opens, tags and the premium are queued and sent after the installation.
- **An unknown or disabled key** (404) is retried after a day, not on every launch.
- **Storage.** A `UserDefaults` suite `com.tappytaps.ttmailer.sdk`.
  - Deleting the app clears it; a reinstall is a new installation.
  - TTMailer removes the old device when the new installation sends the same push token, so a push never arrives twice.
- **Threads.** The state lives in an actor; the public methods are safe from any thread. `subscribe`, `reset` and
  `deleteContact` are `async throws`.
- **Size.** No dependencies (StoreKit only with the automatic premium), no background tasks, no swizzling: the app calls the SDK where it wants to.

## 11. Privacy

The SDK sends only what is listed in section 10, plus an e-mail address the user types for the newsletter. It does not
use the IDFA and does not track across apps.

For the App Store privacy details:

| Data | Linked to the user | Used for tracking | Purpose |
|---|---|---|---|
| Device ID (the installation id and push token) | yes | no | App functionality |
| Email address (only with the newsletter) | yes | no | App functionality, developer's marketing |
| User ID (only with `setUserId`) | yes | no | App functionality |
| Product interaction (push opens) | yes | no | Analytics |
| Purchase history (only with the premium, automatic or `setPremium`) | yes | no | Developer's marketing |

The SDK ships a privacy manifest (`PrivacyInfo.xcprivacy`) with these data types and its one required-reason API:
`UserDefaults` (reason `CA92.1`, its own state). Xcode merges it into the app's privacy report.

## 12. Testing and troubleshooting

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
  `application(_:didFinishLaunchingWithOptions:)` returns, and `didReceive` must call `TTMailer.handle` (or `opened`).
- **`subscribe` fails with `noForm` / `formWithoutConfirmation`.** Fix the app's form in TTMailer (section 2).
- **Everything fails with a 404 in the log.** The key is wrong, rotated or disabled, or the project is archived.
- **A test server.** `TTMailer.configure(appKey:baseURL:)` with its URL and a key from that server.

## 13. API reference

| Method | Description |
|---|---|
| `configure(appKey:baseURL:linkKey:)` | Starts the SDK. Call once at launch. |
| `setPushToken(_: Data)` | The APNs device token. |
| `setPushToken(_: String)` | A token as text (FCM). |
| `setPushEnabled(_: Bool)` | The user's notification choice; writes the app's push topic. |
| `setUserId(_: String?)` | The account id after sign-in; `nil` after sign-out. |
| `subscribe(email:language:) async throws -> Bool` | The newsletter sign-up with a confirmation e-mail. |
| `handle(_: [AnyHashable: Any], from: UIViewController? = nil) -> URL?` | `@MainActor`. Reports a tap on a push and does its action (browser, in-app browser, in-app message); returns the link only when the app should open it. |
| `onDeepLink: (@MainActor (URL) -> Void)?` | `@MainActor`. The app's own deep links tapped in an in-app message (after it closes). Without it the SDK opens them through the system. |
| `opened(_: [AnyHashable: Any]) -> URL?` | Deprecated in favour of `handle`: reports a tap on a push; returns its link, ignores the action. |
| `sdkVersion: String` | The SDK's version (`"0.4.0"`). |
| `reset() async throws` | Removes this installation and starts a new one. |
| `deleteContact() async throws` | Erases the user's contact (account deletion). |
| `installationId() async -> String?` | The current installation id. |
| `setActivityTracking(_: Bool)` | App activity reporting (on by default). |
| `setLanguage(_: String?)` | The app's own language; `nil` = the system's. |
| `addTags(_: [String])` / `removeTags(_: [String])` | Tags of the user's contact. |
| `setPremium(until:kind:startedAt:)` | The premium as the app knows it. |
| `setLifetimePremium(kind:startedAt:)` | A lifetime premium. |
| `enableAutomaticPurchases(lifetimeProductIds: Set<String>? = nil)` | The premium read from StoreKit 2 (off by default). |

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

## 14. The server API

The SDK is a thin client of TTMailer's public SDK API. Every call carries the header `X-TTMailer-App-Key`.

| Call | Used by |
|---|---|
| `PUT /sdk/v1/installations/{installationId}` with `{pushToken, pushEnabled, language, timeZone, appVersion, osVersion, sdkVersion, userId}` | sync |
| `POST /sdk/v1/installations/{installationId}/subscribe` with `{email, language}` | `subscribe` |
| `DELETE /sdk/v1/installations/{installationId}` | `reset` |
| `DELETE /sdk/v1/installations/{installationId}/contact` | `deleteContact` |
| `POST /p/open` with `{t: ttmToken, at}` (no key) | `handle`, `opened` |
| `GET <ttmUrl>` (the in-app message page) and its TTMailer links, each with the header `X-TTMailer-SDK: <sdkVersion>` (no key) | `handle` |

Limits:
- 300 calls per IP address and minute;
- 20,000 new installations per app and day (`429`).

An unknown or disabled key answers `404`.
