# PhoneBox for iOS

This is the iOS app: a port of the Android app in [`../android`](../android). It turns an old iPhone or iPad into the same
desk panel for your computer.

It is a thin native shell around the **same panel**. The HTML/JS in `android/app/src/main/assets/www` is not copied:
the Xcode project bundles that folder as it is, so every widget, template, page, theme and translation works the same
on both platforms. The native code ports the Android shell file by file:

| Android (`android/app/src/main/java/...`) | iOS (`ios/PhoneBox/`) |
|---|---|
| `MainActivity.kt`: WebView, `/agent/*` proxy, `window.Android` bridge, sensors, kiosk mode | `PanelViewController.swift` and `PanelSchemeHandler.swift` |
| `AgentLink.kt`: USB / Wi-Fi routes, certificate pinning, QR pairing, paired computers | `AgentLink.swift` |
| `AgentStream.kt`: live server-sent-events stream | `AgentStream.swift` |
| `Dictation.kt`: speech to text for the Dictation widget | `Dictation.swift` |
| `res/values*/strings.xml` | `en.lproj`, `vi.lproj` `Localizable.strings` |
| launcher icon | `Assets.xcassets/AppIcon.appiconset` |

The panel calls the same bridge (`window.Android`, `window.onAndroidKey`, `window.onAndroidSpeech`,
`window.onAgentStream`, …), so `main.js` and the widgets need no changes.

## Build

You need a Mac with Xcode 15 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd ios
xcodegen generate
open PhoneBox.xcodeproj
```

Pick your team under **Signing & Capabilities** (and set `PHONEBOX_BUNDLE_ID` in `project.yml` to your own ID), connect
the iPhone and press Run. A free Apple ID works; the app then has
to be reinstalled every 7 days. The app runs on iOS 15 and later (iPhone 6s and newer, iPad 5th generation and newer).

CI (`.github/workflows/ios.yml`) builds it for the simulator and uploads an unsigned `.ipa` that can be signed and
sideloaded (AltStore, Sideloadly, …).

## Install it as an app

iOS installs only apps signed by Apple, so there are three ways to get PhoneBox onto an iPhone:

**TestFlight (recommended; needs a paid Apple Developer account, $99/year).** The app then installs and updates like
any App Store app, through Apple's TestFlight app, and it never expires.

1. In [App Store Connect](https://appstoreconnect.apple.com) › Apps, create a new app with your own bundle ID, e.g.
   `com.yourname.phonebox` (register it, and `com.yourname.phonebox.control` for the Control Center control, under
   Certificates, Identifiers & Profiles if it isn't offered).
2. Users and Access › Integrations › App Store Connect API: create a key with the **Admin** role (Xcode creates the signing certificate and profiles with it; your existing
   certificate is not needed) and download it.
3. In this GitHub repository, Settings › Secrets and variables › Actions, add `APPLE_TEAM_ID`, `IOS_BUNDLE_ID`,
   `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the .p8 file, base64-encoded: `base64 -i AuthKey_XXXX.p8`).
4. Start a build: push a tag such as `ios-v1` (`git tag ios-v1 && git push origin ios-v1`), or, once this is merged
   into main, Actions › **ios-release** › Run workflow. Every build gets the next number by itself.
5. After Apple has processed it (a few minutes), add yourself as a tester in App Store Connect › TestFlight and install
   PhoneBox from the TestFlight app on the iPhone.

**Your own signing certificate (.p12 + .mobileprovision, e.g. from a certificate service).** Every build is published
as a pre-release, with fixed links:

- `https://github.com/<owner>/<repo>/releases/download/ios-latest/PhoneBox-unsigned.ipa`
- `https://github.com/<owner>/<repo>/releases/download/ios-latest/PhoneBox-unsigned-noext.ipa` (without the iOS 18
  Control Center control, for signers or profiles that can't sign app extensions)

Import the link into your signer app (ESign, Feather, Scarlet, your certificate provider's signer), sign it with your
certificate and install. The app asks for no special entitlements, so a wildcard profile works; keep or change the
bundle ID as you like. If the certificate is revoked, the app stops opening until you sign it again with a new one.

**Sideloading with a free Apple ID.** Download `phonebox-ios-unsigned` from the latest **ios** run in Actions and
install the `.ipa` with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io). Apps signed with a free
Apple ID stop opening after 7 days and must be re-installed (AltStore does that by itself).

**Xcode.** Build it yourself as described above and run it on the connected iPhone.

## Connect it to the computer

### USB (like the Android app)

Plug the iPhone into the computer, tap **Trust** on the phone when asked, and open PhoneBox. That's all: the agent finds
the phone and connects within a few seconds, and the status line shows **USB**. While on USB the app also fetches the
Wi-Fi pairing by itself, exactly like the Android app, so it carries on over Wi-Fi when unplugged.

Android does this with `adb reverse`; iOS has no adb, so the agent uses Apple's **usbmuxd** instead (`IosUsb.cs` on the
agent, `UsbTunnel.swift` in the app). The computer needs Apple's device support:

| Computer | What to install |
|---|---|
| macOS | Nothing, it is built in. |
| Windows | The **Apple Devices** app (Microsoft Store) or iTunes. |
| Linux | The `usbmuxd` package (`sudo apt install usbmuxd`, `sudo dnf install usbmuxd`, …). |

### Wi-Fi / Tailscale with the QR code

1. On the computer, open PhoneBox settings › **Wi-Fi** and turn on Wi-Fi access.
2. Choose **Pair a phone over Wi-Fi**. A QR code appears.
3. Scan it with the iPhone's Camera app. The pairing page opens in Safari; tap **Open in PhoneBox**.
4. Check that the code in the app matches the one on the computer and tap **Pair**.
5. Allow **Local Network** access when iOS asks: without it the app cannot reach the computer over Wi-Fi.

The phone keeps the agent's certificate fingerprint (pinning) and token in the Keychain. Several computers can be paired
and switched in the page overview, as on Android.

## Feature by feature

| Android app | iOS app |
|---|---|
| Panel, all widgets, templates, pages, themes, languages | The same files (`android/app/src/main/assets/www`). |
| USB with `adb reverse` | USB through usbmuxd (see above). |
| Wi-Fi / Tailscale, QR pairing, pinned certificate, several computers | The same. |
| Live stream from the agent | The same; plugging in moves it to USB at once. |
| Volume keys flip pages | The same. iOS gives apps no key events, so the app watches the volume and puts it back after each press (it moves the volume to the middle when it is at either end). |
| Back returns to the first page / opens the overview | Swipe in from the left edge (iOS's back gesture). |
| Room light sensor: auto brightness, night screen when dark | The front camera's exposure meter, converted to lux. It runs only while one of those options is on; iOS shows its camera indicator then. Nothing is recorded. |
| Proximity: a wave wakes the night screen | iOS proximity monitoring, on only while the night screen or idle dim is showing (iOS turns the screen off while the hand is near, then the panel wakes). |
| Brightness | The same. iPhone brightness is system-wide, so yours is restored whenever the panel leaves the screen. |
| Haptics and notification vibration patterns | Core Haptics. |
| Dictation widget | Apple's speech recognizer; "on the phone only" uses on-device recognition. |
| Screen pinning | Guided Access. On a supervised iPhone the app starts it itself; otherwise triple-click the side button once. |
| Quick Settings tile | Control Center control (iOS 18): Control Center › Add a Control › PhoneBox. |
| Keep the screen on, full screen, landscape / portrait / auto | The same. |
| Weather for the place set on the computer | The weather where the iPhone is (approximate location, like the Weather app's "My Location"; the computer's place is the fallback, and Settings › Weather can turn it off). |
| Time zone, 12/24-hour, language and date formats from the phone | The same (12/24-hour follows the phone when the clock setting is "Follow the phone", the default for new settings). |
| Battery level and charging | The same; iOS reports no battery temperature or charger type. |
| Use as the home screen (starts after a reboot) | iOS lets no app replace the home screen. For a dedicated panel phone use Guided Access, or Single App Mode on a supervised iPhone (Apple Configurator), which also starts PhoneBox after a restart. |
| Agent opens the panel when the phone is plugged in | iOS lets no computer start an app. Leave PhoneBox open (Guided Access keeps it there). |
| App updates from the agent | Not offered (they are APKs); update from Xcode / your sideloading tool. |
