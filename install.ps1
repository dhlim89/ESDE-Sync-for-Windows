param([string]$InstallRoot, [switch]$SkipShortcuts, [switch]$SkipPlatformTools)
$ErrorActionPreference = 'Stop'
$SrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PayloadDir = $SrcDir
if (Test-Path -LiteralPath (Join-Path $SrcDir 'App\version.json')) { $PayloadDir = Join-Path $SrcDir 'App' }
. (Join-Path $PayloadDir 'update-common.ps1')
. (Join-Path $PayloadDir 'update-transaction.ps1')
$AppVersion = Get-AppVersion (Join-Path $PayloadDir 'version.json')
$AppRoot = Join-Path $env:LOCALAPPDATA 'ESDE-Sync'
if ($InstallRoot) { $AppRoot = [IO.Path]::GetFullPath($InstallRoot) }
[void](Assert-UpdateDiskPath $AppRoot $AppRoot)
$operation = Enter-AppMutex $AppRoot 'operation'
try {
    if (Get-PendingUpdate $AppRoot) { throw '미완료 업데이트 세션을 먼저 복구해 주세요.' }
    Assert-NoAppProcesses $AppRoot -IncludeGui
    New-Item -ItemType Directory -Path $AppRoot -Force | Out-Null

    # 기존 설정은 덮어쓰지 않는다. 구 RG Cube 설치의 최초 데이터 이관만 유지한다.
    $legacyRoot = Join-Path $env:LOCALAPPDATA 'ESDE-RGCube-Sync'
    if (-not $InstallRoot -and (Test-Path $legacyRoot) -and -not (Test-Path (Join-Path $AppRoot 'config.json'))) {
        foreach ($name in @('config.json','Manifests','platform-tools')) {
            $source = Join-Path $legacyRoot $name
            $destination = Join-Path $AppRoot $name
            if ((Test-Path $source) -and -not (Test-Path $destination)) { Copy-Item -LiteralPath $source -Destination $destination -Recurse }
        }
    }
    $platform = Join-Path $AppRoot 'platform-tools'
    if (-not $SkipPlatformTools -and -not (Test-Path (Join-Path $platform 'adb.exe'))) {
        if (Test-Path $platform) { throw '기존 platform-tools는 수정하지 않습니다. adb.exe 상태를 확인해 주세요.' }
        $bootstrap = Join-Path $AppRoot ('.Updates\bootstrap-'+[guid]::NewGuid().ToString('N'))
        [void](Assert-UpdateDiskPath $bootstrap $AppRoot)
        New-Item -ItemType Directory -Path $bootstrap -Force | Out-Null
        $zip = Join-Path $bootstrap 'platform-tools.zip'
        Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $bootstrap 'tools')
        $tools = Join-Path $bootstrap 'tools\platform-tools'
        if (-not (Test-Path (Join-Path $tools 'adb.exe'))) { throw 'Platform Tools 패키지 오류' }
        Move-UpdateDirectory $tools $platform $AppRoot
    }
    # 바로가기는 항상 고정 App 경로를 사용한다. App 교체 전에 준비한다.
    if (-not $SkipShortcuts) {
        $shell = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath('Desktop')
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        foreach ($folder in @($desktop,$startMenu)) {
            $shortcut = $shell.CreateShortcut((Join-Path $folder 'ES-DE Sync.lnk'))
            $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $AppRoot 'App\ESDE-Sync.ps1')+'"'
            $shortcut.WorkingDirectory = Join-Path $AppRoot 'App'
            $shortcut.IconLocation = (Join-Path $AppRoot 'App\esde-sync-icon-v141.ico')+',0'
            $shortcut.Description = 'ES-DE Sync'
            $shortcut.Save()
        }
    }
    $session = New-LocalUpdateSession $AppRoot $PayloadDir $AppVersion
    $result = Invoke-UpdateTransaction $AppRoot $session
    if ($result.state -ne 'completed') {
        throw ('설치 실패: '+$result.originalError+' / 복구: '+$result.rollbackError+' / 세션: '+$session)
    }
    Write-Host ('ES-DE Sync for Android v'+$AppVersion.version+' 설치 및 시작 확인 완료.')
    Write-Host ('이전 App 백업과 설치 기록: '+$session)
}
finally { Exit-AppMutex $operation }