# Security policy

## Report a vulnerability

Do not open a public issue for a security problem. Use [private vulnerability reporting](https://github.com/3257/ResourceWatch/security/advisories/new) on GitHub. Include the version, the macOS version and the steps to reproduce.

You get a first answer within 7 days. Fixes ship in a new release, and the release notes credit you if you want.

## Scope

ResourceWatch reads process names, resident sizes and file metadata. It moves files to the Trash only after a confirmation. Its bundled scripts in `CleanupScripts/` ask before each change. These reports are in scope:

- A path that makes the app or a script change or delete files that the user did not confirm.
- A way to run a command that the user did not review.
- Any network call, telemetry or credential access. The app must make none.

Release downloads are ad-hoc signed and not notarized. See the [README](README.md) for the first-launch steps.
