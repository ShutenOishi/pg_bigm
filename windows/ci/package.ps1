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

$assetName = "pg_repack-$UpstreamRef-pg$PostgreSqlMajor-windows-x64"
$stage = Join-Path $DistDir $assetName
$zipPath = Join-Path $DistDir "$assetName.zip"

if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $stage "bin") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "lib") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "share\extension") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "docs") | Out-Null

Copy-Item (Join-Path $UpstreamDir "pg_repack.exe") (Join-Path $stage "bin\pg_repack.exe")
Copy-Item (Join-Path $UpstreamDir "pg_repack.dll") (Join-Path $stage "lib\pg_repack.dll")
Copy-Item (Join-Path $UpstreamDir "lib\pg_repack.control") (Join-Path $stage "share\extension\pg_repack.control")
Copy-Item (Join-Path $UpstreamDir "lib\pg_repack--*.sql") (Join-Path $stage "share\extension\")
Copy-Item (Join-Path $UpstreamDir "COPYRIGHT") (Join-Path $stage "COPYRIGHT")
Copy-Item (Join-Path $UpstreamDir "README.rst") (Join-Path $stage "UPSTREAM-README.rst")

foreach ($doc in @("pg_repack.rst", "pg_repack_jp.rst")) {
    $source = Join-Path $UpstreamDir "doc\$doc"
    if (Test-Path $source) {
        Copy-Item $source (Join-Path $stage "docs\$doc")
    }
}

$upstreamSha = (& git -C $UpstreamDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamSha)) {
    throw "Failed to resolve the pinned upstream commit SHA."
}

@"
pg_repack Windows binary package
================================

Upstream repository: $UpstreamRepository
Upstream ref:        $UpstreamRef
Upstream commit:     $upstreamSha
pg_repack version:   $UpstreamVersion
PostgreSQL major:    $PostgreSqlMajor
PostgreSQL tested:   $PostgreSqlMinor
Architecture:        Windows x64
Compiler:            MSVC
License:             see COPYRIGHT

This is an unofficial pgextwin probe package built from the official pg_repack source.

The package contains both components required by pg_repack:
- bin/pg_repack.exe
- lib/pg_repack.dll

Install the extension files into the matching PostgreSQL installation and run
CREATE EXTENSION pg_repack in each database that will be processed.
"@ | Set-Content -Path (Join-Path $stage "PACKAGE-INFO.txt") -Encoding utf8

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal

if (-not (Test-Path $zipPath)) {
    throw "Expected package was not produced: $zipPath"
}

Write-Host "Created package: $zipPath"
