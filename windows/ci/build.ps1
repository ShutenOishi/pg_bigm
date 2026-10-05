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
if ([string]::IsNullOrWhiteSpace($repackVersion)) {
    throw "Could not determine pg_repack version from META.json."
}

# Apply the two minimal Windows compatibility changes demonstrated by the
# maintained VS2022 community port. The checkout is disposable; pgextwin does
# not vendor or maintain a forked copy of upstream C sources.
$pgutHeader = Join-Path $UpstreamDir "bin\pgut\pgut.h"
$headerText = Get-Content $pgutHeader -Raw
$plainInclude = '#include "c.h"'
$patchedInclude = @'
#ifndef WIN32
#include "c.h"
#else
#include "postgres_fe.h"
#endif
'@

if ($headerText.Contains($plainInclude)) {
    $headerText = $headerText.Replace($plainInclude, $patchedInclude.TrimEnd())
    Set-Content -Path $pgutHeader -Value $headerText -Encoding utf8
    Write-Host "Patched pgut.h to use postgres_fe.h on Windows."
}
elseif (-not $headerText.Contains('#include "postgres_fe.h"')) {
    throw "Expected pgut.h frontend include was not found; review upstream before continuing."
}

$pgutSource = Join-Path $UpstreamDir "bin\pgut\pgut.c"
$pgutText = Get-Content $pgutSource -Raw

foreach ($functionName in @("on_before_exec", "on_after_exec")) {
    $functionMarker = "$functionName(pgutConn *conn)"
    $functionStart = $pgutText.LastIndexOf($functionMarker, [StringComparison]::Ordinal)
    if ($functionStart -lt 0) {
        throw "Expected function '$functionName' was not found in pgut.c."
    }

    $nextFunction = $pgutText.IndexOf("static void", $functionStart + $functionMarker.Length, [StringComparison]::Ordinal)
    if ($nextFunction -lt 0) {
        $nextFunction = $pgutText.Length
    }

    $lockMarker = "EnterCriticalSection(&cancelConnLock);"
    $lockPosition = $pgutText.IndexOf($lockMarker, $functionStart, [StringComparison]::Ordinal)
    if ($lockPosition -lt 0 -or $lockPosition -ge $nextFunction) {
        throw "Expected Windows cancel lock was not found in '$functionName'."
    }

    $segment = $pgutText.Substring($functionStart, $lockPosition - $functionStart)
    if ($segment -notmatch 'init_cancel_handler\(\);') {
        $insertText = "init_cancel_handler();" + [Environment]::NewLine + [char]9
        $pgutText = $pgutText.Insert($lockPosition, $insertText)
    }
}

Set-Content -Path $pgutSource -Value $pgutText -Encoding utf8

# Generate extension control and SQL exactly as upstream PGXS does for
# PostgreSQL 12+, which covers every pgextwin target.
$controlTemplate = Join-Path $UpstreamDir "lib\pg_repack.control.in"
$sqlTemplate = Join-Path $UpstreamDir "lib\pg_repack.sql.in"
$controlOut = Join-Path $UpstreamDir "lib\pg_repack.control"
$sqlOut = Join-Path $UpstreamDir "lib\pg_repack--$repackVersion.sql"

(Get-Content $controlTemplate -Raw).Replace("REPACK_VERSION", $repackVersion) |
    Set-Content -Path $controlOut -Encoding utf8

(Get-Content $sqlTemplate -Raw).
    Replace("REPACK_VERSION", $repackVersion).
    Replace("relhasoids", "false") |
    Set-Content -Path $sqlOut -Encoding utf8

# Reuse upstream's explicit Windows export list for the server DLL.
$exportsPath = Join-Path $UpstreamDir "lib\exports.txt"
$defPath = Join-Path $UpstreamDir "pg_repack.pgextwin.def"
(@("LIBRARY pg_repack", "EXPORTS") + (Get-Content $exportsPath)) |
    Set-Content -Path $defPath -Encoding ascii

foreach ($library in @("postgres.lib", "libpq.lib", "libintl.lib", "libpgport.lib", "libpgcommon.lib")) {
    $path = Join-Path $PgRoot "lib\$library"
    if (-not (Test-Path $path)) {
        throw "Required PostgreSQL library was not found: $path"
    }
}

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$cmdFile = Join-Path $tempRoot "pg_repack-build.cmd"

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cd /d "$UpstreamDir"

rem Server extension DLL
cl /nologo /O2 /MD /DWIN32 /DNOGDI /DNOMINMAX /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include\internal" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir\lib\pgut" ^
  /c "$UpstreamDir\lib\repack.c" /Fo"$UpstreamDir\repack.obj"
if errorlevel 1 exit /b %errorlevel%

cl /nologo /O2 /MD /DWIN32 /DNOGDI /DNOMINMAX /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include\internal" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir\lib\pgut" ^
  /c "$UpstreamDir\lib\pgut\pgut-spi.c" /Fo"$UpstreamDir\pgut-spi.obj"
if errorlevel 1 exit /b %errorlevel%

link /nologo /DLL /OUT:"$UpstreamDir\pg_repack.dll" /DEF:"$defPath" ^
  "$UpstreamDir\repack.obj" "$UpstreamDir\pgut-spi.obj" ^
  "$PgRoot\lib\postgres.lib" "$PgRoot\lib\libpq.lib" "$PgRoot\lib\libintl.lib" ^
  "$PgRoot\lib\libpgport.lib" "$PgRoot\lib\libpgcommon.lib" ws2_32.lib advapi32.lib
if errorlevel 1 exit /b %errorlevel%

rem Client executable
cl /nologo /O2 /MD /DWIN32 /DNOGDI /DNOMINMAX /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include\internal" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir\bin\pgut" ^
  /c "$UpstreamDir\bin\pg_repack.c" /Fo"$UpstreamDir\pg_repack-client.obj"
if errorlevel 1 exit /b %errorlevel%

cl /nologo /O2 /MD /DWIN32 /DNOGDI /DNOMINMAX /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include\internal" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir\bin\pgut" ^
  /c "$UpstreamDir\bin\pgut\pgut.c" /Fo"$UpstreamDir\pgut.obj"
if errorlevel 1 exit /b %errorlevel%

cl /nologo /O2 /MD /DWIN32 /DNOGDI /DNOMINMAX /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DREPACK_VERSION=$repackVersion ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include\internal" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir\bin\pgut" ^
  /c "$UpstreamDir\bin\pgut\pgut-fe.c" /Fo"$UpstreamDir\pgut-fe.obj"
if errorlevel 1 exit /b %errorlevel%

link /nologo /OUT:"$UpstreamDir\pg_repack.exe" ^
  "$UpstreamDir\pg_repack-client.obj" "$UpstreamDir\pgut.obj" "$UpstreamDir\pgut-fe.obj" ^
  "$PgRoot\lib\libpq.lib" "$PgRoot\lib\libintl.lib" "$PgRoot\lib\libpgport.lib" "$PgRoot\lib\libpgcommon.lib" ^
  ws2_32.lib advapi32.lib
if errorlevel 1 exit /b %errorlevel%
"@ | Set-Content -Path $cmdFile -Encoding ascii

& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) {
    throw "pg_repack MSVC build failed with exit code $LASTEXITCODE."
}

foreach ($output in @(
    (Join-Path $UpstreamDir "pg_repack.dll"),
    (Join-Path $UpstreamDir "pg_repack.exe"),
    $controlOut,
    $sqlOut
)) {
    if (-not (Test-Path $output)) {
        throw "Expected pg_repack build output was not produced: $output"
    }
}

& (Join-Path $UpstreamDir "pg_repack.exe") --version
if ($LASTEXITCODE -ne 0) {
    throw "Built pg_repack.exe could not execute --version."
}

Write-Host "Built pg_repack $repackVersion Windows client and extension DLL."
