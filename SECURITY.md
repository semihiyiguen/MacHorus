# Security Policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. You will get an answer as soon as possible; please allow reasonable time for a fix before disclosing details.

## Design for safety

MacHorus is built to be safe to run on any Mac:

- **No administrator rights.** MacHorus never asks for them and has no privileged helper.
- **Nothing is sent.** No account, no analytics, no crash reporting, no update check. The only network access is the network check, started by the user (see [docs/PRIVACY.md](docs/PRIVACY.md)).
- **Minimal permissions,** asked by macOS only when a feature first needs them; every feature can be switched off. Full Disk Access, Accessibility and Screen Recording are never requested.
- **Read-only private APIs** behind adapters with capability checks and public fallbacks; administrators can switch each one off. The SMC is only read, never written.
- **Clipboard history stays in memory** and is gone when MacHorus quits.
- **Quitting processes** is limited to your own processes and always asks first.
- The code is checked with strict concurrency, Thread and Address Sanitizer, and a pre-commit hook that scans for secrets.

You can verify all of this in the source: the network code is in `Sources/MacHorusTools/NetworkCheck.swift`, the permissions in `Sources/MacHorusCore/Features/FeatureModule.swift`, and private APIs in `Sources/MacHorusMonitor/PrivateAPI/`.
