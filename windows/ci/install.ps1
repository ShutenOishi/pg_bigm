[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dll = Join-Path $UpstreamDir "pg_hint_plan.dll"
$control = Join-Path $UpstreamDir "pg_hint_plan.control"
$extensionDir = Join-Path $PgRoot "share\extension"

foreach ($path in @($dll, $control)) {
    if (-not (Test-Path $path)) {
        throw "Required pg_hint_plan file was not found: $path"
    }
}

Copy-Item $dll (Join-Path $PgRoot "lib\pg_hint_plan.dll") -Force
Copy-Item $control (Join-Path $extensionDir "pg_hint_plan.control") -Force
Copy-Item (Join-Path $UpstreamDir "pg_hint_plan--*.sql") $extensionDir -Force
