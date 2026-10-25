# Keep Xcode's disk use under control

Xcode, its simulators and Swift Package Manager can use 100 GB or more on a busy Mac. Most of that space is cache that Xcode can make again. This guide shows where the space goes, how to measure it correctly, how to clean it up and how to keep it from growing again.

The commands work without ResourceWatch. ResourceWatch runs the same checks automatically and offers the cleanup script from its **Storage cleanup** menu.

## Where the space goes

| Folder | What Xcode keeps there | Safe to delete | Grows when |
|---|---|---|---|
| `~/Library/Developer/Xcode/DerivedData` | Build products, indexes, logs and package checkouts, one folder for each project checkout | Yes. The next build takes longer. | You build, or open a new clone or worktree |
| `~/Library/Developer/CoreSimulator/Devices` | Apps, data and caches of each simulator | Delete simulators that you do not use | You install apps and run simulators |
| `~/Library/Developer/XCTestDevices` | Simulator clones for parallel testing | Yes, when no tests run | You run tests in parallel |
| `/Library/Developer/CoreSimulator` | Simulator runtimes, about 8 GB for each iOS version | Delete runtimes that no simulator uses | You install Xcode updates |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | Debug symbols for each OS version of a connected device | Yes, for OS versions that you no longer debug | You connect a device with a new OS |
| `~/Library/Caches/org.swift.swiftpm` | Downloaded package repositories | Yes. The next package resolve is slow. | You add or update packages |
| `~/Library/Developer/Xcode/Archives` | One archive for each exported or uploaded build | Keep archives of shipped builds for their crash-report symbols | You archive |

## Measure private size, not `du`

APFS clones share disk blocks. Xcode makes clones for parallel-testing simulators and for package checkouts in DerivedData. `du`, Finder and most disk tools count each clone at its full size.

For example, on one Mac `du` reported 1.7 TB for about 130 test clones, on a disk of 1 TB. The clones had less than 1 GB of private data.

The correct number is the private size: the blocks that no clone shares. macOS returns it through `getattrlist` with `ATTR_CMNEXT_PRIVATESIZE`. Deleting a folder frees at least its private size. Blocks that only the deleted clones share are freed too, so the real amount can be higher.

`dev_clean.py` and ResourceWatch both report the private size, and they also show the shared size when it is 1 GB or more:

```text
== xctest: Parallel testing simulator clones — 1 item(s), 0 MB
       0 MB  129 clone(s) in ~/Library/Developer/XCTestDevices  [another 252.3 GB is shared with clones]  [measured for 30 s only]
```

A walk over millions of files is slow, so the script stops measuring one item after 30 seconds. The size is then a minimum.

## Clean up

[`CleanupScripts/dev_clean.py`](../CleanupScripts/dev_clean.py) uses only the Python standard library. It does a dry run by default:

```bash
python3 CleanupScripts/dev_clean.py              # report everything not used for 30 days
python3 CleanupScripts/dev_clean.py --days 7
python3 CleanupScripts/dev_clean.py --apply --only dd-gone,sims
```

| Category | What it finds |
|---|---|
| `dd-gone` | DerivedData of projects that no longer exist, such as removed worktrees |
| `dd-stale` | DerivedData of projects not opened for `--days` |
| `dd-orphan` | DerivedData without `info.plist`, not changed for `--days` |
| `sims` | Simulators that are unavailable, or not booted for `--days` |
| `runtimes` | Simulator runtimes that no simulator uses |
| `devsupport` | DeviceSupport folders not changed for `--days` |
| `spm` | The whole Swift Package Manager cache |
| `xctest` | All parallel-testing simulator clones |

With `--apply`, the script asks y/N before it deletes each category. It deletes nothing while Xcode, `xcodebuild`, Simulator or a test runner runs.

To do the same steps by hand:

```bash
xcrun simctl delete unavailable           # simulators whose runtime is gone
xcrun simctl --set testing delete all     # parallel-testing clones
xcrun simctl runtime list                 # then: xcrun simctl runtime delete <identifier>
```

## Prevent the growth

1. **Keep few worktrees and clones of large projects.** Each checkout gets its own DerivedData folder, with its own copy of every package. For a project with many packages, that copy can be more than 10 GB, most of it package git history. Reuse a free worktree before you add one. When you remove a worktree, run `dev_clean.py --only dd-gone`.
2. **Share package checkouts in command-line builds.** Pass `-clonedSourcePackagesDirPath <folder>` to `xcodebuild`, with the same folder for each checkout. Then all checkouts use one package copy. Do this only for checkouts that use the same package versions, and do not build two of them at the same time. The Xcode app has no equivalent setting.
3. **Limit parallel test workers.** Pass `-maximum-parallel-testing-workers 4` to `xcodebuild test`. Each worker uses one simulator clone. Delete the clones after large test runs.
4. **Erase simulators instead of making new ones.** `xcrun simctl erase <udid>` resets a simulator and frees its data. Delete simulators that you made for one task.
5. **Delete DeviceSupport for old OS versions** after you update your devices.

## Growth that no folder explains

Sometimes free space drops faster than any folder grows. Look for these causes outside Xcode:

- **Virtual machine disk images.** Tools such as Tart, UTM and Parallels can clone a VM from a base image. At first the clone uses almost no space. Each write in the guest then adds space on the Mac, and folder totals do not show it. For Tart, `tart list` shows the VMs, `tart delete <name>` removes one, and `tart prune --entries caches --older-than 7` removes old base images.
- **Local snapshots.** `tmutil listlocalsnapshots /` lists Time Machine and macOS update snapshots. A staged macOS update keeps its snapshot until you install the update.
- **Swap.** `sysctl vm.swapusage` shows the swap in use. macOS writes swap files to `/System/Volumes/VM` when memory is full.

When free space drops quickly and ResourceWatch has not found a growing folder in your home folder, its growth alert points to these causes.
