# MacScope

A local SwiftUI macOS diagnostic utility for Intel and Apple Silicon. Deployment target: macOS 12. Swift Charts is used on macOS 13+, with native SwiftUI path charts on macOS 12. No packages, database, account, server, analytics or external network requests.

## Build and run

1. On a Mac, install Xcode 15 or newer and open `MacScope.xcodeproj`.
2. Select the **MacScope** scheme and **My Mac**, then press **⌘R**.
3. If signing requires configuration, select your development team under Signing & Capabilities. The app is intentionally not sandboxed so it can read locally accessible diagnostic reports and run `/usr/sbin/system_profiler`. Hardened runtime and camera/audio entitlements are included.

Command-line build (local unsigned validation):

```sh
xcodebuild -project MacScope.xcodeproj -scheme MacScope -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

For normal camera/microphone permission testing, use a consistently signed development build from Xcode. Distribution requires appropriate signing/notarization; this repository does not provide a signed installer.

## Build a downloadable app with GitHub Actions

The workflow in `.github/workflows/build-macos.yml` runs on a macOS runner with Xcode. It runs only `MacScopeTests/DiagnosticLogicTests`, builds a universal Release binary (`arm64` and `x86_64`), checks both architectures, applies an ad-hoc signature with the media entitlements, verifies the signature, and packages the `.app` using `ditto` to preserve executable permissions.

After uploading the project to your GitHub repository, open **Actions → Build MacScope for macOS**. A source push starts it automatically; **Run workflow** is also available once the workflow is on the default branch. Download the **MacScope-macOS** artifact from a successful run, extract it, then extract the inner `MacScope-macOS.zip`. Move `MacScope.app` to Applications on your Mac. The receiving Mac does not need Xcode. Test results are uploaded separately.

This personal test build is ad-hoc signed, **not Developer ID signed or notarized**. macOS may block its first launch; after attempting to open your trusted build, use System Settings → Privacy & Security → Open Anyway if available. Do not disable Gatekeeper globally. Normal public distribution requires Developer ID signing and notarization. Camera/microphone permission prompts and physical hardware still need manual testing on the receiving Mac.

Workflow preparation does not mean an application has been built: only a successful GitHub Actions run produces the downloadable app. Runner reference: https://docs.github.com/en/actions/reference/runners/github-hosted-runners

## Focused unit tests

Tests only cover pure normalization, threshold logic, counter deltas, redaction and result serialization/defaults. No test connects to any database. The application-hosted test target may launch the app and perform its normal read-only local scan.

```sh
xcodebuild -project MacScope.xcodeproj -scheme MacScope -destination 'platform=macOS' -only-testing:MacScopeTests/DiagnosticLogicTests CODE_SIGNING_ALLOWED=NO test
```

## Features

- Five native screens: dashboard, hardware details, 12 independent Test Lab checks, diagnostic logs, report.
- CPU, estimated used memory, block-device read activity and network receive charts, sampled every two seconds and bounded to 60 samples. Write/transmit rates are also displayed. Missing counters display unavailable, not zero. macOS does not expose block-device counters on every Mac.
- Inventory from `sysctl`, `ProcessInfo`, volume resource values, IOKit power sources and a bounded `system_profiler` subprocess. Expensive reads execute off the main actor.
- Battery charge/cycle/design-capacity estimate when exposed. Capacity below 80% is warning, below 60% critical. These are app-defined capacity categories, not Apple's service diagnosis or a safety verdict. Values above design capacity are capped at 100%. Unsupported/ambiguous units do not become a health estimate.
- Startup/home volume free capacity: below 15% warning, below 5% critical. APFS volumes can share container space; this is volume availability, not physical SSD wear.
- Solid color display inspection, including full-screen patterns (click to cycle, Escape to exit). Keyboard captures key codes only while focused. Trackpad surface detects clicks, scrolls, pinch and rotation; mouse and trackpad origin cannot always be distinguished.
- Local left/right speaker tone; ten-second microphone level observation without recording; camera preview without recording; user-triggered biometric-only Touch ID verification. Interactive checks are recorded as user-confirmed, not automated hardware certification.
- Network path/interface observation with timeout. No Internet probe or speed test.
- Latest 100 accessible `.ips`, `.crash`, `.panic` and `.diag` reports from user/system DiagnosticReports directories; 64 KB detail limit, severity filters, file modification timestamps and common identifier redaction. Diagnostic reports can still contain app-specific personal information. No raw logs are exported.
- Local JSON/PDF exports with device inventory, individual results, measurement limitations and recommendations. Sensitive identifiers are excluded by design.

## Permissions

- Camera/microphone: prompted only after running the respective test. Grant in System Settings → Privacy & Security. macOS 12 uses System Preferences → Security & Privacy.
- Touch ID: requires supported hardware and an enrolled fingerprint; macOS handles verification.
- No Accessibility, Input Monitoring, administrator, network, or Full Disk Access grant is required. Keyboard events are local to the focused test area. Some system-reserved keys/gestures cannot be captured.
- Inaccessible log directories/reports are reported rather than requesting elevated access.

## Scope and unsupported diagnostics

This utility cannot execute Apple's private diagnostics, prove physical component health, measure SSD wear universally, run SMART self-tests, certify memory integrity, inspect fingerprint data, verify all keyboard keys, automatically detect dead pixels or confirm sound/image quality. It does not query protected unified logs or promise access to every panic report. Wi-Fi signal quality, throughput and Internet reachability are not tested. Success means only the named observation succeeded; no composite health score is created.

Memory is estimated as active + wired + compressor pages, rather than Activity Monitor's pressure calculation. Network totals include non-loopback interfaces and may include virtual adapters. Disk rates cover the exposed IOBlockStorageDriver instances. Counter resets invalidate one sample. Inventory is refreshed on launch/Scan Again; activity charts continue sampling while the app is open.

## Validation status

Authored in a Linux environment without Swift, macOS SDKs or Xcode. Xcode build, XCTest execution, actual device behavior, permission prompts, PDF appearance and visual layout have **not** been validated on a Mac. Static checks passed: all 11 Swift files parse without syntax errors, both property lists and the shared scheme XML parse, and all 45 Xcode project object references and Swift source paths resolve. These checks do not perform Swift type checking or substitute for compilation. Nine focused XCTest methods are included but have not been run.

Suggested Mac acceptance checks: launch in light/dark mode; resize; scan on Intel and Apple Silicon; verify graphs against Activity Monitor; run each module; deny/regrant media permissions; cancel/retry tests; test a Mac without battery/Touch ID; inspect multi-page JSON/PDF exports; confirm full-screen display test Escape exits and camera indicator turns off after dismissal.
