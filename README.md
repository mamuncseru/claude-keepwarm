# claude-keepwarm

Keep Claude Code's 5-hour usage window rolling, so idle time burns windows
instead of your working time burning them.

[![CI](https://github.com/mamuncseru/claude-keepwarm/actions/workflows/ci.yml/badge.svg)](https://github.com/mamuncseru/claude-keepwarm/actions/workflows/ci.yml)

---

## The problem

Your usage window starts at the **top of the hour containing your first
message** and lasts 5 hours. It does not tick while you're away.

```
Idle 02:00 → 09:00.  First message at 09:00.
  window   09:00 ────────────────────────── 14:00
  quota exhausted by 10:00
  blocked  10:00 ──────────── 14:00     ← 4 hours lost, after 7 idle hours
```

You were away for seven hours and still had to wait four more. Those idle hours
bought you nothing, because a window only starts when *you* start.

## What it does

`keepwarm` sends one tiny prompt just after each window expires, so windows tile
back-to-back around the clock:

```
… 04:00──09:00 │ 09:00──14:00 │ 14:00──19:00 …
      ↑ opened while you slept, for ~$0.0005
```

Start work at 08:30 and the current window ends at 09:00: you get that window's
full quota, then a **fresh** window at 09:00 — two windows in thirty minutes.
Without keepwarm your 08:30 message would have opened one window at 08:00 and
you'd wait until 13:00 for the next.

**You do not get more quota per window. You get more windows per day** — up to
the plan's natural ceiling of 24/5 ≈ 4.8 — regardless of when you sit down.

## Install

Requires bash 3.2+, `cron`, and a logged-in [Claude Code](https://claude.com/claude-code) CLI.

```sh
git clone https://github.com/mamuncseru/claude-keepwarm.git
cd claude-keepwarm

./keepwarm install     # hourly cron job
./keepwarm ping        # open the first window (this sets your boundary phase)
./keepwarm doctor      # confirm it's actually running
```

The cron job runs **hourly** but only calls Claude when the window has actually
expired. That makes it self-correcting: if the machine sleeps or cron misses a
run, the next tick catches up instead of drifting out of phase.

To remove it: `./keepwarm uninstall`.

## Is it running?

```sh
./keepwarm doctor
```

```
  [ok]   claude binary          /home/you/.local/bin/claude
  [ok]   cron job               installed (fires at :02 every hour)
  [ok]   cron daemon            running
  [ok]   last tick              0h 08m ago — cron is firing
  [ok]   window tracked         2026-08-02 13:00 EDT -> 2026-08-02 18:00 EDT

  next cron tick   2026-08-02 17:02 EDT (in 0h 47m)
  that tick will   log a WAIT line and exit (no API call)
  first ping tick  2026-08-02 18:02 EDT (in 1h 47m)

  5 ok, 0 warning(s), 0 failing
```

You never have to wait for a ping to know it's alive. **Every hourly tick writes
a log line even when nothing is due**, so the log doubles as a heartbeat — the
`last tick` check is what proves cron is executing the script. `doctor` exits
non-zero if anything fails, so it works as a health probe too.

In the log: `WAIT` means cron ran and correctly decided not to spend a ping.
`OK` means a window was opened.

## Commands

| Command | What it does |
| --- | --- |
| `keepwarm install` | Install the hourly cron job |
| `keepwarm ping` | Open a window now — also **re-phases** your boundaries |
| `keepwarm doctor` | Health check: cron, daemon, heartbeat, window |
| `keepwarm status` | Current window, next ping, recent log |
| `keepwarm run` | Ping only if the window expired (what cron calls) |
| `keepwarm ping --dry-run` | Print the exact command without calling Claude |
| `keepwarm log [n]` | Last n log lines |
| `keepwarm config` | Resolved settings and paths |
| `keepwarm uninstall` | Remove the cron job |

## Cost

One ping, measured:

```
input 167 + output 71 = 238 tokens   ($0.0005)
```

At ~5 pings/day that's ~1,200 tokens/day. It stays that small because the ping
runs with `--system-prompt` (replacing Claude Code's ~15k-token default),
`--tools ""` (no tool schemas) and `--safe-mode` (no CLAUDE.md, skills, plugins,
hooks or MCP). A plain `claude -p hi` costs roughly 60× more.

## Configuration

```sh
cp config.env.example config.env
```

Everything is commented out by default. The most useful knobs:

| Setting | Default | Notes |
| --- | --- | --- |
| `MODEL` | `haiku` | The window is account-wide, so the cheapest model opens it just as well |
| `SLACK_MINUTES` | `2` | Delay past the boundary before pinging. Raise to 5 if you see `LIMITED` in the log |
| `CRON_MINUTE` | `2` | Minute of the hour the job fires on |
| `SKIP_IF_RECENTLY_ACTIVE` | `1` | Don't spend a ping if your own messages already opened the window |
| `PING_ATTEMPTS` | `3` | In-process retries for transient failures |
| `CLAUDE_BIN` | auto | Pin the binary explicitly if auto-detection picks the wrong one |

Any setting can also be overridden per-invocation with a `KEEPWARM_` prefix:
`KEEPWARM_MODEL=sonnet ./keepwarm ping`.

## How it works

The window model it assumes is `window_end = floor_to_hour(first_message) + 5h`.
State lives in `state/window.env`; each hourly tick compares now against
`window_end + SLACK_MINUTES` and does nothing unless it's past.

Three behaviours worth knowing:

**It skips redundant pings.** If you were using Claude Code yourself after the
boundary, your own messages already opened the new window. keepwarm detects that
from transcript mtimes under `~/.claude/projects` and records the window without
spending a ping.

**It self-corrects.** If a ping comes back rate-limited, the old window hadn't
really expired — keepwarm logs it, leaves the recorded window alone, and retries
next hour rather than drifting. Transient local failures are retried in-process
so one blip doesn't cost a full hour of window.

**It finds the CLI even when it isn't on `PATH`.** The VS Code and Cursor
extensions bundle their own `claude` binary in a version-numbered directory;
keepwarm globs for the newest one so an extension update doesn't break the cron
job.

## Limitations

**Boundaries rotate.** 24 isn't divisible by 5, so boundaries at
07:00/12:00/17:00/22:00 today become 03:00/08:00/13:00/18:00/23:00 tomorrow.
This is inherent to a 5-hour window. Re-phase whenever you like by running
`keepwarm ping` at the top of an hour you want a boundary on.

**The hour-anchoring model is inferred, not documented.** It matches observed
behaviour, but if Anthropic anchors differently, pings will occasionally land
early — which shows up as a `LIMITED` line and a retry, not as breakage. Raise
`SLACK_MINUTES` if you see those repeatedly.

**Windows-native isn't supported.** Use WSL, where it works normally.

## Development

```sh
./tests/run.sh          # 18 tests, no network, no API calls, no real crontab
./tests/run.sh lock     # filter by name
shellcheck -s bash keepwarm tests/run.sh
```

Tests run in a throwaway sandbox with a PATH shim providing a stub `claude` and
a fake `crontab`, so `install`/`uninstall` are exercised without touching your
real one. CI runs them on Linux and macOS, under macOS's bash 3.2, and across
half-hour timezones (`Asia/Kolkata`, `Asia/Kathmandu`) that break any
implementation flooring to the hour with `epoch % 3600`.

## A note on responsible use

This is an unofficial community tool with no affiliation to Anthropic. It uses
your own subscription within your plan's existing limits — it doesn't raise
them, bypass them, or share credentials. It reads no secrets; authentication is
whatever the Claude Code CLI already has.

That said, it does generate automated background usage on your account. You're
responsible for making sure that's consistent with the terms of your plan.

## License

MIT — see [LICENSE](LICENSE).
