[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRepository,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRef,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamVersion,

    [Parameter(Mandatory = $true)]
    [int]$PostgreSqlMajor,

    [Parameter(Mandatory = $true)]
    [string]$PostgreSqlMinor,

    [string]$DistDir = "dist"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$assetName = "pg_hint_plan-$UpstreamRef-pg$PostgreSqlMajor-windows-x64"
$stage = Join-Path $DistDir $assetName
$zipPath = Join-Path $DistDir "$assetName.zip"

if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $stage "lib") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "share\extension") | Out-Null

Copy-Item (Join-Path $UpstreamDir "pg_hint_plan.dll") (Join-Path $stage "lib\pg_hint_plan.dll")
Copy-Item (Join-Path $UpstreamDir "pg_hint_plan.control") (Join-Path $stage "share\extension\pg_hint_plan.control")
Copy-Item (Join-Path $UpstreamDir "pg_hint_plan--*.sql") (Join-Path $stage "share\extension\")
Copy-Item (Join-Path $UpstreamDir "COPYRIGHT") (Join-Path $stage "COPYRIGHT")
Copy-Item (Join-Path $UpstreamDir "COPYRIGHT.postgresql") (Join-Path $stage "COPYRIGHT.postgresql")
Copy-Item (Join-Path $UpstreamDir "README.md") (Join-Path $stage "UPSTREAM-README.md")

$upstreamSha = (& git -C $UpstreamDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamSha)) {
    throw "Failed to resolve the pinned upstream commit SHA."
}

@"
pg_hint_plan Windows binary package
===================================

Upstream repository: $UpstreamRepository
Upstream ref:        $UpstreamRef
Upstream commit:     $upstreamSha
pg_hint_plan version: $UpstreamVersion
PostgreSQL major:    $PostgreSqlMajor
PostgreSQL tested:   $PostgreSqlMinor
Architecture:        Windows x64
Compiler:            MSVC
License files:       COPYRIGHT, COPYRIGHT.postgresql

This is an unofficial pgextwin probe package built from the official pg_hint_plan source.
"@ | Set-Content -Path (Join-Path $stage "PACKAGE-INFO.txt") -Encoding utf8

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal

if (-not (Test-Path $zipPath)) {
    throw "Expected package was not produced: $zipPath"
}
