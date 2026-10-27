# How ResourceWatch works

This page holds the full detail on alerts, suggestions, storage cleanup, growth tracking and the menu. The [README](../README.md) has the short version.

The pulse icon stays in place and gains a small red status dot when current metrics exceed configured thresholds or sampling fails; the dot disappears after recovery. The icon reserves the same space in both states, and adapts to light/dark appearance. Visual warnings appear on the current sample, while notifications wait for the configured sustained duration. In Settings, **Show CPU and RAM in menu bar** adds compact live percentages beside the icon (off by default).

When a warning is active, **Current warnings** appears at the top of the menu with the reason, current readings and responsible process names where available. For example: `CPU 90% — above 85%` or `FixtureCompiler: 500% CPU (one core = 100%)`. Storage growth is distinguished from low free space. Click a warning to open the mini panel; recovered warnings disappear from this section while past notifications remain under **Recent alerts**.

## Suggestions and storage cleanup

**Suggestions** appears below the warnings and states what to do. ResourceWatch groups helper processes under their app, so a warning names the app and not one helper. For example: `Google Chrome: 11.2 GiB memory footprint in 34 processes`. Each suggestion opens a submenu with the largest process, a tip and one or more actions:

- **Bring app to front**, **Open Activity Monitor**, **Show in Finder**.
- **Move to Trash…**: offered only for folders that their tools recreate, such as DerivedData, DeviceSupport and package-manager caches, and for orphaned DerivedData folders. A dialog names every item first, and **Cancel** is the default button. Archives, simulators, worktrees, backups, Downloads and growing folders are never offered; they need their own tool or your own choice. In the mini panel, the menu of each cleanup item and each growing folder offers the same actions as the menu bar, including **Run script in Terminal** and **Ask AI in Terminal**.
- **Copy command**: copies a cleanup command, such as `xcrun simctl delete unavailable` or `git -C … worktree remove …`, to the clipboard. You paste it into Terminal and run it yourself.
- **Run script in Terminal**: opens your default terminal app and runs a bundled cleanup script for that suggestion. Today this covers Xcode DerivedData, DerivedData of deleted projects, simulator devices and runtimes, parallel-testing simulator clones, DeviceSupport and the Swift Package Manager cache, through `dev_clean.py`. The script reports private sizes, so APFS clones do not count twice. The action appears only when the Xcode developer tools are installed (`xcode-select -p`).

Every bundled script, in `CleanupScripts/`, follows the same contract:

1. It lists what it found and its size before it asks anything.
2. It asks y/N before each group of changes, and No is the default. There is no flag that skips the question.
3. It changes nothing while the related app runs, such as Xcode or Simulator, and it says why.
4. It changes only what it listed in the same run. It checks again every path that ResourceWatch gives it.
5. It reads no secrets, makes no network calls and needs no administrator access.
6. It has `--help`, and it exits with a non-zero code on bad input.

Without a terminal, every answer is No. ResourceWatch itself still deletes nothing.

[Keep Xcode's disk use under control](xcode-disk-usage.md) explains where Xcode uses space, how to run `dev_clean.py` without the app, and how to keep the space from growing again.

**Ask AI in Terminal** (menu) or **Ask AI** (mini panel) sends a suggestion to an AI coding CLI. ResourceWatch detects Claude Code (`claude`), Codex (`codex`), OpenCode (`opencode --prompt`) and Gemini CLI (`gemini -i`) through your login shell's `PATH` at launch, and lists only the installed ones. The app opens a `.command` file with your default terminal app. The agent starts an interactive session in your login shell, with the suggestion, your Mac's memory and storage readings, and a rule to ask before it deletes files or stops processes. Worktree suggestions start in the worktree folder; other suggestions start in your home folder. The terminal opens a new window, or a new tab when **System Settings → Desktop & Dock → Prefer tabs when opening documents** is **Always**. No Automation or Accessibility permission is needed.

ResourceWatch never quits apps, never empties the Trash, and moves files to the Trash only after you confirm. App totals sum the kernel-charged process memory footprints (`proc_pid_rusage`, `ri_phys_footprint`), avoiding the repeated shared clean pages in summed resident sizes. Footprints include compressed or swapped memory at its original size, so they are not a share of physical RAM and are not directly comparable with the dashboard's system RAM used. Suggestions never present them as a RAM percentage. Check memory pressure and swap to judge system health. macOS does not tell other apps which browser tab owns a process; for Chromium browsers the tip points to the browser's Task Manager (Shift+Esc).

The **Storage cleanup** submenu lists items of 1 GB or more, largest first:

- Known developer and cache folders: Xcode DerivedData, Archives and DeviceSupport, simulator devices, Swift Package Manager, Homebrew, CocoaPods, npm and Gradle caches, the Trash, device backups, and Downloads items unchanged for 30 days.
- Virtual machine disks of Tart, Parallels Desktop and OrbStack. A VM disk image grows as the guest writes, so free space can drop while no other file changes. When free space drops quickly and ResourceWatch has not found a growing folder in your home folder, the alert points to local snapshots, swap and files outside your home folder.
- Xcode DerivedData folders whose project no longer exists.
- Git worktrees in your project folders whose branch is merged into the default branch, or that have no git activity for 14 days. A worktree's size includes its Xcode DerivedData folders.

Set the project folders in **Settings… → Project folders**; the defaults are `~/WorkProjects` and `~/PlayProjects`. ResourceWatch reads git's worktree records directly and runs `git` only during a scan, to find merged branches.

**Growing now** names the folders that grew in the last hour. ResourceWatch watches file changes in your home folder with FSEvents, records the private size of each changed file (the blocks that no APFS clone shares), and adds the growth up for each folder. It drills down to the folder that holds most of the growth; below the top levels it reports the common parent instead of splitting into several deep folders, for example `~/Library/Developer/Xcode/DerivedData/App-abc/Build/Products` instead of `~/Library`. When the storage-growth warning is active, these folders lead **Suggestions**, and the growth notification names the fastest-growing folder. The rules:

- A new file counts in full. The first change to a file that already existed only sets a baseline, so a large disk image that grows a little does not count in full. Deleted files, and files moved out of a folder, subtract their known size; files moved in count in full, so a move inside your home folder balances out.
- An APFS clone, such as a simulator that Xcode clones for parallel tests, shares its blocks with its source. It counts only the blocks it changes later, not its full size.
- ResourceWatch remembers the size of up to 300,000 files. A new file past that limit is not counted, because its deletion could not be subtracted later; the folder then notes that some changes were not measured.
- If a folder's growth is larger than free space can explain (more than twice the drop in free space plus what other folders freed, plus 1 GB), the folder shows its number of file changes and "the size is unclear" instead of a size.
- Only folders that grew by 200 MB or more in the last hour are listed. Paths and sizes stay in memory for one hour and are never written to disk or sent anywhere. File contents are never read.
- Desktop, Documents, Downloads, iCloud Drive, app containers and the Photos library are protected by macOS. ResourceWatch never reads file sizes there, so no permission prompt appears; it counts their file changes only, and lists a protected folder with 2,000 or more changes in the last hour. Downloads is measured after the first **Scan now**.
- Growth outside your home folder, such as swap files, system updates and APFS snapshots, is not included. Monitoring starts when the app launches.

A scan runs at launch, again after 24 hours, and at most once an hour while a low-storage or storage-growth warning is active. **Scan now** starts one at any time. Scans run at background priority, outside the ten-second sampler, and stop measuring a folder after 20 seconds (the size then shows as "at least"). Sizes count only blocks that no APFS clone shares, so deleting a folder frees at least the size shown. A folder with 1 GB or more of shared blocks names that amount: deleting the folder frees it only when the copies are gone too. Folders that macOS protects, such as Downloads, are scanned only after the first **Scan now**, so macOS asks for access when you expect it. Folders that need Full Disk Access are skipped. Low-storage and growth notifications name the largest cleanup item, and process notifications add the app tip.

Choose **Show mini panel** for a small floating dashboard with CPU, memory, network and storage tiles plus up to ten minutes of CPU history. Click a tile for details and click it again to collapse. The pin button toggles staying above other windows. Closing the panel leaves monitoring running. This is a live app panel, not a macOS WidgetKit desktop widget, and shares the existing ten-second sampler.

Samples every ten seconds, off the UI thread:

- All-core CPU above 85% for 60 seconds.
- Individual process above 150% CPU (one and a half cores) for 60 seconds, even if overall CPU is low.
- Individual process above 8 GiB memory footprint for 60 seconds.
- macOS warning/critical memory pressure for 30 seconds. Swap is displayed separately; swap alone does not imply a problem.
- Home volume below 20 GB free or 10% free for 30 seconds.
- More than 10 GB lost over a rolling hour, after at least five minutes of observation.
- Upload or download above 25 MB/s for 60 seconds (adjustable). This indicates sustained traffic, not a claim the connection is saturated.

Alerts repeat every 15 minutes while a condition persists. Recovery resets the sustained window. The menu retains the latest 30 alerts in memory. Disk history resets on restart and measures free-space change; **Growing now** attributes growth to folders. The sampler never scans folders; only storage cleanup scans measure folder sizes. APFS shared capacity and snapshots can affect free space.

Top processes show PID, executable name, CPU since the previous sample and memory footprint. CPU counters use the machine's Mach timebase; 100% means one core. Processes whose task information or footprint cannot be read are omitted; resident sizes are never substituted for footprints. Command arguments and environments are never collected. Sampling uses native APIs on a serial utility queue, with no subprocess per tick.

The compact native menu shows CPU, memory pressure, swap and storage. While a menu is open, its values stay fixed so submenus do not close under the pointer; the latest readings appear when it closes, and notifications are never delayed. **Top processes** and **Recent alerts** expand into submenus. Open **Settings…** to adjust thresholds, CPU/process duration and cooldown with sliders; selected values remain visible beside their labels. **Launch at login** is a separate toggle. Preferences persist locally. Memory pressure and low space use a fixed 30-second window. Login startup is opt-in through Apple's Service Management API; the toggle reads the OS state. Keep the app at a stable path before enabling it. macOS may require approval in Login Items settings. Quitting stops monitoring until the next launch.

The **RAM** submenu adds estimated used/physical memory, compressed/wired memory and the five largest resident processes. The estimate uses resident internal pages minus purgeable pages, plus wired and compressor pages. Pressure remains the basis of system-memory alerts: a large cache or old swap does not necessarily mean trouble.

The **Network** submenu shows download/upload rates and totals since launch, measured from 64-bit Wi-Fi/Ethernet (`en*`) interface counters. Local transfers are included. VPN tunnel/bridge/loopback counters are excluded to avoid counting tunneled traffic twice; this is not a universal internet-usage meter, and other interface types are not included. No packet inspection, destination collection, connectivity probes, or per-process network attribution. New/reconnected interfaces establish a baseline; counter resets do not create traffic spikes. Totals reset when the app quits.

Use **Send test notification** to verify permission and banner delivery. A successful submission is not proof a banner appeared: Focus and OS presentation settings still apply. The app requests foreground banner/list/sound presentation too.
