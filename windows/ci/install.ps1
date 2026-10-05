[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dll = Join-Path $UpstreamDir "pgaudit.dll"
$control = Join-Path $UpstreamDir "pgaudit.control"
$extensionDir = Join-Path $PgRoot "share\extension"

foreach ($path in @($dll, $control)) {
    if (-not (Test-Path $path)) {
        throw "Required pgAudit file was not found: $path"
    }
}

Copy-Item $dll (Join-Path $PgRoot "lib\pgaudit.dll") -Force
Copy-Item $control (Join-Path $extensionDir "pgaudit.control") -Force
Copy-Item (Join-Path $UpstreamDir "pgaudit--*.sql") $extensionDir -Force
