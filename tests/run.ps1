<#
    keepwarm Windows test suite. No network, no API calls, no scheduled tasks.

    Mirrors tests/run.sh. Each test runs in a throwaway sandbox with a stub
    `claude.cmd` (canned responses, counts invocations) pointed at via
    KEEPWARM_CLAUDE_BIN, so results don't depend on the developer's machine.

    Task Scheduler registration is deliberately NOT unit-tested here - it has
    no safe stub. CI covers it with a real install/uninstall smoke test.

        .\tests\run.ps1              run everything
        .\tests\run.ps1 lock         run tests whose name matches "lock"
#>
[CmdletBinding()]
param([string]$Filter = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Kw   = Join-Path $Root 'keepwarm.ps1'
# The PowerShell running THIS suite - not a hardcoded 5.1 path. Hardcoding it
# meant the PowerShell 7 CI job silently tested 5.1 instead.
$Ps   = (Get-Process -Id $PID).Path
$OnWindows = if ($PSVersionTable.PSEdition -eq 'Desktop') { $true } else { $IsWindows }

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()
$script:Current = ''

# ----------------------------------------------------------------- harness --

function New-Sandbox {
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("keepwarm-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Sandbox 'home') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Sandbox 'activity') | Out-Null

    $script:StubLog  = Join-Path $script:Sandbox 'calls.txt'
    $script:StubFlag = Join-Path $script:Sandbox 'flaky.flag'
    New-Item -ItemType File -Force -Path $script:StubLog | Out-Null

    # A stub for whichever platform we are on, so the suite runs on Windows,
    # macOS and Linux alike.
    if ($OnWindows) {
        $stub = Join-Path $script:Sandbox 'claude.cmd'
        $body = @'
@echo off
>>"%STUB_LOG%" echo call
if "%STUB_MODE%"=="limited" (
  echo Claude usage limit reached. Your limit will reset at 3pm.
  exit /b 0
)
if "%STUB_MODE%"=="error" (
  echo {"is_error":true,"result":"stub failure"}
  exit /b 1
)
if "%STUB_MODE%"=="auth" (
  echo {"is_error":true,"duration_api_ms":0,"stop_reason":"stop_sequence","total_cost_usd":0,"terminal_reason":"api_error","result":"Failed to authenticate: OAuth session expired and could not be refreshed","type":"result"}
  exit /b 1
)
if "%STUB_MODE%"=="flaky" (
  if not exist "%STUB_FLAG%" (
    >"%STUB_FLAG%" echo x
    echo {"is_error":true,"result":"transient"}
    exit /b 1
  )
  echo {"is_error":false,"result":"ok"}
  exit /b 0
)
echo {"is_error":false,"result":"ok","usage":{"input_tokens":167,"output_tokens":71}}
exit /b 0
'@
        [IO.File]::WriteAllText($stub, $body)
    } else {
        $stub = Join-Path $script:Sandbox 'claude.sh'
        $body = @'
#!/usr/bin/env bash
printf 'call\n' >>"$STUB_LOG"
case "${STUB_MODE:-ok}" in
  limited) printf 'Claude usage limit reached. Your limit will reset at 3pm.\n'; exit 0 ;;
  error)   printf '{"is_error":true,"result":"stub failure"}\n'; exit 1 ;;
  auth)    printf '%s\n' '{"is_error":true,"duration_api_ms":0,"stop_reason":"stop_sequence","total_cost_usd":0,"terminal_reason":"api_error","result":"Failed to authenticate: OAuth session expired and could not be refreshed","type":"result"}'; exit 1 ;;
  flaky)
    if [ ! -f "$STUB_FLAG" ]; then
      printf 'x' >"$STUB_FLAG"
      printf '{"is_error":true,"result":"transient"}\n'; exit 1
    fi
    printf '{"is_error":false,"result":"ok"}\n'; exit 0 ;;
  *) printf '{"is_error":false,"result":"ok","usage":{"input_tokens":167}}\n'; exit 0 ;;
esac
'@
        # LF only: CRLF would break the shebang.
        [IO.File]::WriteAllText($stub, ($body -replace "`r`n", "`n"))
        & chmod +x $stub
    }

    $env:STUB_LOG                    = $script:StubLog
    $env:STUB_FLAG                   = $script:StubFlag
    $env:STUB_MODE                   = 'ok'
    $env:KEEPWARM_HOME               = Join-Path $script:Sandbox 'home'
    $env:KEEPWARM_ACTIVITY_DIR       = Join-Path $script:Sandbox 'activity'
    $env:KEEPWARM_CLAUDE_BIN         = $stub
    $env:KEEPWARM_PING_ATTEMPTS      = '2'
    $env:KEEPWARM_PING_RETRY_DELAY   = '0'
}

function Remove-Sandbox {
    foreach ($v in 'STUB_LOG','STUB_FLAG','STUB_MODE','KEEPWARM_HOME','KEEPWARM_ACTIVITY_DIR',
                   'KEEPWARM_CLAUDE_BIN','KEEPWARM_PING_ATTEMPTS','KEEPWARM_PING_RETRY_DELAY') {
        Remove-Item -Path "Env:$v" -ErrorAction SilentlyContinue
    }
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Run keepwarm.ps1 in a child process so it gets a clean $PID for lock tests.
function Invoke-Kw {
    param([string[]]$KwArgs)
    & $Ps -NoProfile -ExecutionPolicy Bypass -File $Kw @KwArgs 2>&1 | Out-String | Out-Null
    $LASTEXITCODE
}

function Get-Calls {
    if (-not (Test-Path -LiteralPath $script:StubLog)) { return 0 }
    @(Get-Content -LiteralPath $script:StubLog | Where-Object { $_ -match '\S' }).Count
}

function Get-StateValue {
    param([string]$Key)
    $f = Join-Path $env:KEEPWARM_HOME 'state\window.env'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    foreach ($line in Get-Content -LiteralPath $f) {
        if ($line -match "^$Key=(.*)$") { return $Matches[1] }
    }
    ''
}

function Get-LogText {
    $f = Join-Path $env:KEEPWARM_HOME 'logs\keepwarm.log'
    if (Test-Path -LiteralPath $f) { (Get-Content -LiteralPath $f) -join "`n" } else { '' }
}

function Set-StateWindow {
    param([long]$StartEpoch)
    $dir = Join-Path $env:KEEPWARM_HOME 'state'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        "WINDOW_START=$StartEpoch"
        "WINDOW_END=$($StartEpoch + 18000)"
        "LAST_PING=$StartEpoch"
        'LAST_STATUS=ok'
    ) | Set-Content -LiteralPath (Join-Path $dir 'window.env') -Encoding ASCII
}

function Get-HoursAgoBoundary {
    param([int]$Hours)
    $d = (Get-Date).AddHours(-$Hours)
    [long]([DateTimeOffset]::new($d.Date.AddHours($d.Hour))).ToUnixTimeSeconds()
}

function Add-Failure {
    param([string]$Message)
    $script:Fail++
    $script:Failures += "$($script:Current): $Message"
    Write-Host ("  FAIL {0}" -f $script:Current) -ForegroundColor Red
    Write-Host ("       {0}" -f $Message)
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = 'assertion')
    if ("$Expected" -ne "$Actual") { Add-Failure "${Message}: expected [$Expected], got [$Actual]" }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message = 'assertion')
    if ($Text -notmatch $Pattern) { Add-Failure "${Message}: expected to match /$Pattern/" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    if ($Filter -and $Name -notlike "*$Filter*") { return }
    $script:Current = $Name
    New-Sandbox
    $before = $script:Fail
    try { & $Body } catch { Add-Failure "threw: $($_.Exception.Message)" }
    if ($script:Fail -eq $before) {
        $script:Pass++
        Write-Host ("  ok   {0}" -f $Name) -ForegroundColor Green
    }
    Remove-Sandbox
}

# ------------------------------------------------------------------- tests --

Write-Host ("keepwarm tests  (PowerShell {0}, {1})`n" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)

Invoke-Test 'ping_opens_window_on_the_hour' {
    Invoke-Kw @('ping') | Out-Null
    $start = [long](Get-StateValue 'WINDOW_START')
    $end   = [long](Get-StateValue 'WINDOW_END')
    Assert-Equal 1 (Get-Calls) 'claude called exactly once'
    Assert-Equal 'ok' (Get-StateValue 'LAST_STATUS') 'status recorded'
    $d = [DateTimeOffset]::FromUnixTimeSeconds($start).ToLocalTime().DateTime
    Assert-Equal '00:00' $d.ToString('mm:ss') 'window start floored to the top of the hour'
    Assert-Equal 18000 ($end - $start) 'window is 5 hours long'
}

Invoke-Test 'run_with_no_state_pings' {
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 1 (Get-Calls) 'first run pings'
    Assert-Match (Get-LogText) 'WINDOW\s+opened' 'logs the new window'
}

Invoke-Test 'run_inside_window_does_not_ping' {
    Invoke-Kw @('run') | Out-Null
    Invoke-Kw @('run') | Out-Null
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 1 (Get-Calls) 'no extra calls while the window is live'
    Assert-Match (Get-LogText) 'WAIT' 'logs a WAIT heartbeat'
}

Invoke-Test 'expired_window_pings_again' {
    Set-StateWindow (Get-HoursAgoBoundary 6)
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 1 (Get-Calls) 'expired window triggers a ping'
    Assert-Equal 'ok' (Get-StateValue 'LAST_STATUS') 'status is ok'
}

Invoke-Test 'rate_limited_leaves_window_untouched' {
    Set-StateWindow (Get-HoursAgoBoundary 6)
    $before = Get-StateValue 'WINDOW_END'
    $env:STUB_MODE = 'limited'
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 'limited' (Get-StateValue 'LAST_STATUS') 'records limited'
    Assert-Equal $before (Get-StateValue 'WINDOW_END') 'window NOT advanced on limit'
    Assert-Match (Get-LogText) 'LIMITED' 'logs the limit'
    Assert-Equal 1 (Get-Calls) 'limited is not retried in-process'
}

Invoke-Test 'error_is_retried_then_recorded' {
    Set-StateWindow (Get-HoursAgoBoundary 6)
    $before = Get-StateValue 'WINDOW_END'
    $env:STUB_MODE = 'error'
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 2 (Get-Calls) 'error retried up to PING_ATTEMPTS'
    Assert-Equal 'error' (Get-StateValue 'LAST_STATUS') 'records error'
    Assert-Equal $before (Get-StateValue 'WINDOW_END') 'window NOT advanced on error'
}

# Reported from a real Windows install: an expired login was retried three
# times over 40s and buried its one-line cause in a 1200-char payload.
Invoke-Test 'auth_failure_is_not_retried' {
    Set-StateWindow (Get-HoursAgoBoundary 6)
    $before = Get-StateValue 'WINDOW_END'
    $env:STUB_MODE = 'auth'
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 1 (Get-Calls) 'auth failure is NOT retried - it is not transient'
    Assert-Equal 'auth' (Get-StateValue 'LAST_STATUS') 'records auth'
    Assert-Equal $before (Get-StateValue 'WINDOW_END') 'window NOT advanced on auth failure'
    Assert-Match (Get-LogText) 'AUTH\s+Failed to authenticate' 'logs the readable cause'
}

Invoke-Test 'transient_error_recovers_within_one_run' {
    Set-StateWindow (Get-HoursAgoBoundary 6)
    $env:STUB_MODE = 'flaky'
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 2 (Get-Calls) 'second attempt made'
    Assert-Equal 'ok' (Get-StateValue 'LAST_STATUS') 'recovers without waiting an hour'
    Assert-Match (Get-LogText) 'RETRY' 'logs the retry'
}

Invoke-Test 'skips_ping_when_user_was_active' {
    $start = Get-HoursAgoBoundary 6
    Set-StateWindow $start
    $f = Join-Path $env:KEEPWARM_ACTIVITY_DIR 'session.jsonl'
    New-Item -ItemType File -Force -Path $f | Out-Null
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 0 (Get-Calls) 'no ping spent when already active'
    Assert-Equal 'skipped' (Get-StateValue 'LAST_STATUS') 'records skip'
    Assert-Equal ($start + 18000) (Get-StateValue 'WINDOW_START') 'window advances to the old boundary'
}

Invoke-Test 'stale_activity_does_not_skip' {
    $start = Get-HoursAgoBoundary 6
    Set-StateWindow $start
    $f = Join-Path $env:KEEPWARM_ACTIVITY_DIR 'session.jsonl'
    New-Item -ItemType File -Force -Path $f | Out-Null
    (Get-Item -LiteralPath $f).LastWriteTime =
        [DateTimeOffset]::FromUnixTimeSeconds($start - 3600).ToLocalTime().DateTime
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 1 (Get-Calls) 'stale activity still pings'
}

Invoke-Test 'live_lock_blocks_concurrent_run' {
    $lock = Join-Path $env:KEEPWARM_HOME 'state\keepwarm.lock.d'
    New-Item -ItemType Directory -Force -Path $lock | Out-Null
    # This test process is definitely alive.
    Set-Content -LiteralPath (Join-Path $lock 'pid') -Value $PID -Encoding ASCII
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 0 (Get-Calls) 'does not run while another instance holds the lock'
    Assert-Match (Get-LogText) 'SKIP\s+another keepwarm' 'logs the contention'
}

Invoke-Test 'stale_lock_is_reclaimed' {
    $lock = Join-Path $env:KEEPWARM_HOME 'state\keepwarm.lock.d'
    New-Item -ItemType Directory -Force -Path $lock | Out-Null
    Set-Content -LiteralPath (Join-Path $lock 'pid') -Value '999999' -Encoding ASCII
    Invoke-Kw @('run') | Out-Null
    Assert-Equal 1 (Get-Calls) 'reclaims a lock whose owner died'
}

Invoke-Test 'lock_released_after_run' {
    Invoke-Kw @('run') | Out-Null
    $lock = Join-Path $env:KEEPWARM_HOME 'state\keepwarm.lock.d'
    if (Test-Path -LiteralPath $lock) { Add-Failure 'lock directory left behind after a normal run' }
}

Invoke-Test 'read_only_commands_make_no_calls' {
    Invoke-Kw @('version') | Out-Null
    Invoke-Kw @('config')  | Out-Null
    Invoke-Kw @('status')  | Out-Null
    Assert-Equal 0 (Get-Calls) 'read-only commands make no API calls'
}

Invoke-Test 'doctor_fails_without_task' {
    Invoke-Kw @('ping') | Out-Null
    $rc = Invoke-Kw @('doctor')
    if ($rc -eq 0) { Add-Failure 'doctor should exit non-zero when the task is missing' }
}

Invoke-Test 'dry_run_makes_no_call' {
    Invoke-Kw @('ping', '--dry-run') | Out-Null
    Assert-Equal 0 (Get-Calls) '--dry-run does not call claude'
}

# -------------------------------------------------------------------- main --

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "    - $_" }
    exit 1
}
exit 0
