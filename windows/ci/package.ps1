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

$assetName = "pgaudit-$UpstreamRef-pg$PostgreSqlMajor-windows-x64"
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

Copy-Item (Join-Path $UpstreamDir "pgaudit.dll") (Join-Path $stage "lib\pgaudit.dll")
Copy-Item (Join-Path $UpstreamDir "pgaudit.control") (Join-Path $stage "share\extension\pgaudit.control")
Copy-Item (Join-Path $UpstreamDir "pgaudit--*.sql") (Join-Path $stage "share\extension\")
Copy-Item (Join-Path $UpstreamDir "LICENSE") (Join-Path $stage "LICENSE")
Copy-Item (Join-Path $UpstreamDir "README.md") (Join-Path $stage "UPSTREAM-README.md")
if (Test-Path (Join-Path $UpstreamDir "pgaudit.conf")) {
    Copy-Item (Join-Path $UpstreamDir "pgaudit.conf") (Join-Path $stage "UPSTREAM-pgaudit.conf")
}

$upstreamSha = (& git -C $UpstreamDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamSha)) {
    throw "Failed to resolve the pinned upstream commit SHA."
}

@"
pgAudit Windows binary package
==============================

Upstream repository: $UpstreamRepository
Upstream ref:        $UpstreamRef
Upstream commit:     $upstreamSha
pgAudit version:     $UpstreamVersion
PostgreSQL major:    $PostgreSqlMajor
PostgreSQL tested:   $PostgreSqlMinor
Architecture:        Windows x64
Compiler:            MSVC
License:             PostgreSQL license; see LICENSE

This is an unofficial pgextwin probe package built from the official pgAudit source.
pgAudit must be loaded through shared_preload_libraries before CREATE EXTENSION.
"@ | Set-Content -Path (Join-Path $stage "PACKAGE-INFO.txt") -Encoding utf8

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal

if (-not (Test-Path $zipPath)) {
    throw "Expected package was not produced: $zipPath"
}
