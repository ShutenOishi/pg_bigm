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

$meta = Get-Content (Join-Path $UpstreamDir "META.json") -Raw | ConvertFrom-Json
$repackVersion = [string]$meta.version
if ($repackVersion -ne "1.5.3") {
    throw "Unexpected pg_repack version: $repackVersion"
}

# Windows frontend compatibility patch 1:
# use the frontend umbrella header instead of backend c.h.
$pgutHeaderPath = Join-Path $UpstreamDir "bin\pgut\pgut.h"
$pgutHeader = Get-Content $pgutHeaderPath -Raw
$oldHeader = '#include "c.h"'
$newHeader = @'
#ifndef WIN32
#include "c.h"
#else
#include "postgres_fe.h"
#endif
'@
if (-not $pgutHeader.Contains($oldHeader)) {
    throw "Expected pgut.h include was not found; review upstream before continuing."
}
$pgutHeader = $pgutHeader.Replace($oldHeader, $newHeader.TrimEnd())
Set-Content -Path $pgutHeaderPath -Value $pgutHeader -Encoding utf8

# Windows frontend compatibility patch 2:
# only include poll/select headers when PostgreSQL configuration says they exist.
$clientPath = Join-Path $UpstreamDir "bin\pg_repack.c"
$clientSource = Get-Content $clientPath -Raw
$oldIncludes = @'
#include <unistd.h>
#include <time.h>
#include <poll.h>
#include <sys/poll.h>
#include <sys/select.h>
'@
$newIncludes = @'
#include <unistd.h>
#include <time.h>

#ifdef HAVE_POLL_H
#include <poll.h>
#endif
#ifdef HAVE_SYS_POLL_H
#include <sys/poll.h>
#endif
#ifdef HAVE_SYS_SELECT_H
#include <sys/select.h>
#endif
'@
if (-not $clientSource.Contains($oldIncludes.Trim())) {
    throw "Expected pg_repack.c poll/select include block was not found; review upstream before continuing."
}
$clientSource = $clientSource.Replace($oldIncludes.Trim(), $newIncludes.Trim())
Set-Content -Path $clientPath -Value $clientSource -Encoding utf8

# Windows frontend compatibility patch 3:
# initialize the cancel critical section before the two lock sites.
$pgutPath = Join-Path $UpstreamDir "bin\pgut\pgut.c"
$pgutSource = Get-Content $pgutPath -Raw
$lockNeedle = @'
#ifdef WIN32
	EnterCriticalSection(&cancelConnLock);
#endif
'@
$lockReplacement = @'
#ifdef WIN32
	init_cancel_handler();
	EnterCriticalSection(&cancelConnLock);
#endif
'@
$lockCount = ([regex]::Matches($pgutSource, [regex]::Escape($lockNeedle.Trim()))).Count
if ($lockCount -ne 2) {
    throw "Expected exactly two Windows cancel-lock sites, found $lockCount; review upstream before continuing."
}
$pgutSource = $pgutSource.Replace($lockNeedle.Trim(), $lockReplacement.Trim())
Set-Content -Path $pgutPath -Value $pgutSource -Encoding utf8

# Generate extension metadata like the upstream Makefile (PG12+ uses false
# instead of the removed relhasoids catalog column).
$controlTemplate = Get-Content (Join-Path $UpstreamDir "lib\pg_repack.control.in") -Raw
$controlTemplate.Replace("REPACK_VERSION", $repackVersion) |
    Set-Content (Join-Path $UpstreamDir "lib\pg_repack.control") -Encoding utf8

$sqlTemplate = Get-Content (Join-Path $UpstreamDir "lib\pg_repack.sql.in") -Raw
$sqlTemplate.Replace("REPACK_VERSION", $repackVersion).Replace("relhasoids", "false") |
    Set-Content (Join-Path $UpstreamDir "lib\pg_repack--$repackVersion.sql") -Encoding utf8

# Upstream ships the canonical DLL export list.
$defLines = @("LIBRARY pg_repack", "EXPORTS")
foreach ($line in Get-Content (Join-Path $UpstreamDir "lib\exports.txt")) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "") {
        continue
    }

    $name = ($trimmed -split '\s+')[0]
    $defLines += "    $name"
}
$defPath = Join-Path $UpstreamDir "lib\pg_repack.pgextwin.def"
$defLines | Set-Content $defPath -Encoding ascii

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$cmdFile = Join-Path $tempRoot "pg_repack-build.cmd"

$serverIncludeArgs = @(
    "$PgRoot\include\server\port\win32_msvc",
    "$PgRoot\include\server\port\win32",
    "$PgRoot\include\server",
    "$PgRoot\include",
    "$UpstreamDir\lib",
    "$UpstreamDir\lib\pgut"
) | ForEach-Object { '/I"' + $_ + '"' }
$serverIncludeArgs = $serverIncludeArgs -join " "

$clientIncludeArgs = @(
    "$PgRoot\include\server\port\win32_msvc",
    "$PgRoot\include\server\port\win32",
    "$PgRoot\include\server",
    "$PgRoot\include\internal",
    "$PgRoot\include",
    "$UpstreamDir\bin",
    "$UpstreamDir\bin\pgut"
) | ForEach-Object { '/I"' + $_ + '"' }
$clientIncludeArgs = $clientIncludeArgs -join " "

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cd /d "$UpstreamDir"

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  $serverIncludeArgs ^
  /c "$UpstreamDir\lib\repack.c" /Fo"$UpstreamDir\lib\repack.obj"
if errorlevel 1 exit /b %errorlevel%

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  $serverIncludeArgs ^
  /c "$UpstreamDir\lib\pgut\pgut-spi.c" /Fo"$UpstreamDir\lib\pgut-spi.obj"
if errorlevel 1 exit /b %errorlevel%

link /nologo /DLL /OUT:"$UpstreamDir\pg_repack.dll" /DEF:"$defPath" ^
  "$UpstreamDir\lib\repack.obj" ^
  "$UpstreamDir\lib\pgut-spi.obj" ^
  "$PgRoot\lib\postgres.lib"
if errorlevel 1 exit /b %errorlevel%

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  $clientIncludeArgs ^
  /c "$UpstreamDir\bin\pg_repack.c" /Fo"$UpstreamDir\bin\pg_repack.obj"
if errorlevel 1 exit /b %errorlevel%

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  $clientIncludeArgs ^
  /c "$UpstreamDir\bin\pgut\pgut.c" /Fo"$UpstreamDir\bin\pgut.obj"
if errorlevel 1 exit /b %errorlevel%

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  $clientIncludeArgs ^
  /c "$UpstreamDir\bin\pgut\pgut-fe.c" /Fo"$UpstreamDir\bin\pgut-fe.obj"
if errorlevel 1 exit /b %errorlevel%

link /nologo /OUT:"$UpstreamDir\pg_repack.exe" ^
  "$UpstreamDir\bin\pg_repack.obj" ^
  "$UpstreamDir\bin\pgut.obj" ^
  "$UpstreamDir\bin\pgut-fe.obj" ^
  "$PgRoot\lib\libpq.lib" ^
  "$PgRoot\lib\libpgport.lib" ^
  "$PgRoot\lib\libpgcommon.lib" ^
  "$PgRoot\lib\libintl.lib" ^
  ws2_32.lib advapi32.lib secur32.lib crypt32.lib
if errorlevel 1 exit /b %errorlevel%
"@ | Set-Content -Path $cmdFile -Encoding ascii

& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) {
    throw "pg_repack MSVC build failed with exit code $LASTEXITCODE."
}

foreach ($output in @(
    (Join-Path $UpstreamDir "pg_repack.dll"),
    (Join-Path $UpstreamDir "pg_repack.exe"),
    (Join-Path $UpstreamDir "lib\pg_repack.control"),
    (Join-Path $UpstreamDir "lib\pg_repack--$repackVersion.sql")
)) {
    if (-not (Test-Path $output)) {
        throw "Expected pg_repack build output was not produced: $output"
    }
}

Write-Host "Built pg_repack $repackVersion server extension and client executable."
