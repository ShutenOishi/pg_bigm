[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dll = Join-Path $UpstreamDir "set_user.dll"
$control = Join-Path $UpstreamDir "set_user.control"
$extensionDir = Join-Path $PgRoot "share\extension"
$includeDir = Join-Path $PgRoot "include"

foreach ($path in @($dll, $control)) {
    if (-not (Test-Path $path)) {
        throw "Required set_user file was not found: $path"
    }
}

Copy-Item $dll (Join-Path $PgRoot "lib\set_user.dll") -Force
Copy-Item $control (Join-Path $extensionDir "set_user.control") -Force
Copy-Item (Join-Path $UpstreamDir "extension\set_user--*.sql") $extensionDir -Force
Copy-Item (Join-Path $UpstreamDir "updates\set_user--*.sql") $extensionDir -Force
Copy-Item (Join-Path $UpstreamDir "src\set_user.h") (Join-Path $includeDir "set_user.h") -Force
