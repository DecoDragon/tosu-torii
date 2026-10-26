<#
.SYNOPSIS
Builds a shareable release of this tosu fork for torii / torii nova users.

.DESCRIPTION
Assembles one zip containing:
  - the compiled tosu (packages/tosu/dist, personal state stripped)
  - offsets for the torii install you point it at (torii-offsets/<version>.json,
    the folder tosu searches automatically next to the exe)
  - a SELF-CONTAINED torii-offsets.exe generator, so recipients can regenerate
    offsets themselves after every torii update (no .NET SDK needed)
  - a plain-text quick-start README for recipients

Run from anywhere; paths are resolved relative to the repo root.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -ToriiPath "C:\Users\<you>\AppData\Local\torii\current"

.EXAMPLE
# skip rebuilding tosu if packages\tosu\dist is already current:
powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -ToriiPath "..." -SkipBuild
#>
param(
    [Parameter(Mandatory = $true)][string]$ToriiPath,
    [string]$OutDir = "release",
    [string]$RepoUrl = "https://github.com/DecoDragon/tosu-torii",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# 1. tosu build ---------------------------------------------------------------
$dist = Join-Path $repoRoot "packages\tosu\dist"
if (-not $SkipBuild) {
    Write-Host "==> Building tosu (pnpm build:win) - close any running tosu.exe first" -ForegroundColor Cyan
    & pnpm build:win
    if ($LASTEXITCODE -ne 0) { throw "tosu build failed" }
}
if (-not (Test-Path (Join-Path $dist "tosu.exe"))) {
    throw "tosu.exe not found in $dist - run without -SkipBuild"
}

# 2. generator exe (self-contained: recipients don't need the .NET SDK) -------
Write-Host "==> Publishing torii-offsets generator (self-contained single file)" -ForegroundColor Cyan
$genPublish = Join-Path $repoRoot "tools\torii-offsets\publish"
& dotnet publish (Join-Path $repoRoot "tools\torii-offsets") -c Release -f net10.0 -r win-x64 `
    --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true `
    -o $genPublish
if ($LASTEXITCODE -ne 0) { throw "generator publish failed" }
$genExe = Join-Path $genPublish "torii-offsets.exe"

# 3. offsets for the torii install you pass in --------------------------------
Write-Host "==> Generating offsets from $ToriiPath" -ForegroundColor Cyan
$genOut = Join-Path $repoRoot "tools\torii-offsets\out"
& $genExe --torii-path $ToriiPath --out $genOut
if ($LASTEXITCODE -ne 0) { throw "offset generation failed - fix before sharing" }

# 4. stage the release folder --------------------------------------------------
$stamp = Get-Date -Format "yyyy.MM.dd"
$stage = Join-Path $OutDir "tosu-torii-$stamp"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Write-Host "==> Assembling $stage" -ForegroundColor Cyan
# tosu binary + runtime files, minus YOUR personal state (settings, logs, cache, overlays)
Get-ChildItem $dist -Exclude 'config.ini', 'logs', '.cache', 'static', 'torii-offsets' |
    Copy-Item -Destination $stage -Recurse -Force

# offsets next to tosu.exe -> found automatically via <tosu folder>\torii-offsets\<version>.json
$offsetsDir = Join-Path $stage "torii-offsets"
New-Item -ItemType Directory -Force -Path $offsetsDir | Out-Null
Copy-Item (Join-Path $genOut "*.json") $offsetsDir -Force

# generator so recipients can self-serve after torii updates
Copy-Item $genExe $stage -Force

$versions = (Get-ChildItem $offsetsDir -Filter '*.json' | ForEach-Object { $_.BaseName }) -join ', '

@"
tosu with torii / torii nova support
(fork of tosuapp/tosu 4.26.2 - source: $RepoUrl, branch torii-support)

QUICK START
1. Extract this whole folder somewhere permanent (NOT inside OneDrive).
2. Start torii, then start tosu.exe.
3. Dashboard: http://127.0.0.1:24050 - install and enable overlays there as usual.

Bundled offsets cover torii version(s): $versions

AFTER A TORII UPDATE (tosu log says "No torii offsets found for <version>")
Offsets are per-build, so regenerate them - takes ~30 seconds, torii can stay closed,
no .NET installation needed:
1. Open PowerShell in THIS folder and run:
     .\torii-offsets.exe --torii-path "`$env:LOCALAPPDATA\torii\current" --out ".\torii-offsets"
   (adjust --torii-path if you installed torii elsewhere - it is the folder
    containing torii.exe / torii.deps.json)
2. Restart tosu.exe. Old <version>.json files can stay; tosu picks by version.

NOTES
- Official osu! and osu!lazer also still work with this build.
- Auto-update is intentionally disabled: it would replace this fork with stock
  tosu and drop torii support. Leave ENABLE_AUTOUPDATE off.
- In-game overlay injection (ENABLE_INGAME_OVERLAY) is untested with torii's
  renderer; leave it off unless you want to experiment.
- Memory readers sometimes trigger antivirus heuristics - same situation as
  official tosu. The source link above lets you verify/build it yourself.
- This is a modified build of tosuapp/tosu, licensed LGPL-3.0.
"@ | Set-Content (Join-Path $stage "README-torii.txt") -Encoding UTF8

# 5. zip -----------------------------------------------------------------------
$zip = Join-Path $OutDir "tosu-torii-$stamp.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Write-Host "==> Compressing (this can take a minute)" -ForegroundColor Cyan
Compress-Archive -Path $stage -DestinationPath $zip

$sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "==> Done: $zip ($sizeMb MB)" -ForegroundColor Green
Write-Host "    Share that zip, or upload it as a GitHub Release asset on your fork."
