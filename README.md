<div align="center">

# claude-keepwarm

**Stop waiting out your 5-hour window.**

Claude Code's usage window only starts when *you* do — so idle hours buy you
nothing. `keepwarm` keeps windows rolling around the clock, using a few hundred
tokens from the subscription you already pay for.

[![CI](https://github.com/mamuncseru/claude-keepwarm/actions/workflows/ci.yml/badge.svg)](https://github.com/mamuncseru/claude-keepwarm/actions/workflows/ci.yml)
[![docs](https://github.com/mamuncseru/claude-keepwarm/actions/workflows/docs.yml/badge.svg)](https://mamuncseru.github.io/claude-keepwarm/)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platforms](https://img.shields.io/badge/macOS%20·%20Linux%20·%20Windows-supported-informational)

[**Documentation**](https://mamuncseru.github.io/claude-keepwarm/) ·
[Install](https://mamuncseru.github.io/claude-keepwarm/install/) ·
[How it works](https://mamuncseru.github.io/claude-keepwarm/how-it-works/)

</div>

---

## The problem

Your window starts at the **top of the hour containing your first message** and
lasts five hours. It does not tick while you're away.

<img src="docs/assets/problem.svg" alt="Timeline showing seven idle hours during which no usage window runs, a window opening at 09:00 when the first message is sent, quota exhausted by 10:00, and four hours blocked with no access." width="100%">

You were away for seven hours and still had to wait four more. Those idle hours
bought you nothing, because a window only starts when *you* start.

## The fix

`keepwarm` sends one tiny prompt just after each window expires, so windows tile
back to back whether you're at the keyboard or not.

<img src="docs/assets/solution.svg" alt="The same timeline with keepwarm running: windows tile continuously at 04:00, 09:00 and 14:00, opened by small keepalive pings. Work starting at 08:30 uses the tail of the running window and then a fresh full-quota window at 09:00, with no blocked period." width="100%">

You do **not** get more quota per window. You get **more windows per day** — up
to the plan's natural ceiling of 24 ÷ 5 ≈ 4.8 — regardless of when you sit down.

## Install

Needs a logged-in [Claude Code](https://claude.com/claude-code) CLI.

**macOS / Linux** — requires bash 3.2+ and `cron`:

```sh
git clone https://github.com/mamuncseru/claude-keepwarm.git
cd claude-keepwarm

./keepwarm install     # hourly cron job
./keepwarm ping        # open the first window — sets your boundary phase
./keepwarm doctor      # confirm it's actually running
```

**Windows** — requires PowerShell 5.1 (ships with Windows) or 7:

```powershell
git clone https://github.com/mamuncseru/claude-keepwarm.git
cd claude-keepwarm

.\keepwarm.ps1 install    # hourly scheduled task
.\keepwarm.ps1 ping       # open the first window
.\keepwarm.ps1 doctor     # confirm it's actually running
```

> **Use the native Windows port, not WSL.** WSL2 shuts its VM down once your
> last shell exits, so `cron` inside WSL won't fire overnight — exactly when the
> keepalive matters.

Both run **hourly** but only call Claude when the window has actually expired,
so a missed run self-corrects instead of drifting out of phase.

## Is it running?

You never have to wait for a ping to find out — every hourly tick writes a log
line even when nothing is due, so the log doubles as a heartbeat.

```
$ ./keepwarm doctor

  [ok]   claude binary          /home/you/.local/bin/claude
  [ok]   cron job               installed (fires at :02 every hour)
  [ok]   cron daemon            running
  [ok]   last tick              0h 08m ago — cron is firing
  [ok]   window tracked         2026-08-02 13:00 -> 2026-08-02 18:00

  next cron tick   2026-08-02 17:02 (in 0h 47m)
  that tick will   log a WAIT line and exit (no API call)
  first ping tick  2026-08-02 18:02 (in 1h 47m)

  5 ok, 0 warning(s), 0 failing
```

`doctor` exits non-zero when something's wrong, so it works as a health probe.
In the log, `WAIT` means the tick ran and correctly spent nothing; `OK` means a
window opened, and `AUTH` means your Claude Code login expired — sign in again
with `claude` and `/login`.

## Cost

**It doesn't cost anything extra.** Pings draw from the usage your Claude
subscription already includes - the same allowance your normal Claude Code
sessions use. There's no separate bill, no card to add, nothing to enable.

One ping, measured over three runs:

```
input 167 (stable)  +  output 72-106  =  240-270 tokens
```

At ~5 pings a day that's roughly **1,200 tokens** - a rounding error against any
plan's allowance. For scale only: if you were paying pay-as-you-go API rates,
those tokens would come to about a third of a cent a day, near $1 a year. On a
subscription you pay none of that.

It stays this small because the ping replaces Claude Code's ~15k-token default
system prompt, sends no tool schemas, and disables CLAUDE.md, skills, plugins,
hooks and MCP. A plain `claude -p hi` uses roughly 60x more.

> **The one exception:** if you've pointed Claude Code at an `ANTHROPIC_API_KEY`
> or enabled pay-as-you-go extra usage, those tokens are billed the usual way -
> still around a third of a cent a day.

## Commands

| Command | What it does |
| --- | --- |
| `keepwarm install` | Install the hourly cron job / scheduled task |
| `keepwarm ping` | Open a window now — also **re-phases** your boundaries |
| `keepwarm doctor` | Health check: binary, schedule, daemon, heartbeat, window |
| `keepwarm status` | Current window, next ping, recent log |
| `keepwarm log [n]` | Last n log lines |
| `keepwarm uninstall` | Remove the schedule |

On Windows, use `.\keepwarm.ps1` in place of `./keepwarm`. Full command,
configuration and troubleshooting reference is
[in the docs](https://mamuncseru.github.io/claude-keepwarm/reference/).

## Limitations

**Boundaries rotate.** 24 isn't divisible by 5, so boundaries at
07:00/12:00/17:00/22:00 today become 03:00/08:00/13:00/18:00/23:00 tomorrow.
Inherent to a five-hour window; re-phase any time with `keepwarm ping` at the
top of an hour you want a boundary on.

**The hour-anchoring model is inferred, not documented.** It matches observed
behaviour, but if Anthropic anchors differently, pings will occasionally land
early — which shows up as a `LIMITED` line and a retry, not as breakage. Raise
`SLACK_MINUTES` if you see those repeatedly.

## Development

```sh
./tests/run.sh          # 21 tests — no network, no API calls, no real crontab
shellcheck -s bash keepwarm tests/run.sh
```

```powershell
.\tests\run.ps1         # 16 tests, same coverage on the Windows port
```

CI covers GNU vs BSD `date` (Linux + macOS), bash 3.2, Windows PowerShell 5.1
and 7, a real Task Scheduler round trip, half-hour timezones, and lint on both
ports.

## A note on responsible use

An unofficial community tool, not affiliated with Anthropic. It uses your own
subscription within your plan's existing limits — it doesn't raise them, bypass
them, or share credentials, and it reads no secrets. It does generate automated
background usage on your account, so make sure that's consistent with your
plan's terms.

## License

MIT — see [LICENSE](LICENSE).
