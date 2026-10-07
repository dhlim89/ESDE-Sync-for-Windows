# 실제 ADB나 worker 본문을 실행하지 않는 안전성 회귀 검증.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
$ReservedFolders = @('_TEST', '_UNREGISTERED')
$selectedSystems = @('gb'); $Serial = 'MOCK'
$Buckets = @(@{Remote='/storage/emulated/0/ROMs'}, @{Remote='/storage/emulated/0/ES-DE/gamelists'}, @{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$script:Calls = @(); $script:FailType = ''; $script:Files = @(); $script:Dirs = @()
function Write-Log { }
function Invoke-Adb {
    $command = $args -join ' '
    $script:Calls += $command
    if ($command -match 'find ') {
        $type = if ($command -match '-type f') { 'f' } else { 'd' }
        if ($script:FailType -eq $type) { return [pscustomobject]@{Code=1; StdErr='mock failure'; StdOut=''; Output=@()} }
        $lines = if ($type -eq 'f') { $script:Files } else { $script:Dirs }
        return [pscustomobject]@{Code=0; StdErr=''; StdOut=$(if (@($lines).Count) { ($lines -join [char]0) + [char]0 } else { "" }); Output=$lines}
    }
    return [pscustomobject]@{Code=0; StdErr=''; StdOut=''; Output=@()}
}
function Check($value, $message) { if (-not $value) { throw $message } }
$root = '/storage/emulated/0/ROMs/gb'
foreach ($bad in @('', '/', '/storage/emulated/0', '/storage/emulated/0/ROMs', "$root/../gbc/a", '/storage/emulated/0/ROMs/gbc/a', "$root//a", "$root/_TEST/a", "$root/_UNREGISTERED/a", $root)) {
    $blocked = $false
    try { Remove-RemoteFile $bad } catch { $blocked = $true }
    Check $blocked ('경로 거부 실패: ' + $bad)
}
Check ($script:Calls.Count -eq 0) '위험 경로에서 ADB 호출 발생'
foreach ($bucket in $Buckets) {
    $blocked = $false
    try { Remove-RemoteTree $bucket.Remote } catch { $blocked = $true }
    Check $blocked '허용 루트 전체 삭제 허용'
    Assert-RemotePath ($bucket.Remote + '/gb/normal') -Deleting
}
foreach ($name in $ReservedFolders) {
    Check (Is-ExcludedRelativePath ($name + '/deep/keep.gb')) '예약 하위 판정 누락'
    $blocked = $false
    try { Remove-RemoteTree ($root + '/' + $name) } catch { $blocked = $true }
    Check $blocked '예약 폴더 전체 삭제 허용'
}
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('esde-static-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
foreach ($layout in @('none', '_TEST', '_UNREGISTERED', 'both')) {
    $local = Join-Path $sandbox ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $local | Out-Null
    Set-Content -LiteralPath (Join-Path $local 'normal.gb') -Value 'mock'
    $names = if ($layout -eq 'both') { $ReservedFolders } elseif ($layout -eq 'none') { @() } else { @($layout) }
    foreach ($name in $names) {
        $d = Join-Path $local $name
        New-Item -ItemType Directory -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'keep.gb') -Value 'keep'
    }
    $script:Calls = @(); $script:Files = @("$root/extra.gb"); $script:Dirs = @()
    Mirror-SystemFolder $local $root 'MOCK'
    Check (@($script:Calls | Where-Object { $_ -match 'find ' -and $_ -match '-iname.*_TEST' -and $_ -match '-iname.*_UNREGISTERED' -and $_ -match '-prune' }).Count -eq 2) '예약 하위 탐색 방지 누락'
    Check (@($script:Calls | Where-Object { $_ -match 'rm -f.*extra.gb' }).Count -eq 1) '일반 추가 ROM 삭제 누락'
    Check (@($script:Calls | Where-Object { $_ -match 'push' -and $_ -match '_TEST|_UNREGISTERED' }).Count -eq 0) '예약 폴더 전송 발생'
    if ($names.Count) { Check (@($script:Calls | Where-Object { $_ -match 'push.*normal.gb' }).Count -eq 1) '일반 ROM 전송 누락' }
    Write-Output ('PASS: 원본 존재 및 예약 구성 ' + $layout)
}
$script:Files = @("$root/extra.gb"); $script:Dirs = @("$root/empty"); $script:Calls = @()
Remove-ManagedRemoteContents $root
Check (@($script:Calls | Where-Object { $_ -match 'rm -rf' }).Count -eq 0) 'ROM 시스템 전체 삭제 발생'
Check (@($script:Calls | Where-Object { $_ -match 'rm -f.*extra.gb' }).Count -eq 1) '원본 부재 정리 누락'
foreach ($type in @('f', 'd')) {
    $script:FailType = $type; $script:Calls = @(); $blocked = $false
    try { Mirror-SystemFolder $local $root 'MOCK' } catch { $blocked = $true }
    Check $blocked '조회 실패 허용'
    Check (@($script:Calls | Where-Object { $_ -match 'rm -f|rm -rf|rmdir|push' }).Count -eq 0) '조회 실패 후 변경 호출 발생'
    $script:Calls = @(); $blocked = $false
    try { Remove-ManagedRemoteContents $root } catch { $blocked = $true }
    Check $blocked '원본 부재 조회 실패 허용'
    Check (@($script:Calls | Where-Object { $_ -match 'rm -f|rm -rf|rmdir' }).Count -eq 0) '원본 부재 조회 실패 후 삭제 발생'
}
$script:FailType = ''; $script:Calls = @(); $blocked = $false
try { Mirror-SystemFolder $local '/storage/emulated/0/ROMs/gbc' 'MOCK' } catch { $blocked = $true }
Check $blocked '미선택 시스템 허용'
Check ($script:Calls.Count -eq 0) '미선택 시스템 ADB 호출'
foreach ($file in Get-ChildItem -LiteralPath $repo -Filter '*.ps1') {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Check ($errors.Count -eq 0) ('구문 오류: ' + $file.Name)
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    Check ([BitConverter]::ToString($bytes, 0, 3) -eq 'EF-BB-BF') ('BOM 누락: ' + $file.Name)
}
Write-Output ('PASS: 원본 부재, 일반 ROM 삭제, 위험 경로, 미선택 시스템, 조회 실패, 구문/BOM; PowerShell ' + $PSVersionTable.PSVersion)
Write-Output ('모의 파일 위치: ' + $sandbox)
