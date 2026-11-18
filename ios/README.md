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

iOS has no `adb reverse`, so an iPhone connects **over Wi-Fi** (or Tailscale):

1. On the computer, open PhoneBox settings › **Wi-Fi** and turn on Wi-Fi access.
2. Choose **Pair a phone over Wi-Fi**. A QR code appears.
3. Scan it with the iPhone's Camera app. The pairing page opens in Safari; tap **Open in PhoneBox**.
4. Check that the code in the app matches the one on the computer and tap **Pair**.
5. Allow **Local Network** access when iOS asks: without it the app cannot reach the computer.

The phone keeps the agent's certificate fingerprint (pinning) and token in the Keychain, exactly like the Android app
keeps them. Several computers can be paired and switched in the page overview.

## What differs from Android

The panel is the same; a few things the Android shell does are not possible, or work differently, on iOS:

| Feature | iOS |
|---|---|
| USB connection | Not available (needs `adb reverse`). Use Wi-Fi pairing. The app still tries `127.0.0.1:8765` first, so a USB tunnel run on the phone side would be used. |
| Volume keys flip pages | Yes. iOS gives apps no volume-key events, so the app watches the volume and puts it back after each press. The volume is moved to the middle when it is at either end. |
| Back button | iOS has no Back button. Use the page overview (long-press) or the swipe gestures of the panel. |
| Screen pinning | Uses Guided Access. An app can start it by itself only on a supervised device; otherwise triple-click the side button. |
| Use as the home screen | Not possible on iOS. |
| Room light sensor / proximity wake | No public API on iOS; the panel's automatic brightness and wave-to-wake are off. |
| Battery | Level and charging; iOS reports no temperature or charger type. |
| Brightness | Works. iPhone brightness is system-wide, so the app restores yours whenever it leaves the screen. |
| Dictation | Apple's speech recognizer. "On the phone only" needs a language with on-device recognition (iOS 13+). |
| Quick Settings tile | iOS has none. Add the app to the Dock instead. |
| Keep the screen on | Yes (the idle timer is disabled while the panel is in front). Keep the phone on its charger. |
| App updates from the agent | Not offered: the agent offers APK updates only to Android (the iOS app sends `X-PhoneBox-Platform: ios`). |
