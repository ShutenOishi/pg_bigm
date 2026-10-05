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
$dataDir = Join-Path $tempRoot "pg_bigm-pg$PostgreSqlMajor-data"
$logFile = Join-Path $tempRoot "pg_bigm-pg$PostgreSqlMajor.log"

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
        Get-Content $logFile -Tail 200
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
    & $pgCtl -D $dataDir -l $logFile -o "-p $PgPort -c shared_preload_libraries=pg_bigm" start
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "Failed to start temporary PostgreSQL cluster."
    }

    Wait-Postgres

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP EXTENSION IF EXISTS pg_bigm CASCADE;"
    if ($LASTEXITCODE -ne 0) {
        throw "DROP EXTENSION pre-clean failed."
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_bigm;"
    if ($LASTEXITCODE -ne 0) {
        throw "CREATE EXTENSION pg_bigm failed."
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP TABLE IF EXISTS ci_bigm; CREATE TABLE ci_bigm(v text); INSERT INTO ci_bigm VALUES ('abcdef'), ('uvwxyz'); CREATE INDEX ci_bigm_idx ON ci_bigm USING gin (v gin_bigm_ops);"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_bigm GIN index setup failed."
    }

    $count = (
        & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SET enable_seqscan=off; SELECT count(*) FROM ci_bigm WHERE v LIKE likequery('bcd');"
    ) | Select-Object -Last 1

    $countText = ([string]$count).Trim()
    if ($LASTEXITCODE -ne 0 -or $countText -ne "1") {
        throw "pg_bigm search smoke test failed. Expected 1 row, got '$countText'."
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP TABLE ci_bigm; DROP EXTENSION pg_bigm;"
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke-test cleanup failed."
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
