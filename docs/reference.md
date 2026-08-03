# Reference

## Commands

On Windows, every command is identical with `.\keepwarm.ps1` in place of
`./keepwarm`.

| Command | What it does |
| --- | --- |
| `keepwarm install` | Install the hourly cron job / scheduled task |
| `keepwarm ping` | Open a window now — also **re-phases** your boundaries |
| `keepwarm doctor` | Health check: binary, schedule, daemon, heartbeat, window |
| `keepwarm status` | Current window, next ping, recent log |
| `keepwarm run` | Ping only if the window expired (what the scheduler calls) |
| `keepwarm ping --dry-run` | Print the exact command without calling Claude |
| `keepwarm log [n]` | Last n log lines (default 40) |
| `keepwarm config` | Resolved settings and paths |
| `keepwarm uninstall` | Remove the schedule |
| `keepwarm version` | Print the version |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Failure — `doctor` found a failing check, or `ping` errored |
| `2` | `ping` was rate-limited (you're inside a live window; nothing lost) |
| `3` | `ping` could not authenticate - sign in again |

## Log lines

The log is the source of truth for what the scheduler did, and doubles as its
heartbeat.

| Prefix | Meaning |
| --- | --- |
| `WAIT` | Tick ran, window still live, nothing spent |
| `OK` / `WINDOW` | Ping succeeded, a new window opened |
| `SKIP` | You were already active after the boundary, or another run held the lock |
| `LIMITED` | Still inside a window — state untouched, will retry next tick |
| `RETRY` | Transient failure, retrying within this run |
| `ERROR` | Ping failed; the payload is logged up to 1200 chars |

`WAIT` lines are the healthy steady state. Seeing them every hour means the
schedule is alive and correctly deciding not to spend anything.

## Configuration

```sh
cp config.env.example config.env
```

`config.env` is gitignored, so your settings survive a `git pull`. Every value is
commented out by default.

| Setting | Default | Notes |
| --- | --- | --- |
| `WINDOW_HOURS` | `5` | Length of the usage window |
| `SLACK_MINUTES` | `2` | Delay past the boundary before pinging. Raise to 5 if you see `LIMITED` |
| `CRON_MINUTE` | `2` | Minute of the hour the job fires on |
| `MODEL` | `haiku` | The window is account-wide, so the cheapest model opens it just as well |
| `PING_PROMPT` | `ping` | The keepalive prompt |
| `PING_SYSTEM_PROMPT` | *(see file)* | Replaces Claude Code's default — this is the main cost saving |
| `PING_ATTEMPTS` | `3` | In-process retries for transient failures |
| `PING_RETRY_DELAY` | `20` | Seconds between attempts |
| `SKIP_IF_RECENTLY_ACTIVE` | `1` | Don't spend a ping if your own messages already opened the window |
| `ACTIVITY_DIR` | `~/.claude/projects` | Where the activity check looks |
| `CLAUDE_BIN` | auto | Pin the binary if auto-detection picks wrong |
| `LOG_RETENTION_DAYS` | `30` | Log pruning |

Any setting can also be overridden for one invocation with a `KEEPWARM_` prefix:

```sh
KEEPWARM_MODEL=sonnet ./keepwarm ping
```

Precedence is **defaults → `config.env` → environment**.

## Files

```
keepwarm            the Unix script
keepwarm.ps1        the Windows port
config.env          your settings (gitignored)
state/window.env    current window start/end, last ping status
logs/keepwarm.log   one line per tick, pruned after 30 days
```

The state file is plain `KEY=value` and shared by both ports, so moving between
WSL and native Windows keeps your window.

## Troubleshooting

??? question "`doctor` says the schedule is installed but `last tick` is stale"

    The scheduler isn't running the script. On Linux, check `cron`/`crond` is
    active. On macOS, your terminal may need permission to install cron jobs. On
    Windows, open Task Scheduler and check the task's History tab.

??? question "The log keeps showing `LIMITED`"

    Pings are landing before the window has really expired. Raise
    `SLACK_MINUTES` to 5. Nothing is lost when this happens — state is left
    untouched and the next tick retries.

??? question "`not authenticated` / `Failed to authenticate: OAuth session expired`"

    Your Claude Code login has expired. keepwarm can't refresh it for you - it
    holds no credentials of its own. Sign in again and retry:

    ```sh
    claude          # then use /login
    keepwarm ping
    ```

    Auth failures are deliberately **not** retried: an expired session stays
    expired until a human signs in, so retrying just burns time and fills the
    log. `doctor` reports it as a failing check until the next successful ping.

??? question "`claude binary not found`"

    Auto-detection didn't find the CLI. Set `CLAUDE_BIN` in `config.env` to the
    full path. `./keepwarm config` shows what it resolved.

??? question "Can I run it on more than one machine?"

    The window is account-wide but the state file is local, so two machines
    would ping independently. It's harmless — the second one sees a live window
    and waits — but pick one machine that's reliably awake.

??? question "Does this break my plan's terms?"

    keepwarm uses your own subscription within its existing limits, doesn't
    bypass anything, and shares no credentials. It does create automated
    background usage on your account, which is your call to make.

## Development

```sh
./tests/run.sh          # 21 tests — no network, no API calls, no real crontab
./tests/run.sh lock     # filter by name
shellcheck -s bash keepwarm tests/run.sh
```

```powershell
.\tests\run.ps1         # 16 tests, same coverage on the Windows port
```

Tests run in a throwaway sandbox with a stub `claude` and a fake `crontab`, so
`install` / `uninstall` are exercised without touching your real schedule.

CI covers:

| Job | What it catches |
| --- | --- |
| Linux + macOS | GNU vs BSD `date` divergence |
| macOS `/bin/bash` | bash 3.2 syntax |
| Windows PowerShell 5.1 + 7 | the native port on the version that ships with Windows |
| Task Scheduler smoke test | a real `install` / `uninstall` round trip |
| `Asia/Kolkata`, `Asia/Kathmandu` | half-hour offsets, which break `epoch % 3600` hour-flooring |
| shellcheck + PSScriptAnalyzer | lint on both ports |
