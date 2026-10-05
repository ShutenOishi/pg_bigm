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
$pgRepack = Join-Path $PgRoot "bin\pg_repack.exe"

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
FROM generate_series(1, 30000) AS g;

DELETE FROM public.pgextwin_repack_probe
WHERE id % 3 = 0;

ANALYZE public.pgextwin_repack_probe;
'@ | Set-Content -Path $setupSql -Encoding utf8

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -f $setupSql
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "pg_repack setup SQL failed."
    }

    $beforeCount = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM public.pgextwin_repack_probe;") | Select-Object -Last 1).Trim()
    $beforeNode = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT pg_relation_filenode('public.pgextwin_repack_probe'::regclass);") | Select-Object -Last 1).Trim()

    if ($beforeCount -ne "20000") {
        throw "Unexpected row count before repack: $beforeCount"
    }
    if ([string]::IsNullOrWhiteSpace($beforeNode)) {
        throw "Could not determine relation filenode before repack."
    }

    $oldPath = $env:PATH
    try {
        $env:PATH = (Join-Path $PgRoot "bin") + ";" + $oldPath

        $repackArgs = @(
            "-h", "127.0.0.1",
            "-p", [string]$PgPort,
            "-U", "postgres",
            "-d", "postgres",
            "-w",
            "--table", "public.pgextwin_repack_probe",
            "--no-order",
            "--jobs", "2",
            "--no-analyze"
        )

        & $pgRepack @repackArgs

        if ($LASTEXITCODE -ne 0) {
            Show-PostgresLog
            throw "pg_repack.exe failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        $env:PATH = $oldPath
    }

    $afterCount = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM public.pgextwin_repack_probe;") | Select-Object -Last 1).Trim()
    $afterNode = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT pg_relation_filenode('public.pgextwin_repack_probe'::regclass);") | Select-Object -Last 1).Trim()

    if ($afterCount -ne $beforeCount) {
        throw "Row count changed during repack. Before=$beforeCount After=$afterCount"
    }
    if ($afterNode -eq $beforeNode) {
        throw "Relation filenode did not change; actual table replacement was not demonstrated."
    }

    $extensionVersion = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_repack';") | Select-Object -Last 1).Trim()
    if ($extensionVersion -ne "1.5.3") {
        throw "Unexpected installed pg_repack extension version: $extensionVersion"
    }

    Write-Host "pg_repack functional test passed: rows=$afterCount, filenode $beforeNode -> $afterNode"

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
