[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dll = Join-Path $UpstreamDir "pg_cron.dll"
$control = Join-Path $UpstreamDir "pg_cron.control"
$baseSql = Join-Path $UpstreamDir "pg_cron--1.0.sql"
$upgradeSql = Join-Path $UpstreamDir "pg_cron--*--*.sql"
$extensionDir = Join-Path $PgRoot "share\extension"

foreach ($path in @($dll, $control, $baseSql)) {
    if (-not (Test-Path $path)) {
        throw "Required pg_cron file was not found: $path"
    }
}

Copy-Item $dll (Join-Path $PgRoot "lib\pg_cron.dll") -Force
Copy-Item $control (Join-Path $extensionDir "pg_cron.control") -Force
Copy-Item $baseSql (Join-Path $extensionDir "pg_cron--1.0.sql") -Force
Copy-Item $upgradeSql $extensionDir -Force
