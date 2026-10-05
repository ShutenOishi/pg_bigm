[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
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

$pgConfig = Join-Path $PgRoot "bin\pg_config.exe"
$pgVersionText = (& $pgConfig --version).Trim()
if ($LASTEXITCODE -ne 0 -or $pgVersionText -notmatch 'PostgreSQL\s+(\d+)') {
    throw "Could not determine PostgreSQL major version from pg_config: '$pgVersionText'"
}

$pgMajor = [int]$Matches[1]
$makefileName = "Makefile.win"

# PostgreSQL 16 changed fmgr.h so that PG_FUNCTION_INFO_V1() exports the SQL
# function itself on Windows and centrally marks _PG_init/_PG_fini as
# PGDLLEXPORT. PostgreSQL 14/15 do not do that. Upstream pg_cron v1.6.8's
# Makefile.win was introduced and tested on PG18, so for PG14/15 we add only
# the missing DLL exports at link time without modifying upstream C sources.
if ($pgMajor -lt 16) {
    $exports = @("_PG_init")

    Get-ChildItem (Join-Path $UpstreamDir "src") -Filter "*.c" | ForEach-Object {
        $source = Get-Content $_.FullName -Raw
        foreach ($match in [regex]::Matches($source, 'PG_FUNCTION_INFO_V1\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)')) {
            $exports += $match.Groups[1].Value
        }
    }

    $exports = @($exports | Sort-Object -Unique)
    $defPath = Join-Path $UpstreamDir "pg_cron.pgextwin.def"
    $defLines = @("LIBRARY pg_cron", "EXPORTS") + @($exports | ForEach-Object { "    $_" })
    $defLines | Set-Content -Path $defPath -Encoding ascii

    $upstreamMakefile = Join-Path $UpstreamDir "Makefile.win"
    $compatMakefile = Join-Path $UpstreamDir "Makefile.pgextwin.win"
    $makefileText = Get-Content $upstreamMakefile -Raw
    $linkLine = '$(CC) $(CFLAGS) $(OBJS) $(LIBS) /link /DLL /OUT:$(SHLIB)'
    $compatLinkLine = '$(CC) $(CFLAGS) $(OBJS) $(LIBS) /link /DLL /DEF:pg_cron.pgextwin.def /OUT:$(SHLIB)'

    if (-not $makefileText.Contains($linkLine)) {
        throw "Expected upstream Makefile.win link command was not found; review the pg_cron Windows build before continuing."
    }

    $makefileText.Replace($linkLine, $compatLinkLine) | Set-Content -Path $compatMakefile -Encoding ascii
    $makefileName = "Makefile.pgextwin.win"

    Write-Host "PostgreSQL $pgMajor detected. Added compatibility exports: $($exports -join ', ')"
}
else {
    Write-Host "PostgreSQL $pgMajor detected. Using upstream Makefile.win unchanged."
}

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$cmdFile = Join-Path $tempRoot "pg_cron-build.cmd"

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
set "PGROOT=$PgRoot"
cd /d "$UpstreamDir"
nmake /F "$makefileName" all
"@ | Set-Content -Path $cmdFile -Encoding ascii

& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) {
    throw "pg_cron nmake build failed with exit code $LASTEXITCODE."
}

$dll = Join-Path $UpstreamDir "pg_cron.dll"
$baseSql = Join-Path $UpstreamDir "pg_cron--1.0.sql"

if (-not (Test-Path $dll)) {
    throw "Expected pg_cron.dll was not produced: $dll"
}
if (-not (Test-Path $baseSql)) {
    throw "Expected generated pg_cron--1.0.sql was not produced: $baseSql"
}
