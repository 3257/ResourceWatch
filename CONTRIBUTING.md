# Contributing

Open an issue before a large change, so we can agree on the approach.

## Set up

You need macOS 14 or later and full Xcode 16 or later.

```bash
swift test
bash build.sh
git diff --check
```

CI runs SwiftLint in strict mode, the tests and the app build. Run `swiftlint lint --strict` locally if you have it installed.

## Rules

- Keep the app free of network calls, telemetry, administrator access and automatic file deletion.
- A cleanup script must follow the contract in the [README](README.md): list first, ask y/N per group, change nothing while the related app runs.
- Add a test for each behaviour change. Tests live in `Tests/ResourceWatchTests`.
- Match the style of the surrounding code. Comment only what the code cannot say.
- Screenshots show only app windows, without desktop content or personal data.

## Pull requests

Keep one change per pull request. Describe what changed and why, and say how you tested it.
