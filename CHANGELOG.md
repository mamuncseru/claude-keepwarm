# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-08-02

First release. Verified by hand on macOS, Linux and Windows.

### Added

- **`keepwarm`** — a single bash script that keeps Claude Code's 5-hour usage
  window rolling, so idle hours are converted into windows instead of being
  lost. Sends one ~240-token keepalive just after each window expires.
- **`keepwarm.ps1`** — a native Windows port using Task Scheduler in place of
  cron, with the same command surface, the same `config.env`, and the same
  state file format, so moving between WSL and native Windows keeps your
  window. Registered with `StartWhenAvailable`, so a run missed during sleep
  fires on wake rather than waiting a full hour.
- **`doctor`** — a health check covering the binary, the schedule, the daemon,
  a log heartbeat, the tracked window, and authentication. Exits non-zero on
  failure, so it works as a probe. Every hourly tick logs a line even when it
  does nothing, which is what lets liveness be confirmed without spending a
  ping.
- Hourly scheduling that only calls Claude when the window has actually
  expired, so a missed run self-corrects instead of drifting out of phase.
- Redundant pings are skipped when your own messages already opened the
  window; rate limits leave state untouched and retry next tick; transient
  local failures retry in-process; expired logins are never retried and report
  how to fix themselves.
- Test suites for both ports (21 bash, 16 PowerShell) using a stubbed CLI and
  a fake `crontab` — no network, no API calls, and your real schedule is never
  touched.
- CI across Linux, macOS, bash 3.2, Windows PowerShell 5.1 and 7, a real Task
  Scheduler round trip, half-hour timezones, shellcheck and PSScriptAnalyzer.
- A documentation site with figures explaining the problem and the mechanism.

### Notes

The tool costs nothing beyond the Claude subscription you already have — pings
draw from the usage your plan includes. See the README for the one exception
(an `ANTHROPIC_API_KEY`, or pay-as-you-go extra usage).

Nothing was published before this tag. The intermediate version numbers that
appeared during development were never released; that history is in the git
log, where it belongs.

[1.0.0]: https://github.com/mamuncseru/claude-keepwarm/releases/tag/v1.0.0
