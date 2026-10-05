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
$header = Join-Path $UpstreamDir "src\set_user.h"

$controlText = Get-Content $control -Raw
if ($controlText -notmatch "default_version\s*=\s*'([^']+)'") {
    throw "Could not determine set_user version from set_user.control."
}
$extVersion = $Matches[1]

$baseSql = Join-Path $UpstreamDir "extension\set_user--$extVersion.sql"
$extensionDir = Join-Path $PgRoot "share\extension"

foreach ($path in @($dll, $control, $header, $baseSql)) {
    if (-not (Test-Path $path)) {
        throw "Required set_user file was not found: $path"
    }
}

Copy-Item $dll (Join-Path $PgRoot "lib\set_user.dll") -Force
Copy-Item $control (Join-Path $extensionDir "set_user.control") -Force
Copy-Item $baseSql (Join-Path $extensionDir "set_user--$extVersion.sql") -Force

$updateScripts = @(Get-ChildItem (Join-Path $UpstreamDir "updates") -Filter "*.sql" -File -ErrorAction SilentlyContinue)
foreach ($script in $updateScripts) {
    Copy-Item $script.FullName (Join-Path $extensionDir $script.Name) -Force
}

Copy-Item $header (Join-Path $PgRoot "include\set_user.h") -Force
