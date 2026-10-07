param()

$ErrorActionPreference = "Stop"

$SrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PayloadDir = $SrcDir
if (Test-Path -LiteralPath (Join-Path $SrcDir 'App\version.json')) { $PayloadDir = Join-Path $SrcDir 'App' }
. (Join-Path $PayloadDir 'update-common.ps1')
$AppVersion = Get-AppVersion (Join-Path $PayloadDir 'version.json')
$LegacyRoot = Join-Path $env:LOCALAPPDATA "ESDE-RGCube-Sync"
$AppRoot = Join-Path $env:LOCALAPPDATA "ESDE-Sync"
$InstallDir = Join-Path $AppRoot "App"
$PlatformDir = Join-Path $AppRoot "platform-tools"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# Remove stale icon files from older builds so Windows cannot reuse them accidentally.
Remove-Item -LiteralPath (Join-Path $InstallDir "esde-sync-icon.ico") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $InstallDir "esde-sync-icon.png") -Force -ErrorAction SilentlyContinue

# Migrate useful data from the old RG Cube-specific build if it exists.
if ((Test-Path $LegacyRoot) -and (-not (Test-Path (Join-Path $AppRoot "config.json")))) {
    foreach ($name in @("config.json", "Manifests", "platform-tools")) {
        $src = Join-Path $LegacyRoot $name
        $dst = Join-Path $AppRoot $name
        if ((Test-Path $src) -and (-not (Test-Path $dst))) {
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        }
    }
}

Copy-Item -LiteralPath (Join-Path $PayloadDir "ESDE-Sync.ps1") -Destination $InstallDir -Force
Copy-Item -LiteralPath (Join-Path $PayloadDir "sync-worker.ps1") -Destination $InstallDir -Force
Copy-Item -LiteralPath (Join-Path $PayloadDir "esde-sync-icon-v141.ico") -Destination $InstallDir -Force
Copy-Item -LiteralPath (Join-Path $PayloadDir "esde-sync-icon-v141.png") -Destination $InstallDir -Force

Copy-Item -LiteralPath (Join-Path $PayloadDir 'version.json') -Destination $InstallDir -Force
Copy-Item -LiteralPath (Join-Path $PayloadDir 'update-common.ps1') -Destination $InstallDir -Force

$adb = Join-Path $PlatformDir "adb.exe"
if (-not (Test-Path $adb)) {
    Write-Host "Downloading Android Platform Tools..."
    $zip = Join-Path $env:TEMP "platform-tools-latest-windows.zip"
    $tmp = Join-Path $env:TEMP ("esde-platform-tools-" + [guid]::NewGuid().ToString("N"))

    Invoke-WebRequest -Uri "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    if (Test-Path $PlatformDir) { Remove-Item -LiteralPath $PlatformDir -Recurse -Force }
    Move-Item -LiteralPath (Join-Path $tmp "platform-tools") -Destination $PlatformDir

    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$WshShell = New-Object -ComObject WScript.Shell
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$TargetScript = Join-Path $InstallDir "ESDE-Sync.ps1"
$IconPath = Join-Path $InstallDir "esde-sync-icon-v141.ico"
$desktop = [Environment]::GetFolderPath("Desktop")
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"

# Remove old shortcut names if they exist.
foreach ($legacyLink in @(
    (Join-Path $desktop "ES-DE Sync - RG Cube.lnk"),
    (Join-Path $startMenu "ES-DE Sync - RG Cube.lnk")
)) {
    Remove-Item -LiteralPath $legacyLink -Force -ErrorAction SilentlyContinue
}

$links = @(
    (Join-Path $desktop "ES-DE Sync.lnk"),
    (Join-Path $startMenu "ES-DE Sync.lnk")
)

foreach ($linkPath in $links) {
    $shortcut = $WshShell.CreateShortcut($linkPath)
    $shortcut.TargetPath = $PowerShellExe
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetScript`""
    $shortcut.WorkingDirectory = $InstallDir
    if (Test-Path $IconPath) { $shortcut.IconLocation = "$IconPath,0" }
    $shortcut.Description = "ES-DE Sync"
    $shortcut.Save()
}

Write-Host ""
Write-Host ("ES-DE Sync for Android v" + $AppVersion.version + " installed successfully.")
Write-Host "Run the desktop shortcut: ES-DE Sync"
