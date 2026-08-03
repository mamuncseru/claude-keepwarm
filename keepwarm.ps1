<#
.SYNOPSIS
    keepwarm - keep Claude Code's 5-hour usage window rolling. (Windows port)

.DESCRIPTION
    Claude Code's usage window starts at the top of the hour containing your
    FIRST message and lasts 5 hours. It does not tick while you are away. Idle
    all night, start at 09:00, exhaust the quota by 10:00, and you wait until
    14:00 - having gained nothing from the idle hours.

    keepwarm sends one tiny prompt just after each window expires, so windows
    tile back-to-back around the clock. You do not get more quota per window;
    you get more windows per day.

    This is the native Windows port of the bash script of the same name. It
    keeps the same state file format and the same command surface, and uses
    Task Scheduler where the Unix version uses cron.

.EXAMPLE
    .\keepwarm.ps1 install
    .\keepwarm.ps1 ping
    .\keepwarm.ps1 doctor

.LINK
    https://github.com/mamuncseru/claude-keepwarm
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'ping', 'status', 'doctor', 'log', 'install', 'uninstall',
                 'config', 'version', 'help')]
    [string]$Command = 'status',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$KeepwarmVersion = '1.2.1'
$TaskName        = 'claude-keepwarm'

# --------------------------------------------------------------------- paths --

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath

# $env:USERPROFILE is null off Windows, and Join-Path throws on a null Path -
# which crashed the script at load time before it printed anything.
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }

$HomeDir = if ($env:KEEPWARM_HOME) { $env:KEEPWARM_HOME } else { $ScriptDir }
$StateDir  = Join-Path $HomeDir 'state'
$LogDir    = Join-Path $HomeDir 'logs'
$StateFile = Join-Path $StateDir 'window.env'
$LogFile   = Join-Path $LogDir  'keepwarm.log'
$LockDir   = Join-Path $StateDir 'keepwarm.lock.d'
$ConfigFile = if ($env:KEEPWARM_CONFIG) { $env:KEEPWARM_CONFIG } else { Join-Path $HomeDir 'config.env' }

New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null

# -------------------------------------------------------------------- config --
# Defaults, then config.env, then KEEPWARM_* environment variables (which win).
# Same precedence and same file format as the Unix version, so a single
# documented config works on both.

$Config = @{
    WINDOW_HOURS            = 5
    SLACK_MINUTES           = 2
    MODEL                   = 'haiku'
    CRON_MINUTE             = 2
    LOG_RETENTION_DAYS      = 30
    PING_PROMPT             = 'ping'
    PING_SYSTEM_PROMPT      = 'You are a keepalive probe. Reply with exactly: ok'
    PING_ATTEMPTS           = 3
    PING_RETRY_DELAY        = 20
    SKIP_IF_RECENTLY_ACTIVE = 1
    ACTIVITY_DIR            = (Join-Path (Join-Path $UserHome '.claude') 'projects')
    CLAUDE_BIN              = ''
}

if (Test-Path -LiteralPath $ConfigFile) {
    foreach ($line in (Get-Content -LiteralPath $ConfigFile)) {
        if ($line -match '^\s*#') { continue }
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
        $key = $Matches[1]
        $val = $Matches[2] -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
        # config.env is shell syntax; translate the one expansion that matters.
        $val = $val -replace '\$\{?HOME\}?', ([regex]::Escape($env:USERPROFILE) -replace '\\\\', '\')
        if ($Config.ContainsKey($key)) { $Config[$key] = $val }
    }
}

foreach ($key in @($Config.Keys)) {
    $envVal = [Environment]::GetEnvironmentVariable("KEEPWARM_$key")
    if ($envVal) { $Config[$key] = $envVal }
}

$WindowSeconds = [int]$Config.WINDOW_HOURS * 3600
$SlackSeconds  = [int]$Config.SLACK_MINUTES * 60

# ------------------------------------------------------------------- helpers --

function ConvertTo-Epoch {
    param([Parameter(Mandatory)][datetime]$Date)
    [long]([DateTimeOffset]::new($Date)).ToUnixTimeSeconds()
}

function ConvertFrom-Epoch {
    param([Parameter(Mandatory)][long]$Epoch)
    [DateTimeOffset]::FromUnixTimeSeconds($Epoch).ToLocalTime().DateTime
}

function Get-NowEpoch { ConvertTo-Epoch -Date (Get-Date) }

# Floor to the top of the local hour. DateTime arithmetic handles half-hour
# timezones correctly, which naive epoch modulo 3600 does not.
function Get-FlooredHourEpoch {
    param([Parameter(Mandatory)][long]$Epoch)
    $d = ConvertFrom-Epoch -Epoch $Epoch
    ConvertTo-Epoch -Date $d.Date.AddHours($d.Hour)
}

function Format-Epoch {
    param([long]$Epoch = 0)
    if ($Epoch -le 0) { return 'never' }
    (ConvertFrom-Epoch -Epoch $Epoch).ToString('yyyy-MM-dd HH:mm')
}

function Format-Duration {
    param([Parameter(Mandatory)][long]$Seconds)
    $s = [Math]::Abs($Seconds)
    '{0}h {1:d2}m' -f [int][Math]::Floor($s / 3600), [int](($s % 3600) / 60)
}

function Write-KwLog {
    param([Parameter(Mandatory)][string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -LiteralPath $LogFile -Value "$stamp  $Message"
}

function Write-Say { param([string]$Message = '') Write-Host $Message }

# Collapse a payload to one log-friendly line.
function Format-OneLine {
    param([string]$Text = '', [int]$Max = 1200)
    $t = ($Text -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' '
    if ($t.Length -gt $Max) { $t.Substring(0, $Max) } else { $t }
}

# ------------------------------------------------------------- claude binary --

function Resolve-ClaudeBin {
    if ($Config.CLAUDE_BIN) {
        if (Test-Path -LiteralPath $Config.CLAUDE_BIN) { return $Config.CLAUDE_BIN }
        Write-Say "keepwarm: CLAUDE_BIN is set but not found: $($Config.CLAUDE_BIN)"
        return $null
    }

    $onPath = Get-Command claude -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    # The VS Code / Cursor extensions bundle their own copy in a
    # version-numbered directory and do not add it to PATH. Sort descending so
    # an extension update does not break the scheduled task.
    # Built conditionally: a null base would throw rather than just not match.
    # Forward slashes are accepted on Windows too.
    $globs = @()
    if ($UserHome) {
        $globs += (Join-Path $UserHome '.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude.exe')
        $globs += (Join-Path $UserHome '.cursor/extensions/anthropic.claude-code-*/resources/native-binary/claude.exe')
        $globs += (Join-Path $UserHome '.local/bin/claude.exe')
        $globs += (Join-Path $UserHome '.claude/local/claude.exe')
        $globs += (Join-Path $UserHome '.bun/bin/claude.exe')
    }
    if ($env:APPDATA) { $globs += (Join-Path $env:APPDATA 'npm/claude.cmd') }
    foreach ($g in $globs) {
        $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    Write-Say "keepwarm: could not find claude. Set CLAUDE_BIN in $ConfigFile"
    return $null
}

# --------------------------------------------------------------------- state --

function Get-KwState {
    $state = @{ WINDOW_START = [long]0; WINDOW_END = [long]0; LAST_PING = [long]0; LAST_STATUS = 'none' }
    if (Test-Path -LiteralPath $StateFile) {
        foreach ($line in (Get-Content -LiteralPath $StateFile)) {
            if ($line -match '^([A-Z_]+)=(.*)$') {
                $k = $Matches[1]; $v = $Matches[2]
                if ($state.ContainsKey($k)) {
                    if ($k -eq 'LAST_STATUS') { $state[$k] = $v } else { $state[$k] = [long]$v }
                }
            }
        }
    }
    $state
}

function Set-KwState {
    param([Parameter(Mandatory)][hashtable]$State)
    # Written in the Unix script's format on purpose: same file, same parser,
    # so a user moving between WSL and native Windows keeps their window.
    $lines = @(
        "WINDOW_START=$($State.WINDOW_START)"
        "WINDOW_END=$($State.WINDOW_END)"
        "LAST_PING=$($State.LAST_PING)"
        "LAST_STATUS=$($State.LAST_STATUS)"
    )
    Set-Content -LiteralPath $StateFile -Value $lines -Encoding ASCII
}

function Open-KwWindow {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][long]$At)
    $State.WINDOW_START = Get-FlooredHourEpoch -Epoch $At
    $State.WINDOW_END   = $State.WINDOW_START + $WindowSeconds
    Set-KwState -State $State
}

function Get-DueEpoch {
    param([Parameter(Mandatory)][hashtable]$State)
    if ($State.WINDOW_END -le 0) { return [long]0 }
    [long]($State.WINDOW_END + $SlackSeconds)
}

# ---------------------------------------------------------------------- lock --

function Enter-KwLock {
    $pidFile = Join-Path $LockDir 'pid'
    try {
        New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII
        return $true
    } catch {
        # Directory exists. If its owner is gone the lock is stale.
        $owner = $null
        if (Test-Path -LiteralPath $pidFile) {
            $owner = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ($owner -and (Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue)) {
            return $false
        }
        Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
        try {
            New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII
            return $true
        } catch { return $false }
    }
}

function Exit-KwLock {
    Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ activity --

# Did we use Claude Code ourselves after the window expired? Then the new
# window is already open and a ping would be wasted.
function Test-RecentActivity {
    param([Parameter(Mandatory)][hashtable]$State)
    if ([int]$Config.SKIP_IF_RECENTLY_ACTIVE -ne 1) { return $false }
    if ($State.WINDOW_END -le 0) { return $false }
    if (-not (Test-Path -LiteralPath $Config.ACTIVITY_DIR)) { return $false }

    $boundary = ConvertFrom-Epoch -Epoch $State.WINDOW_END
    $hit = Get-ChildItem -LiteralPath $Config.ACTIVITY_DIR -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -gt $boundary } | Select-Object -First 1
    [bool]$hit
}

# ---------------------------------------------------------------------- ping --

# One attempt. Returns 'ok' | 'limited' | 'error'.
function Invoke-PingOnce {
    param([Parameter(Mandatory)][string]$Bin)

    $cliArgs = @(
        '-p', $Config.PING_PROMPT
        '--model', $Config.MODEL
        '--safe-mode'
        '--disable-slash-commands'
        '--strict-mcp-config'
        '--no-session-persistence'
        '--system-prompt', $Config.PING_SYSTEM_PROMPT
        # `--tools=` not `--tools ""`: PowerShell 5.1 silently drops
        # empty-string arguments to native executables.
        '--tools='
        '--output-format', 'json'
    )

    $raw = ''
    $rc = 0
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'   # native stderr must not throw
        $raw = (& $Bin @cliArgs 2>&1 | Out-String)
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
    } catch {
        Write-KwLog "ERROR    invocation failed :: $(Format-OneLine -Text $_.Exception.Message -Max 400)"
        return 'error'
    }

    if ($raw -match '(?i)usage limit|rate.?limit|limit reached|limit will reset|resets at') {
        Write-KwLog "LIMITED  still inside a window; will retry next tick :: $(Format-OneLine -Text $raw -Max 300)"
        return 'limited'
    }
    if ($rc -ne 0 -or $raw -match '"is_error"\s*:\s*true') {
        Write-KwLog "ERROR    rc=$rc :: $(Format-OneLine -Text $raw -Max 1200)"
        return 'error'
    }

    Write-KwLog "OK       $(Format-OneLine -Text $raw -Max 400)"
    return 'ok'
}

# Retries transient local failures. A 'limited' result is NOT retried: it means
# the old window has not actually expired, and the next hourly tick is the
# right place to try again.
function Invoke-Ping {
    $bin = Resolve-ClaudeBin
    if (-not $bin) {
        Write-KwLog "ERROR    claude binary not found; set CLAUDE_BIN in $ConfigFile"
        return 'error'
    }

    $attempts = [int]$Config.PING_ATTEMPTS
    $delay    = [int]$Config.PING_RETRY_DELAY
    for ($i = 1; $i -le $attempts; $i++) {
        $status = Invoke-PingOnce -Bin $bin
        if ($status -eq 'ok' -or $status -eq 'limited') { return $status }
        if ($i -lt $attempts) {
            Write-KwLog "RETRY    attempt $i failed; retrying in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
    return 'error'
}

function Remove-OldLogLines {
    if (-not (Test-Path -LiteralPath $LogFile)) { return }
    $cutoff = (Get-Date).AddDays(-[int]$Config.LOG_RETENTION_DAYS).ToString('yyyy-MM-dd')
    $kept = Get-Content -LiteralPath $LogFile | Where-Object {
        $_ -match '^(\d{4}-\d{2}-\d{2})' -and $Matches[1] -ge $cutoff
    }
    Set-Content -LiteralPath $LogFile -Value $kept -Encoding ASCII
}

# ------------------------------------------------------------------- tasks --

# Guarded so status/doctor also work on a host without Task Scheduler (macOS,
# Linux, PowerShell 7 anywhere). -ErrorAction does not suppress a *missing
# cmdlet*, which throws under $ErrorActionPreference = 'Stop'.
function Test-HasTaskCmdlets {
    [bool](Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)
}

function Get-KwTask {
    if (-not (Test-HasTaskCmdlets)) { return $null }
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

# Register the task against the PowerShell the user actually ran install with,
# so installing from pwsh 7 does not silently schedule Windows PowerShell 5.1.
function Get-PowerShellPath {
    $current = (Get-Process -Id $PID).Path
    if ($current) { return $current }
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

# ---------------------------------------------------------------- commands --

function Invoke-CmdRun {
    if (-not (Enter-KwLock)) {
        Write-KwLog 'SKIP     another keepwarm run is in progress'
        return
    }
    try {
        $state = Get-KwState
        $now = Get-NowEpoch
        $due = Get-DueEpoch -State $state

        if ($now -lt $due) {
            Write-KwLog "WAIT     window ends $(Format-Epoch $state.WINDOW_END); $(Format-Duration ($due - $now)) to go"
            return
        }

        if (Test-RecentActivity -State $state) {
            $boundary = $state.WINDOW_END
            $state.LAST_STATUS = 'skipped'
            Open-KwWindow -State $state -At $boundary
            Write-KwLog "SKIP     you were active after $(Format-Epoch $boundary); window now runs to $(Format-Epoch $state.WINDOW_END)"
            return
        }

        $state.LAST_PING = $now
        $status = Invoke-Ping
        $state.LAST_STATUS = $status

        if ($status -eq 'ok') {
            Open-KwWindow -State $state -At $now
            Write-KwLog "WINDOW   opened $(Format-Epoch $state.WINDOW_START) -> $(Format-Epoch $state.WINDOW_END)"
        } else {
            Set-KwState -State $state    # leave WINDOW_END alone so we retry
        }

        Remove-OldLogLines
    } finally {
        Exit-KwLock
    }
}

function Invoke-CmdPing {
    param([string[]]$PingArgs = @())

    $state = Get-KwState

    if ($PingArgs -contains '--dry-run') {
        $bin = Resolve-ClaudeBin
        Write-Say 'would run:'
        Write-Say "  $(if ($bin) { $bin } else { '<claude>' }) -p '$($Config.PING_PROMPT)' --model $($Config.MODEL) --safe-mode ``"
        Write-Say "    --disable-slash-commands --strict-mcp-config --no-session-persistence ``"
        Write-Say "    --system-prompt '$($Config.PING_SYSTEM_PROMPT)' --tools= --output-format json"
        return 0
    }

    Write-Say "pinging with model '$($Config.MODEL)'..."
    $state.LAST_PING = Get-NowEpoch
    $status = Invoke-Ping
    $state.LAST_STATUS = $status

    switch ($status) {
        'ok' {
            Open-KwWindow -State $state -At $state.LAST_PING
            Write-Say "ok - window is now $(Format-Epoch $state.WINDOW_START) -> $(Format-Epoch $state.WINDOW_END)"
            return 0
        }
        'limited' {
            Set-KwState -State $state
            Write-Say 'still rate limited - you are inside an existing window. Nothing lost; try later.'
            return 2
        }
        default {
            Set-KwState -State $state
            Write-Say 'ping failed. See: .\keepwarm.ps1 log'
            return 1
        }
    }
}

function Invoke-CmdStatus {
    $state = Get-KwState
    $bin = Resolve-ClaudeBin
    $now = Get-NowEpoch
    $due = Get-DueEpoch -State $state

    Write-Say "keepwarm $KeepwarmVersion (windows)"
    Write-Say ''
    Write-Say ("  claude binary   {0}" -f $(if ($bin) { $bin } else { 'NOT FOUND' }))
    Write-Say ("  model           {0}" -f $Config.MODEL)
    Write-Say ("  window length   {0}h (+{1}m slack)" -f $Config.WINDOW_HOURS, $Config.SLACK_MINUTES)
    Write-Say ''

    if ($state.WINDOW_END -le 0) {
        Write-Say '  window          none recorded yet - run ".\keepwarm.ps1 ping"'
    } else {
        Write-Say ("  window          {0}  ->  {1}" -f (Format-Epoch $state.WINDOW_START), (Format-Epoch $state.WINDOW_END))
        if ($now -lt $state.WINDOW_END) {
            Write-Say ("  resets in       {0}" -f (Format-Duration ($state.WINDOW_END - $now)))
        } else {
            Write-Say ("  resets in       expired {0} ago" -f (Format-Duration ($now - $state.WINDOW_END)))
        }
        if ($now -lt $due) {
            Write-Say ("  next ping       {0} (in {1})" -f (Format-Epoch $due), (Format-Duration ($due - $now)))
        } else {
            Write-Say '  next ping       due now (next scheduled run)'
        }
    }
    Write-Say ("  last ping       {0} [{1}]" -f (Format-Epoch $state.LAST_PING), $state.LAST_STATUS)
    Write-Say ''

    if (Get-KwTask) {
        Write-Say "  task            installed: $TaskName (hourly)"
    } else {
        Write-Say '  task            NOT installed - run ".\keepwarm.ps1 install"'
    }

    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 0) {
        Write-Say ''
        Write-Say '  recent activity'
        Get-Content -LiteralPath $LogFile -Tail 8 | ForEach-Object { Write-Say "    $_" }
    }
}

function Invoke-CmdDoctor {
    $state = Get-KwState
    $now = Get-NowEpoch

    function Write-Check {
        param([string]$Level, [string]$Label, [string]$Detail)
        switch ($Level) {
            'ok'   { Write-Say ("  [ok]   {0,-22} {1}" -f $Label, $Detail); $script:ok++ }
            'warn' { Write-Say ("  [warn] {0,-22} {1}" -f $Label, $Detail); $script:warn++ }
            default { Write-Say ("  [FAIL] {0,-22} {1}" -f $Label, $Detail); $script:fail++ }
        }
    }
    $script:ok = 0; $script:warn = 0; $script:fail = 0

    Write-Say "keepwarm $KeepwarmVersion - doctor (windows)"
    Write-Say ''

    $bin = Resolve-ClaudeBin
    if ($bin) { Write-Check ok 'claude binary' $bin }
    else { Write-Check fail 'claude binary' "not found - set CLAUDE_BIN in $ConfigFile" }

    $task = Get-KwTask
    if ($task) { Write-Check ok 'scheduled task' "$TaskName ($($task.State))" }
    else { Write-Check fail 'scheduled task' 'not installed - run ".\keepwarm.ps1 install"' }

    $svc = $null
    if (Get-Command Get-Service -ErrorAction SilentlyContinue) {
        $svc = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
    }
    if ($svc -and $svc.Status -eq 'Running') { Write-Check ok 'task scheduler' 'running' }
    else { Write-Check warn 'task scheduler' 'not detected (see last tick)' }

    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 0) {
        $last = Get-Content -LiteralPath $LogFile -Tail 1
        if ($last -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
            $age = $now - (ConvertTo-Epoch -Date ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)))
            if ($age -le 3900) { Write-Check ok 'last tick' "$(Format-Duration $age) ago - the task is firing" }
            else { Write-Check fail 'last tick' "$(Format-Duration $age) ago - expected one every hour" }
        } else {
            Write-Check warn 'last tick' 'could not parse log timestamp'
        }
    } else {
        Write-Check warn 'last tick' 'no log yet - the task has not run'
    }

    if ($state.WINDOW_END -gt 0) {
        Write-Check ok 'window tracked' ("{0} -> {1}" -f (Format-Epoch $state.WINDOW_START), (Format-Epoch $state.WINDOW_END))
    } else {
        Write-Check warn 'window tracked' 'none yet - run ".\keepwarm.ps1 ping"'
    }

    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($info -and $info.NextRunTime) {
            Write-Say ''
            Write-Say ("  next task run    {0}" -f $info.NextRunTime.ToString('yyyy-MM-dd HH:mm'))
        }
    }

    Write-Say ''
    Write-Say ("  {0} ok, {1} warning(s), {2} failing" -f $script:ok, $script:warn, $script:fail)
    if ($script:fail -gt 0) { return 1 }
    return 0
}

function Invoke-CmdInstall {
    if (-not (Test-HasTaskCmdlets)) {
        throw 'Task Scheduler cmdlets are unavailable. On macOS/Linux use the ./keepwarm script instead.'
    }
    $bin = Resolve-ClaudeBin
    if (-not $bin) { throw "fix CLAUDE_BIN in $ConfigFile before installing" }

    $psExe = Get-PowerShellPath
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden ' +
               ('-File "{0}" run' -f $ScriptPath)

    $action = New-ScheduledTaskAction -Execute $psExe -Argument $argLine -WorkingDirectory $ScriptDir

    # Repeat hourly, forever, starting at :CRON_MINUTE past.
    $startAt = (Get-Date).Date.AddMinutes([int]$Config.CRON_MINUTE)
    $trigger = New-ScheduledTaskTrigger -Once -At $startAt `
        -RepetitionInterval (New-TimeSpan -Hours 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    # StartWhenAvailable is the Windows analogue of the self-correcting hourly
    # tick: after sleep or hibernation the missed run fires as soon as it can,
    # instead of silently waiting for the next hour.
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'Keeps Claude Code''s 5-hour usage window rolling.' `
        -Force | Out-Null

    Write-Say "installed scheduled task '$TaskName' (hourly at :$('{0:d2}' -f [int]$Config.CRON_MINUTE))"
    Write-Say ''
    Write-Say 'It checks every hour and only calls Claude when the window has actually'
    Write-Say 'expired, so a missed run (sleep, reboot) self-corrects.'

    $state = Get-KwState
    if ($state.WINDOW_END -le 0) {
        Write-Say ''
        Write-Say 'No window recorded yet. Run ".\keepwarm.ps1 ping" to open the first one -'
        Write-Say 'do it at the top of an hour you like, that sets your boundary phase.'
    }
}

function Invoke-CmdUninstall {
    if (-not (Get-KwTask)) {
        Write-Say 'no keepwarm scheduled task installed'
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Say "removed scheduled task '$TaskName'. State and logs kept in $HomeDir."
}

function Invoke-CmdLog {
    param([string[]]$LogArgs = @())
    $n = 40
    if ($LogArgs.Count -gt 0 -and $LogArgs[0] -match '^\d+$') { $n = [int]$LogArgs[0] }
    if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail $n }
    else { Write-Say 'no log yet' }
}

function Invoke-CmdConfig {
    $bin = Resolve-ClaudeBin
    Write-Say "keepwarm $KeepwarmVersion (windows / task scheduler)"
    Write-Say ''
    Write-Say ("{0,-24} {1}{2}" -f 'config file', $ConfigFile, $(if (Test-Path -LiteralPath $ConfigFile) { '' } else { ' (absent, using defaults)' }))
    Write-Say ("{0,-24} {1}" -f 'claude bin', $(if ($bin) { $bin } else { 'NOT FOUND' }))
    Write-Say ("{0,-24} {1}" -f 'state', $StateFile)
    Write-Say ("{0,-24} {1}" -f 'log', $LogFile)
    Write-Say ''
    foreach ($k in 'WINDOW_HOURS','SLACK_MINUTES','MODEL','CRON_MINUTE','LOG_RETENTION_DAYS',
                   'PING_ATTEMPTS','PING_RETRY_DELAY','SKIP_IF_RECENTLY_ACTIVE','ACTIVITY_DIR') {
        Write-Say ("{0,-24} {1}" -f $k, $Config[$k])
    }
}

function Show-Usage {
    Write-Say @"
keepwarm $KeepwarmVersion - keep Claude Code's 5-hour usage window rolling

  .\keepwarm.ps1 install          install the hourly scheduled task
  .\keepwarm.ps1 ping             open a window now; also re-phases boundaries
  .\keepwarm.ps1 doctor           is it actually running? task, service, heartbeat
  .\keepwarm.ps1 status           current window, next ping, recent log

  .\keepwarm.ps1 run              ping only if the window expired (what the task calls)
  .\keepwarm.ps1 ping --dry-run   print the exact command without calling Claude
  .\keepwarm.ps1 log [n]          last n log lines (default 40)
  .\keepwarm.ps1 config           resolved settings and paths
  .\keepwarm.ps1 uninstall        remove the scheduled task
  .\keepwarm.ps1 version          print the version

Configure by copying config.env.example to config.env next to this script.
https://github.com/mamuncseru/claude-keepwarm
"@
}

# -------------------------------------------------------------------- main --

$exit = 0
switch ($Command) {
    'run'       { Invoke-CmdRun }
    'ping'      { $exit = Invoke-CmdPing -PingArgs $Rest }
    'status'    { Invoke-CmdStatus }
    'doctor'    { $exit = Invoke-CmdDoctor }
    'log'       { Invoke-CmdLog -LogArgs $Rest }
    'install'   { Invoke-CmdInstall }
    'uninstall' { Invoke-CmdUninstall }
    'config'    { Invoke-CmdConfig }
    'version'   { Write-Say $KeepwarmVersion }
    'help'      { Show-Usage }
    default     { Show-Usage; $exit = 1 }
}
exit $exit
