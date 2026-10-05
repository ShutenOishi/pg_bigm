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
$dataDir = Join-Path $tempRoot "pg_cron-pg$PostgreSqlMajor-data"
$logFile = Join-Path $tempRoot "pg_cron-pg$PostgreSqlMajor.log"
$setupSql = Join-Path $tempRoot "pg_cron-setup.sql"

if (Test-Path $dataDir) {
    Remove-Item $dataDir -Recurse -Force
}

& $initdb -D $dataDir -U postgres -A trust --encoding=UTF8 --no-locale
if ($LASTEXITCODE -ne 0) {
    throw "initdb failed."
}

function Show-PostgresLog {
    if (Test-Path $logFile) {
        Write-Host "----- PostgreSQL log -----"
        Get-Content $logFile -Tail 250
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
    $serverOptions = "-p $PgPort -c shared_preload_libraries=pg_cron -c cron.database_name=postgres -c cron.use_background_workers=on -c max_worker_processes=20"

    & $pgCtl -D $dataDir -l $logFile -o $serverOptions start
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "Failed to start PostgreSQL with pg_cron preloaded."
    }

    Wait-Postgres

    @'
CREATE EXTENSION pg_cron;
DROP TABLE IF EXISTS public.pgextwin_cron_probe;
CREATE TABLE public.pgextwin_cron_probe (
    id integer PRIMARY KEY,
    executed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
SELECT cron.schedule(
    'pgextwin-ci',
    '1 second',
    'INSERT INTO public.pgextwin_cron_probe(id) VALUES (1) ON CONFLICT (id) DO NOTHING'
);
'@ | Set-Content -Path $setupSql -Encoding utf8

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -f $setupSql
    if ($LASTEXITCODE -ne 0) {
        throw "CREATE EXTENSION or cron.schedule setup failed."
    }

    $executed = $false
    for ($i = 0; $i -lt 30; $i++) {
        $count = (
            & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM public.pgextwin_cron_probe;"
        ) | Select-Object -Last 1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to query the pg_cron probe table."
        }

        if (([string]$count).Trim() -eq "1") {
            $executed = $true
            break
        }

        Start-Sleep -Seconds 2
    }

    if (-not $executed) {
        Show-PostgresLog
        throw "pg_cron scheduled job did not execute within the expected window."
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT cron.unschedule('pgextwin-ci'); DROP TABLE public.pgextwin_cron_probe; DROP EXTENSION pg_cron;"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_cron smoke-test cleanup failed."
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
