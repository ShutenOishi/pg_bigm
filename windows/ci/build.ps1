[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir,

    [string]$BuildDir = "build"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

cmake -S . -B $BuildDir -A x64 "-DPGROOT=$PgRoot" "-DUPSTREAM_DIR=$UpstreamDir"
if ($LASTEXITCODE -ne 0) {
    throw "CMake configure failed."
}

cmake --build $BuildDir --config Release
if ($LASTEXITCODE -ne 0) {
    throw "CMake build failed."
}

$dll = Join-Path $BuildDir "Release\pg_bigm.dll"
if (-not (Test-Path $dll)) {
    throw "Expected pg_bigm.dll was not produced: $dll"
}
