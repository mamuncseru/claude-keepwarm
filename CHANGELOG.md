# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/spec/v2.0.0.html).

## [1.2.2] — 2026-08-02

### Fixed
- **An expired Claude Code login was retried three times over 40 seconds and
  its one-line cause was buried in a 1200-character payload.** Reported from a
  real Windows install. Authentication failures are now their own status:
  never retried (an expired session does not become valid by waiting), logged
  as a readable `AUTH` line, and surfaced by `ping` with the fix to run.
  `doctor` reports it as a failing check until the next successful ping.
  `ping` exits `3` for this case.
- `ping` and the error log now surface the CLI's own `result` message instead
  of making you read raw JSON to find out what happened.
- **Corrected an inaccurate cost claim.** The README and site said "about a
  twentieth of a cent a day"; the real figure at API rates is ~0.25-0.35 cents
  (5-7x higher). Fixed everywhere.

### Changed
- Cost is now stated as what it is: **no extra charge**. Pings draw from the
  usage a Claude subscription already includes, and any dollar figure is
  labelled as the equivalent API value shown for scale. The one exception -
  an `ANTHROPIC_API_KEY` or pay-as-you-go extra usage - is called out
  explicitly, because readers were reasonably assuming a separate bill.
- Docs site defaults to **light mode** for everyone instead of following the
  visitor's OS setting, and the theme switch now shows "Night mode" / "Day
  mode" as text rather than a bare icon.

### Added
- A release workflow: pushing a `v*` tag re-runs the Linux, macOS and Windows
  suites and only then publishes a GitHub release, with notes taken from this
  changelog. A release that publishes regardless of test results is just a tag
  with extra steps.

## [1.2.1] — 2026-08-02

### Fixed
- **Windows PowerShell 5.1 could not parse `keepwarm.ps1` at all.** 5.1 decodes
  a BOM-less `.ps1` as ANSI (CP1252), not UTF-8. There, an em-dash's trailing
  byte (`0x94`) becomes U+201D — a smart double-quote, which PowerShell's
  tokenizer treats as a string delimiter. One em-dash inside a single-quoted
  string desynced the parser and cascaded into seven errors. Both PowerShell
  files are now ASCII-only *and* carry a UTF-8 BOM, and CI fails on any
  non-ASCII byte so the class of bug cannot return silently.
- **The PowerShell 7 CI job was secretly testing 5.1.** `tests/run.ps1`
  hardcoded the Windows PowerShell path when spawning the script under test, so
  the pwsh job exercised the wrong interpreter. It now uses the host it is
  running under.
- **`keepwarm.ps1` crashed at load on any non-Windows host.** `$env:USERPROFILE`
  is null off Windows and `Join-Path` throws on a null `-Path`. Added a
  `$UserHome` fallback and made the binary-search globs conditional.
- `Get-ScheduledTask` / `Get-Service` are now probed with `Get-Command` before
  use — `-ErrorAction SilentlyContinue` does not suppress a *missing cmdlet*,
  which throws under `$ErrorActionPreference = 'Stop'`. `status` and `doctor`
  consequently work on macOS and Linux too.
- `install` registers the task against the PowerShell that ran it, so
  installing from pwsh 7 no longer silently schedules 5.1.
- CI: `Invoke-ScriptAnalyzer -Path` takes a string, not an array — passing both
  files at once failed the lint job outright.
- CI: shellcheck exits non-zero on SC1091; the sourced runtime state file is
  now explicitly exempted.

### Changed
- `tests/run.ps1` now runs on macOS and Linux as well as Windows: the stub is
  emitted as a shell script off Windows and a `.cmd` on it. This is what made
  the port testable outside CI.

## [1.2.0] — 2026-08-02

### Added
- **Windows support** via a native PowerShell port (`keepwarm.ps1`) using Task
  Scheduler instead of cron. Same commands, same `config.env`, same state file
  format, so moving between WSL and native Windows keeps your window. The task
  is registered with `StartWhenAvailable`, the Windows analogue of the
  self-correcting hourly tick: a run missed during sleep fires on wake rather
  than waiting a full hour.
- Windows test suite (`tests/run.ps1`), plus CI jobs for Windows PowerShell 5.1
  and PowerShell 7, PSScriptAnalyzer, and a real Task Scheduler
  install/uninstall smoke test.

### Changed
- The ping now passes `--tools=` instead of `--tools ""`. PowerShell 5.1
  silently drops empty-string arguments to native executables, so the quoted
  form would have broken the Windows port. Verified equivalent on Unix.

## [1.1.0] — 2026-08-02

First public release.

### Added
- `keepwarm doctor` — health check covering the binary, cron entry, cron
  daemon, log heartbeat and tracked window. Exits non-zero on failure, so it
  works as a probe. Answers "is it running?" without waiting for a ping.
- In-process retry for transient ping failures (`PING_ATTEMPTS`,
  `PING_RETRY_DELAY`). Previously a single local blip cost a full hour of
  window, because the next attempt was the next hourly tick.
- `KEEPWARM_*` environment overrides for every setting, which is what makes the
  script testable in isolation.
- Test suite (`tests/run.sh`): 18 tests, no network, no API calls, no real
  crontab — a PATH shim supplies a stub `claude` and a fake `crontab`.
- CI on Linux and macOS, under macOS's bash 3.2, and across half-hour
  timezones.
- `keepwarm version`.

### Changed
- Portable across macOS and Linux. All date handling goes through a GNU/BSD
  compatibility layer; replaced `flock` with an atomic `mkdir` lock that
  reclaims locks whose owner died, and replaced `find -newermt`/`-quit` (both
  GNU-only) with a `touch -t` reference file.
- Log errors up to 1200 chars instead of 500 — the old limit truncated the
  `result` field that explains the failure.
- `config.env` is now gitignored; ship `config.env.example` instead, so local
  settings survive a `git pull`.

### Fixed
- `set -o pipefail` combined with `grep -q` could turn a **successful** match
  into a non-zero pipeline status: `grep -q` exits at the first match and
  SIGPIPEs its upstream writer. This silently broke the cron-daemon check and
  could have suppressed rate-limit detection. All such checks now use
  here-strings instead of pipes.
- `doctor` reported the wrong "first ping tick": GNU `date` parsed a trailing
  `+1 hour` as a timezone offset. Replaced with epoch arithmetic.
- Flooring to the top of the hour now round-trips through a formatted string
  rather than `epoch % 3600`, which was wrong in half-hour timezones such as
  `Asia/Kolkata` and `Asia/Kathmandu`.

[1.2.2]: https://github.com/mamuncseru/claude-keepwarm/releases/tag/v1.2.2
[1.2.1]: https://github.com/mamuncseru/claude-keepwarm/releases/tag/v1.2.1
[1.2.0]: https://github.com/mamuncseru/claude-keepwarm/releases/tag/v1.2.0
[1.1.0]: https://github.com/mamuncseru/claude-keepwarm/releases/tag/v1.1.0
