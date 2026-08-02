# Install

You need a logged-in [Claude Code](https://claude.com/claude-code) CLI. keepwarm
reads no credentials of its own — it uses whatever authentication the CLI
already has.

## macOS / Linux

Requires bash 3.2+ (the version macOS ships) and `cron`.

```sh
git clone https://github.com/mamuncseru/claude-keepwarm.git
cd claude-keepwarm

./keepwarm install     # hourly cron job
./keepwarm ping        # open the first window — sets your boundary phase
./keepwarm doctor      # confirm it's actually running
```

Run `ping` at the top of an hour you'd like a boundary on: the window it opens
determines where every later boundary falls.

Remove it with `./keepwarm uninstall`. State and logs are left in place.

## Windows

Requires Windows PowerShell 5.1 (ships with Windows 10 and 11) or PowerShell 7.
Uses Task Scheduler instead of cron, with the same commands, the same
`config.env`, and the same state file format.

```powershell
git clone https://github.com/mamuncseru/claude-keepwarm.git
cd claude-keepwarm

.\keepwarm.ps1 install    # hourly scheduled task
.\keepwarm.ps1 ping       # open the first window
.\keepwarm.ps1 doctor     # confirm it's actually running
```

If PowerShell blocks the script, either unblock it once with
`Unblock-File .\keepwarm.ps1`, or run it as
`powershell -ExecutionPolicy Bypass -File .\keepwarm.ps1 install`. The task it
registers always passes `-ExecutionPolicy Bypass`, so scheduled runs work either
way.

!!! tip "Use the native port, not WSL"

    WSL2 shuts its VM down once your last shell exits, so `cron` inside WSL
    won't fire overnight — exactly when the keepalive matters. Making WSL
    reliable means having Windows Task Scheduler wake it, at which point the
    native port is the same integration with one less moving part.

The Windows task is registered with `StartWhenAvailable`, so a run missed while
the machine was asleep fires as soon as it's back rather than waiting a full
hour.

## Finding the CLI

keepwarm looks for `claude` in this order:

1. `PATH`
2. The copy bundled inside the VS Code / Cursor extension
   (`…/anthropic.claude-code-*/resources/native-binary/`), newest match first
3. `~/.local/bin`, `~/.claude/local`, `~/.bun/bin`
4. `/usr/local/bin`, `/opt/homebrew/bin` (Unix) or `%APPDATA%\npm` (Windows)

The extension bundle matters more than it sounds: it's a common install shape
and it is **not** on `PATH`. Because the directory name carries the extension
version, keepwarm globs and takes the newest — so an extension update doesn't
quietly break your scheduled job.

If auto-detection picks the wrong one, pin it:

```sh
cp config.env.example config.env
# then set CLAUDE_BIN=/full/path/to/claude
```

## Verifying

```sh
./keepwarm doctor
```

Anything other than `0 failing` tells you what's wrong. The most useful line is
`last tick` — under about 65 minutes old proves the scheduler is really running
the script, which is the part people usually can't confirm.

If `doctor` says the cron job is installed but `last tick` is stale, the schedule
isn't firing. On Linux check that `crond`/`cron` is running; on macOS confirm
your terminal has permission to add cron jobs; on Windows check the task's
history in Task Scheduler.

## Uninstalling

```sh
./keepwarm uninstall          # or: .\keepwarm.ps1 uninstall
```

That removes only the schedule. Delete the cloned directory to remove state and
logs as well.
