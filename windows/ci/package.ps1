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

    [string]$BuildDir = "build",

    [string]$DistDir = "dist"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$assetName = "pg_bigm-$UpstreamRef-pg$PostgreSqlMajor-windows-x64"
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
New-Item -ItemType Directory -Force -Path (Join-Path $stage "docs") | Out-Null

Copy-Item (Join-Path $BuildDir "Release\pg_bigm.dll") (Join-Path $stage "lib\pg_bigm.dll")
Copy-Item (Join-Path $UpstreamDir "pg_bigm.control") (Join-Path $stage "share\extension\pg_bigm.control")
Copy-Item (Join-Path $UpstreamDir "pg_bigm--*.sql") (Join-Path $stage "share\extension\")
Copy-Item (Join-Path $UpstreamDir "LICENSE") (Join-Path $stage "LICENSE")
Copy-Item (Join-Path $UpstreamDir "README.md") (Join-Path $stage "UPSTREAM-README.md")

$japaneseDoc = Join-Path $UpstreamDir "docs\pg_bigm.md"
$englishDoc = Join-Path $UpstreamDir "docs\pg_bigm_en.md"

if (Test-Path $japaneseDoc) {
    Copy-Item $japaneseDoc (Join-Path $stage "docs\pg_bigm.md")
}
if (Test-Path $englishDoc) {
    Copy-Item $englishDoc (Join-Path $stage "docs\pg_bigm_en.md")
}

$upstreamSha = (& git -C $UpstreamDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamSha)) {
    throw "Failed to resolve the pinned upstream commit SHA."
}

@"
pg_bigm Windows binary package
=================================

Upstream repository: $UpstreamRepository
Upstream ref:        $UpstreamRef
Upstream commit:     $upstreamSha
pg_bigm version:     $UpstreamVersion
PostgreSQL major:    $PostgreSqlMajor
PostgreSQL tested:   $PostgreSqlMinor
Architecture:        Windows x64
Compiler:            MSVC (GitHub-hosted windows-latest)
License:             PostgreSQL License; see LICENSE

This is an unofficial Windows binary package.
The pg_bigm upstream documentation is authoritative.
"@ | Set-Content -Path (Join-Path $stage "PACKAGE-INFO.txt") -Encoding utf8

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal

if (-not (Test-Path $zipPath)) {
    throw "Expected package was not produced: $zipPath"
}

Write-Host "Created package: $zipPath"
