#!/usr/bin/env -S python3 -I
"""Find (and optionally remove) stale Xcode, simulator and SwiftPM data.

Default is a dry run: it only reports. Nothing is deleted without --apply, and
--apply still asks y/N for each category. While Xcode, xcodebuild, Simulator or
XCTRunner run, --apply only reports. Without a terminal, every answer is No.

Categories:
  dd-gone     DerivedData whose project no longer exists (info.plist WorkspacePath)
  dd-stale    DerivedData not opened for --days (info.plist LastAccessedDate)
  dd-orphan   DerivedData without info.plist, not modified for --days
  sims        Simulator devices that are unavailable, or not booted for --days
  runtimes    Simulator runtimes that no device uses
  devsupport  iOS/watchOS DeviceSupport entries not modified for --days
  spm         SwiftPM download cache (packages download again on next resolve)
  xctest      Parallel testing simulator clones (Xcode makes new ones for each run)

Shared DerivedData caches (*.noindex) are never touched.

Sizes count only blocks that no APFS clone shares, so deleting an item frees at
least that much. Simulator test clones and DerivedData packages are mostly
clones; plain du counts each clone in full. Measuring one item stops after
30 seconds, and its size is then a minimum.

Usage:
  dev_clean.py                     # report everything, --days 30
  dev_clean.py --days 14
  dev_clean.py --only dd-gone,sims
  dev_clean.py --apply --only dd-gone
"""
import argparse
import ctypes
import datetime as dt
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DERIVED = f"{HOME}/Library/Developer/Xcode/DerivedData"
DEVSUPPORT = [f"{HOME}/Library/Developer/Xcode/{p} DeviceSupport" for p in ("iOS", "watchOS", "tvOS", "visionOS")]
SPM_CACHE = f"{HOME}/Library/Caches/org.swift.swiftpm"
XCTEST = f"{HOME}/Library/Developer/XCTestDevices"
CATEGORIES = ["dd-gone", "dd-stale", "dd-orphan", "sims", "runtimes", "devsupport", "spm", "xctest"]
TIME_LIMIT = 30


class AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16), ("commonattr", ctypes.c_uint32),
                ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                ("forkattr", ctypes.c_uint32)]


LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.getattrlist.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
# ATTR_BIT_MAP_COUNT, forkattr ATTR_CMNEXT_PRIVATESIZE; options FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW.
PRIVATE_SIZE_REQUEST = AttrList(5, 0, 0, 0, 0, 0, 0x8)
PRIVATE_SIZE_OPTIONS = 0x20 | 0x1


def private_size(path):
    """Bytes of a file that no clone shares, or None where the volume does not report it (not APFS)."""
    buffer = ctypes.create_string_buffer(16)
    if LIBC.getattrlist(os.fsencode(path), ctypes.byref(PRIVATE_SIZE_REQUEST), buffer, len(buffer), PRIVATE_SIZE_OPTIONS) != 0:
        return None
    # The kernel packs the reply at 4-byte alignment: a UInt32 length, then the off_t.
    return int.from_bytes(buffer.raw[4:12], "little", signed=True)


def size_of(*paths):
    """Private and clone-shared bytes in KB, and whether the walk finished within TIME_LIMIT."""
    own = shared = count = 0
    deadline = time.monotonic() + TIME_LIMIT
    stack = [p for p in paths if os.path.lexists(p)]
    while stack:
        path = stack.pop()
        try:
            st = os.lstat(path)
        except OSError:
            continue
        allocated = st.st_blocks * 512
        own_bytes = private_size(path) if stat.S_ISREG(st.st_mode) else None
        own_bytes = allocated if own_bytes is None else own_bytes
        own += own_bytes
        shared += allocated - own_bytes
        if stat.S_ISDIR(st.st_mode):
            try:
                stack.extend(os.path.join(path, name) for name in os.listdir(path))
            except OSError:
                pass
        count += 1
        if count % 2000 == 0 and time.monotonic() > deadline:
            return {"kb": own // 1024, "shared_kb": shared // 1024, "complete": False}
    return {"kb": own // 1024, "shared_kb": shared // 1024, "complete": True}


def human(kb):
    # Decimal units, the same as ResourceWatch and Finder.
    gb = kb * 1024 / 1e9
    return f"{gb:.1f} GB" if gb >= 1 else f"{kb * 1024 / 1e6:.0f} MB"


def age_days(when):
    return (dt.datetime.now(dt.timezone.utc) - when).days


def mtime_utc(path):
    return dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc)


def simctl_json(*args):
    out = subprocess.run(["xcrun", "simctl", *args, "-j"], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def running(*names):
    return [n for n in names if subprocess.run(["pgrep", "-x", n], capture_output=True).returncode == 0]


# Each finder returns a list of items: {"label", "kb", "remove": callable}.

def derived_data(days):
    gone, stale, orphan = [], [], []
    if not os.path.isdir(DERIVED):
        return gone, stale, orphan
    for name in sorted(os.listdir(DERIVED)):
        path = os.path.join(DERIVED, name)
        if name.endswith(".noindex") or os.path.islink(path) or not os.path.isdir(path):
            continue
        plist = os.path.join(path, "info.plist")
        item = {"path": path, "remove": lambda p=path: shutil.rmtree(p)}
        if os.path.isfile(plist):
            with open(plist, "rb") as f:
                info = plistlib.load(f)
            workspace = info.get("WorkspacePath", "")
            last = info.get("LastAccessedDate")
            if workspace and not os.path.exists(workspace):
                gone.append({**item, "label": f"{name}  (was {workspace})"})
            elif last and age_days(last.replace(tzinfo=dt.timezone.utc)) >= days:
                stale.append({**item, "label": f"{name}  ({age_days(last.replace(tzinfo=dt.timezone.utc))} days, {workspace})"})
        elif age_days(mtime_utc(path)) >= days:
            orphan.append({**item, "label": f"{name}  (no info.plist, {age_days(mtime_utc(path))} days)"})
    for item in gone + stale + orphan:
        item.update(size_of(item["path"]))
    return gone, stale, orphan


def simulators(days):
    items, used_runtimes = [], set()
    for runtime, devices in simctl_json("list", "devices")["devices"].items():
        for d in devices:
            used_runtimes.add(runtime)
            booted_at = d.get("lastBootedAt")
            if d["state"] != "Shutdown":
                continue
            if not d.get("isAvailable", True):
                why = "unavailable"
            elif booted_at is None:
                # No boot date: judge by when the device was created, so new devices stay.
                device_dir = os.path.dirname(d["dataPath"])
                created = dt.datetime.fromtimestamp(os.stat(device_dir).st_birthtime, dt.timezone.utc)
                if age_days(created) < days:
                    continue
                why = f"never booted, created {age_days(created)} days ago"
            else:
                age = age_days(dt.datetime.fromisoformat(booted_at.replace("Z", "+00:00")))
                if age < days:
                    continue
                why = f"last booted {age} days ago"
            short_rt = runtime.rsplit(".", 1)[-1]
            items.append({
                "label": f"{d['name']} {short_rt}  {d['udid']}  ({why})",
                **size_of(d["dataPath"], d.get("logPath", "")),
                "remove": lambda u=d["udid"]: subprocess.run(["xcrun", "simctl", "delete", u], check=True),
                "runtime": runtime,
            })
    return items, used_runtimes


def runtimes(used_runtimes):
    items = []
    for r in simctl_json("runtime", "list").values():
        if r.get("runtimeIdentifier") in used_runtimes or not r.get("deletable", False):
            continue
        items.append({
            "label": f"{r['runtimeIdentifier'].rsplit('.', 1)[-1]} {r.get('version', '')}  {r['identifier']}  (no devices use it)",
            "kb": r.get("sizeBytes", 0) // 1024,
            "remove": lambda i=r["identifier"]: subprocess.run(["xcrun", "simctl", "runtime", "delete", i], check=True),
        })
    return items


def device_support(days):
    items = []
    for root in DEVSUPPORT:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isdir(path) or age_days(mtime_utc(path)) < days:
                continue
            items.append({
                "label": f"{os.path.basename(root)}/{name}  ({age_days(mtime_utc(path))} days)",
                **size_of(path),
                "remove": lambda p=path: shutil.rmtree(p),
            })
    return items


def spm_cache():
    if not os.path.isdir(SPM_CACHE):
        return []

    def clear():
        for name in os.listdir(SPM_CACHE):
            p = os.path.join(SPM_CACHE, name)
            shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)

    return [{"label": f"{SPM_CACHE}/*  (whole cache)", **size_of(SPM_CACHE), "remove": clear}]


def test_clones():
    if not os.path.isdir(XCTEST):
        return []
    clones = [n for n in os.listdir(XCTEST) if os.path.isdir(os.path.join(XCTEST, n)) and not os.path.islink(os.path.join(XCTEST, n))]
    if not clones:
        return []

    def remove():
        # "delete all" also takes clones made after the listing, so refuse if a test run started during the prompt.
        busy = running("xcodebuild", "XCTRunner")
        if busy:
            raise RuntimeError(f"{', '.join(busy)} started; nothing was deleted")
        # simctl also removes the clones from its device set, which deleting the folders would leave behind.
        subprocess.run(["xcrun", "simctl", "--set", "testing", "delete", "all"], check=True)

    return [{"label": f"{len(clones)} clone(s) in {XCTEST}", **size_of(XCTEST), "remove": remove}]


def confirm(question):
    try:
        return input(question).strip().lower() == "y"
    except EOFError:
        print()
        return False


def report_and_apply(category, title, items, apply):
    total = sum(i["kb"] for i in items)
    print(f"\n== {category}: {title} — {len(items)} item(s), {human(total)}")
    for i in sorted(items, key=lambda i: -i["kb"]):
        notes = ""
        if i.get("shared_kb", 0) * 1024 >= 1e9:
            notes += f"  [another {human(i['shared_kb'])} is shared with clones]"
        if not i.get("complete", True):
            notes += f"  [measured for {TIME_LIMIT} s only]"
        print(f"   {human(i['kb']):>8}  {i['label']}{notes}")
    if not apply or not items:
        return total
    if not confirm(f"   Delete these {len(items)} item(s), {human(total)}? [y/N] "):
        print("   skipped")
        return 0
    freed = 0
    for i in items:
        try:
            i["remove"]()
            freed += i["kb"]
        except Exception as e:  # keep going; report the failure
            print(f"   FAILED {i['label']}: {e}")
    print(f"   freed at least {human(freed)}")
    return freed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=30, help="age threshold in days (default 30)")
    ap.add_argument("--only", default=",".join(CATEGORIES), help="comma-separated categories")
    ap.add_argument("--apply", action="store_true", help="delete, after a y/N prompt per category")
    args = ap.parse_args()
    only = set(args.only.split(","))
    unknown = only - set(CATEGORIES)
    if unknown:
        sys.exit(f"unknown categories: {', '.join(sorted(unknown))}")

    busy = running("Xcode", "xcodebuild", "Simulator", "XCTRunner")
    refused = args.apply and busy
    if refused:
        # Report anyway: the list is useful even when nothing can be deleted now.
        print(f"Report only: {', '.join(busy)} running. Quit them first, then run this again to delete.")
        args.apply = False
    print(f"{'APPLY' if args.apply else 'DRY RUN'}  threshold {args.days} days")

    freed = 0
    if only & {"dd-gone", "dd-stale", "dd-orphan"}:
        gone, stale, orphan = derived_data(args.days)
        if "dd-gone" in only:
            freed += report_and_apply("dd-gone", "DerivedData for deleted projects", gone, args.apply)
        if "dd-stale" in only:
            freed += report_and_apply("dd-stale", f"DerivedData not opened for {args.days}+ days", stale, args.apply)
        if "dd-orphan" in only:
            freed += report_and_apply("dd-orphan", f"DerivedData without info.plist, {args.days}+ days old", orphan, args.apply)
    if only & {"sims", "runtimes"}:
        sims, used = simulators(args.days)
        if "sims" in only:
            freed += report_and_apply("sims", f"Simulator devices unused for {args.days}+ days", sims, args.apply)
        if "runtimes" in only:
            # Re-read after deleting devices, so a runtime freed by "sims" shows up.
            if args.apply and "sims" in only:
                _, used = simulators(args.days)
            freed += report_and_apply("runtimes", "Simulator runtimes no device uses", runtimes(used), args.apply)
    if "devsupport" in only:
        freed += report_and_apply("devsupport", f"DeviceSupport not modified for {args.days}+ days", device_support(args.days), args.apply)
    if "spm" in only:
        freed += report_and_apply("spm", "SwiftPM download cache", spm_cache(), args.apply)
    if "xctest" in only:
        freed += report_and_apply("xctest", "Parallel testing simulator clones", test_clones(), args.apply)

    print(f"\n{'Freed' if args.apply else 'Could free'} at least {human(freed)}.")
    if refused:
        print(f"Nothing was deleted, because {', '.join(busy)} running.")
    elif not args.apply:
        print("Nothing was deleted. Re-run with --apply (and --only <category>) to delete.")


if __name__ == "__main__":
    main()
