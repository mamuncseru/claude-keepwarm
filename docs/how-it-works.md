# How it works

## The window model

keepwarm assumes:

```
window_end = floor_to_hour(first_message) + 5h
```

A first message at 09:37 puts you in a window that started at **09:00** and ends
at **14:00** — so starting mid-hour quietly costs you the part of the hour you
already spent. That's the model the tool encodes, and the reason `ping` is worth
running at the top of an hour.

## Why more windows, not more quota

This is the part worth being precise about, because it's easy to over-claim.

keepwarm does **not** raise your per-window quota. What it changes is *how many
windows exist in a day*. A five-hour window means a ceiling of 24 ÷ 5 ≈ 4.8
windows per day — but you only collect one when a window actually opens, and a
window only opens when a message is sent.

Without keepwarm, you collect windows only while you're awake and working. Every
idle stretch is a window that never existed. With keepwarm, the idle stretch
opens and expires a window on its own, so by the time you sit down you're either
inside a fresh one or minutes away from the next.

<figure class="kw-figure" markdown>
![The same timeline with keepwarm running: windows tile continuously at 04:00, 09:00 and 14:00, opened by small keepalive pings, with work starting at 08:30 and never blocked.](assets/solution.svg)
<figcaption>Windows tile whether or not you're at the keyboard.</figcaption>
</figure>

The worst case is that you start work just after a boundary and get a full fresh
window. The best case is that you start just before one and get the tail of the
running window *plus* a full fresh one. Neither case involves waiting.

## The hourly tick

The scheduled job runs **every hour**, not every five. Each tick compares now
against `window_end + SLACK_MINUTES` and exits immediately if it isn't past.

That's deliberate. A rigid five-hourly schedule drifts: the moment one run is
late, missed, or lands early, every subsequent run is out of phase with the real
boundary, and there's no mechanism to recover. An hourly tick with a recorded
window is self-correcting — a missed run just means the next tick notices the
window is overdue and acts.

It's also what makes liveness observable. Every tick logs a line even when it
does nothing, so the log is a heartbeat and `doctor` can tell you the schedule is
alive without spending a ping.

## What each tick decides

| Situation | What happens | Cost |
| --- | --- | --- |
| Window still live | Log `WAIT`, exit | none |
| Window expired | Ping, open a new window, log `OK` | ~240 tokens |
| You were active after the boundary | Log `SKIP`, record the window | none |
| Ping came back rate-limited | Log `LIMITED`, leave state alone, retry next tick | one ping |
| Transient local failure | Retry in-process, then give up until next tick | up to 3 pings |

### It skips redundant pings

If you were using Claude Code yourself after the boundary, your own messages
already opened the new window. keepwarm notices — it stamps a reference file at
the boundary time and looks for newer transcripts under `~/.claude/projects` —
and records the window without spending anything.

### It self-corrects

A `LIMITED` result means the old window hadn't really expired, so the recorded
state is left untouched and the next tick tries again. This is why a wrong guess
about the boundary degrades into a retry rather than a drift.

Transient local failures are different: those are retried *within* the same run,
because otherwise a single blip costs a full hour of window. This isn't
hypothetical — it's why the retry exists. During development a ping failed with
zero API duration and zero tokens (it never reached the network), recovered an
hour later, and cost an hour of window in the process.

## Costs

**Nothing extra.** Pings come out of the usage your Claude subscription already
includes - the same allowance your interactive sessions use. There is no
separate bill.

One ping, measured over three runs with the exact command that ships:

```
input 167 (stable)  +  output 72-106  =  240-270 tokens
```

At ~5 pings a day that is roughly 1,200 tokens. For scale only: at
pay-as-you-go API rates that would be about a third of a cent a day (near $1 a
year) - which you do not pay on a subscription. If you have instead configured
Claude Code with an `ANTHROPIC_API_KEY` or enabled extra usage, it bills
normally at that rate.

It stays that small because of four flags:

| Flag | Effect |
| --- | --- |
| `--system-prompt` | Replaces Claude Code's ~15k-token default system prompt |
| `--tools=` | No tool schemas in the request |
| `--safe-mode` | No CLAUDE.md, skills, plugins, hooks or MCP |
| `--no-session-persistence` | Doesn't litter `~/.claude/projects` with keepalive sessions |

A plain `claude -p hi` costs roughly 60× more.

!!! info "Why `--tools=` and not `--tools \"\"`"

    PowerShell 5.1 silently drops empty-string arguments to native executables,
    so the quoted form would break the Windows port — the flag would vanish and
    every ping would carry full tool schemas. The `=` form behaves identically
    on both platforms.

## Boundaries rotate

24 isn't divisible by 5, so a tiling schedule can't hold a fixed daily phase.
Boundaries at 07:00 / 12:00 / 17:00 / 22:00 today become 03:00 / 08:00 / 13:00 /
18:00 / 23:00 tomorrow, shifting an hour earlier each day.

This is inherent to a five-hour window, not something the tool can fix. You can
re-phase whenever you like by running `keepwarm ping` at the top of an hour you
want a boundary on — that opens a window there and every subsequent boundary
follows from it.

## The model is inferred, not documented

The hour-anchoring above matches observed behaviour, but Anthropic doesn't
document it. If the real anchoring differs, pings will occasionally land early —
which surfaces as a `LIMITED` line and a retry, not as breakage.

If you see `LIMITED` repeatedly, raise `SLACK_MINUTES`. That's the knob for
exactly this uncertainty.
