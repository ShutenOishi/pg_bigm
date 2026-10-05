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
$dataDir = Join-Path $tempRoot "pgaudit-pg$PostgreSqlMajor-data"
$logFile = Join-Path $tempRoot "pgaudit-pg$PostgreSqlMajor.log"
$setupSql = Join-Path $tempRoot "pgaudit-setup.sql"

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
    $serverOptions = "-p $PgPort -c shared_preload_libraries=pgaudit"

    & $pgCtl -D $dataDir -l $logFile -o $serverOptions start
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "Failed to start PostgreSQL with pgAudit preloaded."
    }

    Wait-Postgres

    @'
CREATE EXTENSION pgaudit;
SET pgaudit.log = 'read,write,ddl';
SET pgaudit.log_relation = on;

DROP TABLE IF EXISTS public.pgextwin_pgaudit_probe;
CREATE TABLE public.pgextwin_pgaudit_probe (
    id integer PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO public.pgextwin_pgaudit_probe
VALUES (1, 'pgextwin');
SELECT payload
FROM public.pgextwin_pgaudit_probe
WHERE id = 1;
'@ | Set-Content -Path $setupSql -Encoding utf8

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -f $setupSql
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "pgAudit functional SQL failed."
    }

    Start-Sleep -Seconds 1

    if (-not (Test-Path $logFile)) {
        throw "PostgreSQL log file was not created."
    }

    $log = Get-Content $logFile -Raw

    $requiredPatterns = @(
        'AUDIT:\s+SESSION,[^\r\n]*,DDL,CREATE TABLE,',
        'AUDIT:\s+SESSION,[^\r\n]*,WRITE,INSERT,',
        'AUDIT:\s+SESSION,[^\r\n]*,READ,SELECT,'
    )

    foreach ($pattern in $requiredPatterns) {
        if ($log -notmatch $pattern) {
            Show-PostgresLog
            throw "Required pgAudit log pattern was not found: $pattern"
        }
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SET pgaudit.log = 'none'; DROP TABLE public.pgextwin_pgaudit_probe; DROP EXTENSION pgaudit;"
    if ($LASTEXITCODE -ne 0) {
        throw "pgAudit smoke-test cleanup failed."
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
