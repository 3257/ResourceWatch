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

Shared DerivedData caches (*.noindex) are never touched.

Usage:
  dev_clean.py                     # report everything, --days 30
  dev_clean.py --days 14
  dev_clean.py --only dd-gone,sims
  dev_clean.py --apply --only dd-gone
"""
import argparse
import datetime as dt
import json
import os
import plistlib
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
DERIVED = f"{HOME}/Library/Developer/Xcode/DerivedData"
DEVSUPPORT = [f"{HOME}/Library/Developer/Xcode/{p} DeviceSupport" for p in ("iOS", "watchOS", "tvOS", "visionOS")]
SPM_CACHE = f"{HOME}/Library/Caches/org.swift.swiftpm"
CATEGORIES = ["dd-gone", "dd-stale", "dd-orphan", "sims", "runtimes", "devsupport", "spm"]


def du_kb(path):
    out = subprocess.run(["du", "-sk", path], capture_output=True, text=True).stdout
    return int(out.split()[0]) if out else 0


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
        item["kb"] = du_kb(item["path"])
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
                "kb": (d.get("dataPathSize", 0) + d.get("logPathSize", 0)) // 1024,
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
                "kb": du_kb(path),
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

    return [{"label": f"{SPM_CACHE}/*  (whole cache)", "kb": du_kb(SPM_CACHE), "remove": clear}]


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
        print(f"   {human(i['kb']):>8}  {i['label']}")
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
    print(f"   freed about {human(freed)}")
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

    print(f"\n{'Freed' if args.apply else 'Could free'} about {human(freed)}.")
    if refused:
        print(f"Nothing was deleted, because {', '.join(busy)} running.")
    elif not args.apply:
        print("Nothing was deleted. Re-run with --apply (and --only <category>) to delete.")


if __name__ == "__main__":
    main()
