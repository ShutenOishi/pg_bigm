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
$testSql = Join-Path $tempRoot "set_user-pg$PostgreSqlMajor-test.sql"
$outputFile = Join-Path $tempRoot "set_user-pg$PostgreSqlMajor-output.txt"

foreach ($path in @($dataDir, $logFile, $testSql, $outputFile)) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
    }
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
\set ON_ERROR_STOP on
CREATE EXTENSION set_user;
CREATE ROLE pgextwin_setuser_target NOLOGIN;
SELECT set_user('pgextwin_setuser_target');
SELECT CASE
         WHEN current_user = 'pgextwin_setuser_target'
          AND session_user = 'postgres'
         THEN 'PGEXTWIN_TARGET_OK'
         ELSE 'PGEXTWIN_TARGET_BAD:' || current_user || ':' || session_user
       END;
SELECT reset_user();
SELECT CASE
         WHEN current_user = 'postgres'
          AND session_user = 'postgres'
         THEN 'PGEXTWIN_RESET_OK'
         ELSE 'PGEXTWIN_RESET_BAD:' || current_user || ':' || session_user
       END;
DROP ROLE pgextwin_setuser_target;
DROP EXTENSION set_user;
'@ | Set-Content -Path $testSql -Encoding utf8

    $output = (& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -At -f $testSql 2>&1)
    $exitCode = $LASTEXITCODE
    $output | Set-Content -Path $outputFile -Encoding utf8
    $outputText = $output -join [Environment]::NewLine

    if ($exitCode -ne 0) {
        Show-PostgresLog
        throw "set_user functional SQL failed. Output: $outputText"
    }

    if ($outputText -notmatch 'PGEXTWIN_TARGET_OK') {
        Show-PostgresLog
        throw "set_user did not transition current_user to the target role. Output: $outputText"
    }

    if ($outputText -notmatch 'PGEXTWIN_RESET_OK') {
        Show-PostgresLog
        throw "reset_user did not restore the original user. Output: $outputText"
    }

    Start-Sleep -Seconds 1

    $log = Get-Content $logFile -Raw
    if ($log -notmatch 'Superuser Role postgres transitioning to Role pgextwin_setuser_target') {
        Show-PostgresLog
        throw "Expected set_user transition log entry was not found."
    }

    if ($log -notmatch 'Role pgextwin_setuser_target transitioning to Superuser Role postgres') {
        Show-PostgresLog
        throw "Expected reset_user transition log entry was not found."
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
