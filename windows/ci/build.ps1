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

$controlPath = Join-Path $UpstreamDir "pgaudit.control"
$sourcePath = Join-Path $UpstreamDir "pgaudit.c"

$control = Get-Content $controlPath -Raw
if ($control -notmatch "default_version\s*=\s*'([^']+)'") {
    throw "Could not determine pgAudit version from pgaudit.control."
}
$pgauditVersion = $Matches[1]

$source = Get-Content $sourcePath -Raw
$exports = @("Pg_magic_func", "_PG_init")
foreach ($match in [regex]::Matches($source, 'PG_FUNCTION_INFO_V1\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)')) {
    $exports += $match.Groups[1].Value
}
$exports = @($exports | Sort-Object -Unique)

$defPath = Join-Path $UpstreamDir "pgaudit.pgextwin.def"
(@("LIBRARY pgaudit", "EXPORTS") + @($exports | ForEach-Object { "    $_" })) |
    Set-Content -Path $defPath -Encoding ascii

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$cmdFile = Join-Path $tempRoot "pgaudit-build.cmd"

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cd /d "$UpstreamDir"

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS /DPGAUDIT_VERSION=\""$pgauditVersion\"" ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include" ^
  /c "$sourcePath" /Fo"$UpstreamDir\pgaudit.obj"
if errorlevel 1 exit /b %errorlevel%

link /nologo /DLL /OUT:"$UpstreamDir\pgaudit.dll" /DEF:"$defPath" ^
  "$UpstreamDir\pgaudit.obj" ^
  "$PgRoot\lib\postgres.lib" ^
  "$PgRoot\lib\libintl.lib"
if errorlevel 1 exit /b %errorlevel%
"@ | Set-Content -Path $cmdFile -Encoding ascii

& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) {
    throw "pgAudit MSVC build failed with exit code $LASTEXITCODE."
}

$dll = Join-Path $UpstreamDir "pgaudit.dll"
if (-not (Test-Path $dll)) {
    throw "Expected pgaudit.dll was not produced: $dll"
}

Write-Host "Built pgAudit $pgauditVersion with exports: $($exports -join ', ')"
