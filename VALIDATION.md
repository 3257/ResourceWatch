# Local validation — 2026-10-20

## Requirements and evidence

| Requirement | Evidence |
| --- | --- |
| Lightweight background macOS monitor | Native menu bar app, serial utility sampler every 10 seconds; no network requests, subprocess polling or directory walks. Running app inspected via Accessibility. Initial running build sampled at 0.0% CPU and about 94 MiB RSS; later with Settings open, 0.9% CPU and about 113 MiB RSS. Point samples, not a long-term benchmark. |
| Sustained CPU alerts, including a busy tool on an otherwise idle Mac | Alert-engine tests cover all-machine versus independent process thresholds; native live test measures a disposable one-core child for 0.4 seconds. Caught and fixed Mach tick conversion. |
| Memory information and alerts | Live host VM metrics: RAM estimate, physical RAM, wired/compressed, swap, pressure; native resident process sizes. Synthetic tests cover process memory and pressure, and verify old swap alone is quiet. |
| Storage capacity and growth alerts | Synthetic low-space and rolling-growth tests, including expiry. Live sampler reads the home volume. No writes or recursive scans used to create pressure. |
| Network information and alerts | Native 64-bit Wi-Fi/Ethernet counters; rate/total/reset/reconnect tests and sustained-traffic test. Live test checks interfaces are enumerated after short routing-address records. No load generated on the network. |
| Compact menu similar to WindowBar | Native menu style, short summary rows, RAM/network/process/alert submenus. Accessibility inspection confirmed native menu items and submenu content. Settings is a separate window. |
| Threshold sliders | Nine native sliders enumerated in the running Settings window. CPU AXIncrement changed 85 to 90; AXDecrement restored 85. Numeric labels visible through Accessibility. |
| Saved settings | Isolated UserDefaults tests cover round-trip and migration from earlier settings missing new fields. |
| Notifications actually work | User approved notification permission. Sent test through the running app; Settings confirmed **Test delivered to Notification Center**, based on the delivered request identifier. This does not override Focus or prove every future banner will be visible. |
| Optional login startup | Uses SMAppService.mainApp register/unregister and reads OS status. Toggle present in Settings. Left off; an actual logout/login was not performed. |

The initial Swift Testing suite passed with 13 tests, including live native metrics and CPU scaling. The release build and live slider interaction passed. `git diff --check` passed. The initial packaged app was about 476 KiB on disk (excluding SwiftPM's ignored build cache); the dashboard adds code to later builds.

## Limits

Home volume only; physical `en*` network interfaces only; no folder/network-process attribution. RAM used is estimated and RSS differs from Activity Monitor footprint. Protected processes may be absent. Alerts and network/storage history are bounded in memory and reset when the app exits. Login startup is optional, and monitoring requires the app to run. No automatic process termination or file deletion. No sustained stress test or reboot test performed.

## Icon and mini panel follow-up

- Pulse menu icon, warning triangle for current threshold violations or sampling errors; recovery and condition coverage verified by tests. Visual state uses current samples; notification duration still applies separately.
- Optional CPU/RAM menu text is saved in Settings. Regression test verifies this presentation toggle does not reset alert timing.
- Live panel captured by its own window ID and visually inspected. Four equal-height metric tiles, native material, CPU history and a pin control; uses the existing sampler.
- Actual CPU, Memory, Network and Storage tile actions exercised through Accessibility; each corresponding detail heading appeared. Details collapsed afterward.
- Pin action verified against Core Graphics window layer: floating 3 → normal 0 → floating 3. Restored pinned.
- Fifteen tests passed; release build passed. Panel close is independent of the app's monitor owner.

## Inline warning summaries

- Added a top-level Current warnings section with CPU readings/thresholds, process names and usage, memory pressure, storage free space, network rates and the distinct rapid-storage-growth reason. Warning rows open the mini panel.
- Regression test verifies displayed readings and culprit names for simultaneous conditions and removal after recovery. Sixteen tests and the release build passed.
- Launched the standalone updated app and inspected its native menu. CPU had recovered to 10.4%, and the warning section was correctly absent; active-condition text was verified by the regression test without generating system pressure.

## Pulse status dot

- Kept the pulse glyph in normal and warning states, adding a red dot during warnings or collection errors. Recovery removes the dot. The same icon width is reserved in both states.
- Full-color non-template rendering preserves the badge color. Appearance is read in the menu bar label view.
- Pixel regression checks verify an opaque red badge during warnings and a transparent badge area otherwise, in both light and dark variants. Seventeen tests and the release build passed; updated app launched locally.

## App and notification icon — 2026-10-21

- Added original vector pulse/status-dot artwork on a blue rounded tile. AppKit generates the PNG preview and native iconset; `iconutil` creates the ICNS during every app build.
- Verified ICNS header/length and standard/Retina representations, the bundle's CFBundleIconFile resource, and strict code-signature validation. Packaging version is 0.1.1 (build 2).
- Refreshed only this app's Launch Services registration and restarted the rebuilt app. NSWorkspace resolved the new artwork instead of a generic app icon; its rendered result was visually inspected.
- Sent a test through Settings; the running app confirmed delivery to Notification Center. OS icon resolution and delivery were verified separately; no personal notification content was captured or published.

### Notification placeholder follow-up

The user subsequently confirmed the notification still showed a placeholder, so the ICNS/Finder and delivery checks above did **not** prove correct notification rendering. Removing the stale old-app registration and restarting Notification Center also did not resolve the reported issue.

Added a compiled AppIcon asset catalog, declared CFBundleIconName alongside CFBundleIconFile, and bumped the bundle to 0.1.2 (build 3). Verified 11 named AppIcon renditions in Assets.car, the asset compiler's metadata, strict signing and all 17 tests. Reloaded the per-user notification services without deleting preferences/history, launched the new build and sent a distinctly titled **ResourceWatch test — 0.1.2**. Visual confirmation of that new notification is pending; this remains an unconfirmed fix.
