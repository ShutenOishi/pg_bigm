[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [int]$PgPort,

    [Parameter(Mandatory = $true)]
    [int]$PostgreSqlMajor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$initdb = Join-Path $PgRoot "bin\initdb.exe"
$pgCtl = Join-Path $PgRoot "bin\pg_ctl.exe"
$pgIsReady = Join-Path $PgRoot "bin\pg_isready.exe"
$psql = Join-Path $PgRoot "bin\psql.exe"

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$dataDir = Join-Path $tempRoot "set_user-pg$PostgreSqlMajor-data"
$logFile = Join-Path $tempRoot "set_user-pg$PostgreSqlMajor.log"
$scriptFile = Join-Path $tempRoot "set_user-probe.sql"

if (Test-Path $dataDir) {
    Remove-Item $dataDir -Recurse -Force
}
if (Test-Path $logFile) {
    Remove-Item $logFile -Force
}

& $initdb -D $dataDir -U postgres -A trust --encoding=UTF8 --no-locale
if ($LASTEXITCODE -ne 0) {
    throw "initdb failed."
}

function Show-PostgresLog {
    if (Test-Path $logFile) {
        Write-Host "----- PostgreSQL log -----"
        Get-Content $logFile -Tail 300
        Write-Host "--------------------------"
    }
}

function Wait-Postgres {
    for ($i = 0; $i -lt 45; $i++) {
        & $pgIsReady -h 127.0.0.1 -p $PgPort -q
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds 2
    }

    Show-PostgresLog
    throw "Temporary PostgreSQL cluster did not become ready."
}

try {
    $serverOptions = "-p $PgPort -c shared_preload_libraries=set_user"

    & $pgCtl -D $dataDir -l $logFile -o $serverOptions start
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "Failed to start PostgreSQL with set_user preloaded."
    }

    Wait-Postgres

    @'
CREATE EXTENSION set_user;
CREATE ROLE pgextwin_set_user_target;
SELECT set_user('pgextwin_set_user_target');
SELECT 'after_set=' || current_user;
SELECT reset_user();
SELECT 'after_reset=' || current_user;
'@ | Set-Content -Path $scriptFile -Encoding utf8

    $output = (
        & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -X -A -t -v ON_ERROR_STOP=1 -f $scriptFile
    ) -join [Environment]::NewLine

    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "set_user functional SQL failed."
    }

    if ($output -notmatch 'after_set=pgextwin_set_user_target') {
        Show-PostgresLog
        throw "set_user did not switch current_user as expected. Output: $output"
    }

    if ($output -notmatch 'after_reset=postgres') {
        Show-PostgresLog
        throw "reset_user did not restore current_user as expected. Output: $output"
    }

    Start-Sleep -Seconds 1
    $log = Get-Content $logFile -Raw

    if ($log -notmatch 'Role postgres transitioning to Role pgextwin_set_user_target') {
        Show-PostgresLog
        throw "set_user transition was not logged."
    }

    if ($log -notmatch 'Role pgextwin_set_user_target transitioning to Role postgres') {
        Show-PostgresLog
        throw "reset_user transition was not logged."
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP EXTENSION set_user; DROP ROLE pgextwin_set_user_target;"
    if ($LASTEXITCODE -ne 0) {
        throw "set_user smoke-test cleanup failed."
    }
}
catch {
    Show-PostgresLog
    throw
}
finally {
    if (Test-Path (Join-Path $dataDir "postmaster.pid")) {
        & $pgCtl -D $dataDir -m fast stop
    }
}
