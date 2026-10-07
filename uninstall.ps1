$CurrentRoot = Join-Path $env:LOCALAPPDATA "ESDE-Sync"
$LegacyRoot = Join-Path $env:LOCALAPPDATA "ESDE-RGCube-Sync"
$desktop = [Environment]::GetFolderPath("Desktop")
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"

foreach ($link in @(
    (Join-Path $desktop "ES-DE Sync.lnk"),
    (Join-Path $startMenu "ES-DE Sync.lnk"),
    (Join-Path $desktop "ES-DE Sync - RG Cube.lnk"),
    (Join-Path $startMenu "ES-DE Sync - RG Cube.lnk")
)) {
    Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $CurrentRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $LegacyRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "ES-DE Sync has been uninstalled."
