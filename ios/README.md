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

Pick your team under **Signing & Capabilities**, connect the iPhone and press Run. A free Apple ID works; the app then has
to be reinstalled every 7 days. The app runs on iOS 15 and later (iPhone 6s and newer, iPad 5th generation and newer).

CI (`.github/workflows/ios.yml`) builds it for the simulator and uploads an unsigned `.ipa` that can be signed and
sideloaded (AltStore, Sideloadly, …).

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
| Battery level and charging | The same; iOS reports no battery temperature or charger type. |
| Use as the home screen (starts after a reboot) | iOS lets no app replace the home screen. For a dedicated panel phone use Guided Access, or Single App Mode on a supervised iPhone (Apple Configurator), which also starts PhoneBox after a restart. |
| Agent opens the panel when the phone is plugged in | iOS lets no computer start an app. Leave PhoneBox open (Guided Access keeps it there). |
| App updates from the agent | Not offered (they are APKs); update from Xcode / your sideloading tool. |
