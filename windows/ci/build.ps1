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

$pgConfig = Join-Path $PgRoot "bin\pg_config.exe"
$pgVersionText = (& $pgConfig --version).Trim()
if ($LASTEXITCODE -ne 0 -or $pgVersionText -notmatch 'PostgreSQL\s+(\d+)\.(\d+)') {
    throw "Could not determine PostgreSQL version from pg_config: '$pgVersionText'"
}

$pgMajor = [int]$Matches[1]
$pgVersion = "$($Matches[1]).$($Matches[2])"

$queryScanL = Join-Path $UpstreamDir "query_scan.l"
$queryScanC = Join-Path $UpstreamDir "query_scan.c"

if (Test-Path $queryScanL) {
    $winFlex = Get-Command win_flex.exe -ErrorAction SilentlyContinue

    if ($null -eq $winFlex) {
        Write-Host "win_flex.exe not found; installing winflexbison3 for the probe."
        & choco install winflexbison3 --yes --no-progress
        if ($LASTEXITCODE -notin @(0, 1641, 3010)) {
            throw "Chocolatey failed to install winflexbison3 with exit code $LASTEXITCODE."
        }

        $winFlex = Get-Command win_flex.exe -ErrorAction SilentlyContinue
    }

    if ($null -eq $winFlex) {
        throw "win_flex.exe was not found after installing winflexbison3."
    }

    & $winFlex.Source "--outfile=$queryScanC" $queryScanL
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $queryScanC)) {
        throw "Failed to generate query_scan.c from query_scan.l."
    }
}

$source = Get-Content (Join-Path $UpstreamDir "pg_hint_plan.c") -Raw
$exports = @("_PG_init")
if ($source -match '(?ms)\bvoid\s+_PG_fini\s*\(\s*void\s*\)\s*\{') {
    $exports += "_PG_fini"
}

$defPath = Join-Path $UpstreamDir "pg_hint_plan.pgextwin.def"
(@("LIBRARY pg_hint_plan", "EXPORTS") + @($exports | Sort-Object -Unique | ForEach-Object { "    $_" })) |
    Set-Content -Path $defPath -Encoding ascii

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$objects = @("pg_hint_plan.obj")
$extraInclude = ""
$compileQueryJumble = ""

if ($pgMajor -lt 17) {
    $sourceSha256 = @{
        "14.24" = "a7fa7ed3d558172355f51406097a7bd4f6b473be80f311ef7cda96bf383d8897"
        "15.19" = "e1a64a87a46b825b88c082e4518161a47aab53c45694964f8ba1df28f7859f89"
        "16.15" = "c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed"
    }

    if (-not $sourceSha256.ContainsKey($pgVersion)) {
        throw "No reviewed PostgreSQL source SHA-256 is configured for $pgVersion."
    }

    $archiveName = "postgresql-$pgVersion.tar.bz2"
    $archivePath = Join-Path $tempRoot $archiveName
    $sourceParent = Join-Path $tempRoot "pgextwin-postgresql-source-$pgVersion"
    $sourceRoot = Join-Path $sourceParent "postgresql-$pgVersion"
    $sourceUrl = "https://ftp.postgresql.org/pub/source/v$pgVersion/$archiveName"

    if (Test-Path $sourceParent) {
        Remove-Item $sourceParent -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $sourceParent | Out-Null

    Write-Host "Downloading official PostgreSQL source: $sourceUrl"
    Invoke-WebRequest -Uri $sourceUrl -OutFile $archivePath

    $actualSourceHash = (Get-FileHash $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedSourceHash = $sourceSha256[$pgVersion].ToLowerInvariant()
    if ($actualSourceHash -ne $expectedSourceHash) {
        throw "PostgreSQL source SHA-256 mismatch for $archiveName. Expected $expectedSourceHash, got $actualSourceHash."
    }

    & tar.exe -xjf $archivePath -C $sourceParent
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $sourceRoot)) {
        throw "Failed to extract official PostgreSQL source archive: $archivePath"
    }

    if ($pgMajor -le 15) {
        $queryJumbleSource = Join-Path $sourceRoot "src\backend\utils\misc\queryjumble.c"
    }
    else {
        $queryJumbleSource = Join-Path $sourceRoot "src\backend\nodes\queryjumblefuncs.c"
        $queryJumbleNodeDir = Join-Path $sourceRoot "src\backend\nodes"

        foreach ($generated in @("queryjumblefuncs.funcs.c", "queryjumblefuncs.switch.c")) {
            $generatedPath = Join-Path $queryJumbleNodeDir $generated
            if (-not (Test-Path $generatedPath)) {
                throw "Official PostgreSQL source archive is missing generated file required for PG16: $generatedPath"
            }
        }

        $extraInclude = '/I"' + $queryJumbleNodeDir + '"'
    }

    if (-not (Test-Path $queryJumbleSource)) {
        throw "PostgreSQL query-jumble source was not found: $queryJumbleSource"
    }

    $queryJumbleObject = Join-Path $UpstreamDir "queryjumble.pgextwin.obj"
    $objects += "queryjumble.pgextwin.obj"

    $compileQueryJumble = @"
cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include" ^
  $extraInclude ^
  /c "$queryJumbleSource" /Fo"$queryJumbleObject"
if errorlevel 1 exit /b %errorlevel%
"@
}

$cmdFile = Join-Path $tempRoot "pg_hint_plan-build.cmd"

$compileQueryScan = ""
if (Test-Path $queryScanC) {
    $compileQueryScan = @"
cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir" ^
  /c "$queryScanC" /Fo"$UpstreamDir\query_scan.obj"
if errorlevel 1 exit /b %errorlevel%
"@
    $objects += "query_scan.obj"
}

$objectArgs = ($objects | ForEach-Object { '"{0}"' -f (Join-Path $UpstreamDir $_) }) -join " "

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cd /d "$UpstreamDir"

cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS ^
  /I"$PgRoot\include\server\port\win32_msvc" ^
  /I"$PgRoot\include\server\port\win32" ^
  /I"$PgRoot\include\server" ^
  /I"$PgRoot\include" ^
  /I"$UpstreamDir" ^
  /c "$UpstreamDir\pg_hint_plan.c" /Fo"$UpstreamDir\pg_hint_plan.obj"
if errorlevel 1 exit /b %errorlevel%

$compileQueryJumble

$compileQueryScan

link /nologo /DLL /OUT:"$UpstreamDir\pg_hint_plan.dll" /DEF:"$defPath" ^
  $objectArgs ^
  "$PgRoot\lib\postgres.lib" ^
  "$PgRoot\lib\libintl.lib"
if errorlevel 1 exit /b %errorlevel%
"@ | Set-Content -Path $cmdFile -Encoding ascii

& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) {
    throw "pg_hint_plan MSVC build failed with exit code $LASTEXITCODE."
}

$dll = Join-Path $UpstreamDir "pg_hint_plan.dll"
if (-not (Test-Path $dll)) {
    throw "Expected pg_hint_plan.dll was not produced: $dll"
}

Write-Host "Built pg_hint_plan for PostgreSQL $pgVersion with exports: $($exports -join ', ')"
