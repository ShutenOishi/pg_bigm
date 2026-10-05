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
$repack = Join-Path $PgRoot "bin\pg_repack.exe"

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$dataDir = Join-Path $tempRoot "pg_repack-pg$PostgreSqlMajor-data"
$logFile = Join-Path $tempRoot "pg_repack-pg$PostgreSqlMajor.log"
$setupSql = Join-Path $tempRoot "pg_repack-pg$PostgreSqlMajor-setup.sql"

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
    & $pgCtl -D $dataDir -l $logFile -o "-p $PgPort" start
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "Failed to start temporary PostgreSQL cluster."
    }

    Wait-Postgres

    @'
CREATE EXTENSION pg_repack;
DROP TABLE IF EXISTS public.pgextwin_repack_probe;
CREATE TABLE public.pgextwin_repack_probe (
    id integer PRIMARY KEY,
    payload text NOT NULL
) WITH (fillfactor = 70);

INSERT INTO public.pgextwin_repack_probe
SELECT g, repeat(md5(g::text), 8)
FROM generate_series(1, 20000) AS g;

DELETE FROM public.pgextwin_repack_probe
WHERE id <= 15000;

ANALYZE public.pgextwin_repack_probe;
'@ | Set-Content -Path $setupSql -Encoding utf8

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -f $setupSql
    if ($LASTEXITCODE -ne 0) {
        throw "pg_repack setup SQL failed."
    }

    $beforeNode = (
        & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT pg_relation_filenode('public.pgextwin_repack_probe'::regclass);"
    ) | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$beforeNode)) {
        throw "Could not read the pre-repack relfilenode."
    }

    $beforeCount = (
        & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM public.pgextwin_repack_probe;"
    ) | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or ([string]$beforeCount).Trim() -ne "5000") {
        throw "Unexpected pre-repack row count: $beforeCount"
    }

    & $repack -h 127.0.0.1 -p $PgPort -U postgres -d postgres --table public.pgextwin_repack_probe --no-order --no-kill-backend
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "pg_repack.exe failed to repack the probe table."
    }

    $afterNode = (
        & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT pg_relation_filenode('public.pgextwin_repack_probe'::regclass);"
    ) | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$afterNode)) {
        throw "Could not read the post-repack relfilenode."
    }

    $afterCount = (
        & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM public.pgextwin_repack_probe;"
    ) | Select-Object -Last 1

    if ($LASTEXITCODE -ne 0 -or ([string]$afterCount).Trim() -ne "5000") {
        throw "Row count changed after pg_repack. Expected 5000, got '$afterCount'."
    }

    if (([string]$beforeNode).Trim() -eq ([string]$afterNode).Trim()) {
        throw "pg_repack completed but the table relfilenode did not change."
    }

    $tempObjects = (
        & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='repack' AND (c.relname LIKE 'table_%' OR c.relname LIKE 'log_%' OR c.relname LIKE 'index_%');"
    ) | Select-Object -Last 1

    if ($LASTEXITCODE -ne 0 -or ([string]$tempObjects).Trim() -ne "0") {
        throw "Temporary pg_repack objects remained after a successful repack: $tempObjects"
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP TABLE public.pgextwin_repack_probe; DROP EXTENSION pg_repack;"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_repack smoke-test cleanup failed."
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
