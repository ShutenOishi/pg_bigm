[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir,

    [string]$BuildDir = "build"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dll = Join-Path $BuildDir "Release\pg_bigm.dll"
$control = Join-Path $UpstreamDir "pg_bigm.control"
$sqlPattern = Join-Path $UpstreamDir "pg_bigm--*.sql"
$extensionDir = Join-Path $PgRoot "share\extension"

if (-not (Test-Path $dll)) {
    throw "Built DLL was not found: $dll"
}

if (-not (Test-Path $control)) {
    throw "Extension control file was not found: $control"
}

Copy-Item $dll (Join-Path $PgRoot "lib\pg_bigm.dll") -Force
Copy-Item $control (Join-Path $extensionDir "pg_bigm.control") -Force
Copy-Item $sqlPattern $extensionDir -Force
