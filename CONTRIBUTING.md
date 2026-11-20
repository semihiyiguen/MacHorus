# Contributing

Thanks for your interest in MacHorus! Bug reports, measurements from other Macs and pull requests are welcome.

## Reporting bugs

Open an issue with:

- your Mac model, chip and macOS version,
- what you expected and what you saw (a screenshot helps),
- the output of `/Applications/MacHorus.app/Contents/MacOS/MacHorus --print-diagnosis`. It contains no serial number, computer name, addresses or app names.

## Building

Requirements: macOS 14.2 or later and the Command Line Tools (`xcode-select --install`). Xcode is not needed.

```bash
make build      # debug build
make test       # unit tests
make check      # lint, build, tests, Thread and Address Sanitizer
make run        # build build/MacHorus.app and open it
```

`make app` signs ad-hoc. Run `scripts/setup-signing.sh` once to create a local signing identity, so macOS keeps granted permissions across rebuilds. Run `scripts/install-hooks.sh` once to enable the pre-commit hook.

## Pull requests

- `make check` must pass with **zero warnings**.
- Format with `make format`; `make lint` must be clean.
- UI text: English is the source (`Resources/en.lproj`), every key also needs a German translation (`Resources/de.lproj`); `make lint` checks both.
- No new network access, no telemetry, no new permissions without discussion in an issue first.
- New measurements must be verified against a macOS tool and stay within the resource budget (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- Keep the SPDX header in every source file. By contributing you agree that your contribution is licensed under GPL-3.0-or-later.
