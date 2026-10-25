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

## Run script in Terminal — 2026-10-24

- Moved the shared `.command` writer from `AIAgents` into `TerminalLauncher`. The AI launch test passes without changes; a new test runs a generated `.command` with a tool path and arguments that hold spaces, quotes, `$HOME` and backticks, and checks that each argument arrives unchanged.
- `dev_clean.py` now reports before it refuses: with `--apply` while Xcode, xcodebuild, Simulator or XCTRunner run, it lists everything and deletes nothing. A closed stdin answers No. A test runs it against a temporary home with `--apply` and no terminal: it lists the fake orphan folder, and the folder still exists afterwards. `--help` exits 0; a bad flag and a bad category exit non-zero.
- Tests cover the catalog-to-script mapping, the `Script:` detail line, the orphan finding's `dd-gone` script, and that the action has no command when the file or, for Python, the developer tools are missing. `/usr/bin/python3` (3.9.6) parses every bundled `.py`; `zsh -n` parses every `.sh`. 48 tests passed.
- `bash build.sh` twice: `Contents/Resources/Scripts/dev_clean.py` exists once, not nested, and `codesign --verify --strict` passes.
- Ran the bundled script on this Mac. `--only dd-gone` listed the same 6 folders as the app; `--apply --only spm` with stdin closed printed `skipped`, and the 18 GB cache stayed. The script now prints decimal GB, so its 31.7 GB matches the app (it printed 29.5 binary "GB" before).
- Clicked through the built app with Accessibility: Storage cleanup → Xcode DerivedData for deleted projects shows the `Script:` line and **Run script in Terminal** next to **Ask AI in Terminal**. The click opened Terminal, which ran `dev_clean.py --apply --only dd-gone`. An `xcodebuild` process was running, so the script printed "Report only: xcodebuild running", listed the 6 folders and ended with "Nothing was deleted". The DerivedData listing was identical before and after, and the temporary `.command` file was gone.
- The mini panel's cleanup and growth row menus now use the same `RecommendationActions` view as the menu bar submenu, so they offer every available action and Ask AI. Checked: the build, the tests, and the new footer text in the running panel. The open row menu was not captured; GUI automation was stopped because it reached other windows.
- Not covered by hand: the interactive y/N prompt with nothing busy. The closed-stdin test and the `spm` run cover the No path.

## Growth and cleanup sizes with APFS clones — 2026-10-24

- Problem seen: the panel showed `~/Library/Developer/XCTestDevices — +1001.9 GB in the last hour` (3,458,946 file changes) on a 995 GB volume with 393 GB free. `du -sh` also reported 1.0 TB for the folder's 89 simulator clones.
- Measured on this Mac with `getattrlist(ATTR_CMNEXT_PRIVATESIZE)`: `XCTestDevices` has 3.8 million files, 1,189 GB allocated and 0 GB private; `CoreSimulator/Devices` has 384,000 files, 108 GB allocated and 37 GB private. A 50 MB `cp -c` clone reports 0 private bytes, and 1 MB after a small append.
- Fixes: growth and cleanup sizes use private bytes; cleanup items name shared space of 1 GB or more; files past the 300,000-file limit no longer count one way; growth that free space cannot explain shows its change count and "the size is unclear".
- The `GrowthTracker` stream now retains the tracker. With a second tracker test, `swift test` crashed with signal 11 in 1 of 5 runs; after the change, 12 of 12 runs passed. `main` passed 6 of 6 runs before the change.
- Tests: clone sizes in a temporary folder (`copyfile` with `COPYFILE_CLONE`), a live tracker that ignores five clones and counts a new 2 MB file, symmetric counting past the file limit, and the free-space check with the 1001.9 GB case. 45 tests passed.
- Not yet checked in the running app: the panel and menu after an hour of parallel UI tests.

## Cleanup script parity and Xcode disk guide — 2026-10-25

- `dev_clean.py` has a new `xctest` category for parallel-testing simulator clones. It deletes them with `xcrun simctl --set testing delete all`, the same command as the app's cleanup row. That row now also offers the script.
- The script now measures private size with `getattrlist(ATTR_CMNEXT_PRIVATESIZE)`, as the app does, instead of `du -sk`. It names shared space of 1 GB or more, and it reports "Could free at least …".
- Measured on this Mac: the Python walk gave the same DerivedData numbers as the app's Swift code, 27.4 GB private and 36.9 GB shared. One worktree's DerivedData folder showed 13.1 GB with `du`, and 3.2 GB private with 9.9 GB shared.
- A full walk of 129 test clones (about 8 million files) took 185 s; `du -sk` took 113 s. A threaded walk was slower. So each item stops after 30 s and is marked "measured for 30 s only". The run showed 0 MB private and 252.3 GB shared; `du` showed 1.7 TB for the folder on a 926 GB volume.
- A dry run of `--days 7 --only dd-gone,dd-stale,dd-orphan,sims,xctest` took 38 s and reported at least 25.5 GB.
- Tests: an 8 MB `cp -c` clone inside a DerivedData folder reports 0 MB; a fake `XCTestDevices` clone reports 2 MB and still exists after `--apply` without a terminal; the catalog row maps to `--only xctest`. 52 tests passed and `swiftlint lint --strict` reported nothing.
- `docs/xcode-disk-usage.md`: the `xcodebuild` options were checked against `xcodebuild -help` of Xcode 26.5, the `simctl` commands against `xcrun simctl help`, and the Tart commands against `tart prune --help`.
- Not covered: `--apply --only xctest` with a terminal against real clones, and **Run script in Terminal** on the new row in the running app.
