[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
$vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe was not found: $vswhere"
}

$vsRoot = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($vsRoot)) {
    throw "Visual Studio with the C++ x64 toolchain was not found."
}

$vsDevCmd = Join-Path $vsRoot "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path $vsDevCmd)) {
    throw "VsDevCmd.bat was not found: $vsDevCmd"
}

$controlPath = Join-Path $UpstreamDir "set_user.control"
$sourcePath = Join-Path $UpstreamDir "src\set_user.c"
$baseTemplate = Join-Path $UpstreamDir "extension\set_user.sql"

$control = Get-Content $controlPath -Raw
if ($control -notmatch "default_version\s*=\s*'([^']+)'") {
    throw "Could not determine set_user version from set_user.control."
}
$extVersion = $Matches[1]

$source = Get-Content $sourcePath -Raw
$prototype = 'extern Datum set_user(PG_FUNCTION_ARGS);'
$exportPrototype = 'extern PGDLLEXPORT Datum set_user(PG_FUNCTION_ARGS);'

if (-not $source.Contains($prototype) -and -not $source.Contains($exportPrototype)) {
    throw "Expected set_user prototype was not found; review upstream before continuing."
}

if ($source.Contains($prototype)) {
    $source = $source.Replace($prototype, $exportPrototype)
    Set-Content -Path $sourcePath -Value $source -Encoding utf8
    Write-Host "Applied Windows linkage compatibility patch to set_user prototype."
}

$source = Get-Content $sourcePath -Raw
$exports = @("Pg_magic_func", "_PG_init", "_PG_fini")
foreach ($match in [regex]::Matches($source, 'PG_FUNCTION_INFO_V1\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)')) {
    $exports += $match.Groups[1].Value
}
$exports = @($exports | Sort-Object -Unique)

$defPath = Join-Path $UpstreamDir "set_user.pgextwin.def"
(@("LIBRARY set_user", "EXPORTS") + @($exports | ForEach-Object { "    $_" })) |
    Set-Content -Path $defPath -Encoding ascii

$baseSql = Join-Path $UpstreamDir "extension\set_user--$extVersion.sql"
Copy-Item $baseTemplate $baseSql -Force

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$cmdFile = Join-Path $tempRoot "set_user-build.cmd"

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cd /d "$UpstreamDir"

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DEXTVERSION=\""$extVersion\"" ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir\src" ^
  /c "$sourcePath" /Fo"$UpstreamDir\set_user.obj"
if errorlevel 1 exit /b %errorlevel%

link /nologo /DLL /OUT:"$UpstreamDir\set_user.dll" /DEF:"$defPath" ^
  "$UpstreamDir\set_user.obj" ^
  "$PgRoot\lib\postgres.lib" ^
  "$PgRoot\lib\libintl.lib"
if errorlevel 1 exit /b %errorlevel%
"@ | Set-Content -Path $cmdFile -Encoding ascii

& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) {
    throw "set_user MSVC build failed with exit code $LASTEXITCODE."
}

$dll = Join-Path $UpstreamDir "set_user.dll"
if (-not (Test-Path $dll)) {
    throw "Expected set_user.dll was not produced: $dll"
}
if (-not (Test-Path $baseSql)) {
    throw "Expected generated extension SQL was not produced: $baseSql"
}

Write-Host "Built set_user $extVersion with exports: $($exports -join ', ')"
