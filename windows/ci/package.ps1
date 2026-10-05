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

$assetName = "pg_cron-$UpstreamRef-pg$PostgreSqlMajor-windows-x64"
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

Copy-Item (Join-Path $UpstreamDir "pg_cron.dll") (Join-Path $stage "lib\pg_cron.dll")
Copy-Item (Join-Path $UpstreamDir "pg_cron.control") (Join-Path $stage "share\extension\pg_cron.control")
Copy-Item (Join-Path $UpstreamDir "pg_cron--1.0.sql") (Join-Path $stage "share\extension\pg_cron--1.0.sql")
Copy-Item (Join-Path $UpstreamDir "pg_cron--*--*.sql") (Join-Path $stage "share\extension\")
Copy-Item (Join-Path $UpstreamDir "LICENSE") (Join-Path $stage "LICENSE")
Copy-Item (Join-Path $UpstreamDir "README.md") (Join-Path $stage "UPSTREAM-README.md")
Copy-Item (Join-Path $UpstreamDir "CHANGELOG.md") (Join-Path $stage "UPSTREAM-CHANGELOG.md")

$upstreamSha = (& git -C $UpstreamDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamSha)) {
    throw "Failed to resolve the pinned upstream commit SHA."
}

@"
pg_cron Windows binary package
================================

Upstream repository: $UpstreamRepository
Upstream ref:        $UpstreamRef
Upstream commit:     $upstreamSha
pg_cron release:     $UpstreamVersion
PostgreSQL major:    $PostgreSqlMajor
PostgreSQL tested:   $PostgreSqlMinor
Architecture:        Windows x64
Compiler:            MSVC
License:             PostgreSQL-style license; see LICENSE

This is an unofficial Windows binary package built from the official pg_cron source.
pg_cron requires shared_preload_libraries=pg_cron and must be configured according
to the upstream documentation.
"@ | Set-Content -Path (Join-Path $stage "PACKAGE-INFO.txt") -Encoding utf8

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal

if (-not (Test-Path $zipPath)) {
    throw "Expected package was not produced: $zipPath"
}

Write-Host "Created package: $zipPath"
