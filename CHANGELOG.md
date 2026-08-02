# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/spec/v2.0.0.html).

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

[1.1.0]: https://github.com/mamuncseru/claude-keepwarm/releases/tag/v1.1.0
