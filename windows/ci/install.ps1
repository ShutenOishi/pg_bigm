[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$meta = Get-Content (Join-Path $UpstreamDir "META.json") -Raw | ConvertFrom-Json
$version = [string]$meta.version

$dll = Join-Path $UpstreamDir "pg_repack.dll"
$exe = Join-Path $UpstreamDir "pg_repack.exe"
$control = Join-Path $UpstreamDir "lib\pg_repack.control"
$sql = Join-Path $UpstreamDir "lib\pg_repack--$version.sql"
$extensionDir = Join-Path $PgRoot "share\extension"

foreach ($path in @($dll, $exe, $control, $sql)) {
    if (-not (Test-Path $path)) {
        throw "Required pg_repack file was not found: $path"
    }
}

Copy-Item $dll (Join-Path $PgRoot "lib\pg_repack.dll") -Force
Copy-Item $exe (Join-Path $PgRoot "bin\pg_repack.exe") -Force
Copy-Item $control (Join-Path $extensionDir "pg_repack.control") -Force
Copy-Item $sql (Join-Path $extensionDir "pg_repack--$version.sql") -Force
