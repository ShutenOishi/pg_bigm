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
$dataDir = Join-Path $tempRoot "pg_hint_plan-pg$PostgreSqlMajor-data"
$logFile = Join-Path $tempRoot "pg_hint_plan-pg$PostgreSqlMajor.log"
$setupSql = Join-Path $tempRoot "pg_hint_plan-setup.sql"

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
    $serverOptions = "-p $PgPort -c shared_preload_libraries=pg_hint_plan"

    & $pgCtl -D $dataDir -l $logFile -o $serverOptions start
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "Failed to start PostgreSQL with pg_hint_plan preloaded."
    }

    Wait-Postgres

    @'
CREATE EXTENSION pg_hint_plan;
DROP TABLE IF EXISTS public.pgextwin_hint_probe;
CREATE TABLE public.pgextwin_hint_probe (
    id integer PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO public.pgextwin_hint_probe
SELECT g, repeat('x', 100)
FROM generate_series(1, 50000) AS g;
ANALYZE public.pgextwin_hint_probe;
'@ | Set-Content -Path $setupSql -Encoding utf8

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -f $setupSql
    if ($LASTEXITCODE -ne 0) {
        throw "pg_hint_plan setup failed."
    }

    $seqPlan = (& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "/*+ SeqScan(pgextwin_hint_probe) */ EXPLAIN (COSTS OFF) SELECT * FROM public.pgextwin_hint_probe WHERE id = 4242;") -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        throw "SeqScan hint EXPLAIN failed."
    }

    if ($seqPlan -notmatch 'Seq Scan on pgextwin_hint_probe') {
        Show-PostgresLog
        throw "SeqScan hint was not applied. Plan: $seqPlan"
    }

    $indexPlan = (& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "/*+ IndexScan(pgextwin_hint_probe pgextwin_hint_probe_pkey) */ EXPLAIN (COSTS OFF) SELECT * FROM public.pgextwin_hint_probe WHERE id = 4242;") -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        throw "IndexScan hint EXPLAIN failed."
    }

    if ($indexPlan -notmatch 'Index Scan using pgextwin_hint_probe_pkey on pgextwin_hint_probe') {
        Show-PostgresLog
        throw "IndexScan hint was not applied. Plan: $indexPlan"
    }

    if ($PostgreSqlMajor -le 16) {
        # PG14-16 pg_hint_plan calls PostgreSQL core JumbleQuery() and
        # EnableQueryId() when the hint-table path is enabled. Those symbols
        # are supplied by the exact-version PostgreSQL source object rebuilt
        # by build.ps1, so exercise that path explicitly.
        $hintTableProbe = (
            & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SET compute_query_id = on; SET pg_hint_plan.enable_hint_table = on; EXPLAIN (COSTS OFF) SELECT * FROM public.pgextwin_hint_probe WHERE id = 4242;"
        ) -join [Environment]::NewLine

        if ($LASTEXITCODE -ne 0) {
            Show-PostgresLog
            throw "pg_hint_plan hint-table compatibility path failed."
        }

        if ($hintTableProbe -notmatch 'Scan') {
            Show-PostgresLog
            throw "Hint-table compatibility path did not produce an execution plan. Output: $hintTableProbe"
        }
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP TABLE public.pgextwin_hint_probe; DROP EXTENSION pg_hint_plan;"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_hint_plan smoke-test cleanup failed."
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
