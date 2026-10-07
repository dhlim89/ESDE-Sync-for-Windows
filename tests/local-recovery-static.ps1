# 실제 ADB 없이 Windows 경로 API와 reparse/복구 정책을 검증한다.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
function Check($value, $message) { if (-not $value) { throw $message } }
$script:Messages = @()
function Write-Log([string]$Message) { $script:Messages += $Message }
function Invoke-Adb { throw '실제 ADB 호출 금지' }
Initialize-LocalPathApi
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('esde-v146-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$file = Join-Path $sandbox 'readable.txt'
Set-Content -LiteralPath $file -Value 'local content'
Assert-LocalSourcePath $file $sandbox
Write-Output 'PASS: 일반 파일, 네이티브 최종 경로 및 전체 읽기'

# Dropbox provider 없이 동일한 reparse metadata를 모의한다. 실제 읽기는 로컬 API를 사용한다.
$script:MockInfo = @{}
$script:FinalOverride = ''
$script:ReadCount = 0
function Get-LocalPathInfo([string]$Path) {
    if ($script:MockInfo.ContainsKey($Path)) { return $script:MockInfo[$Path] }
    return [EsdeLocalPath]::Inspect($Path)
}
function Test-LocalFileReadable([string]$Path, [bool]$Directory) {
    $script:ReadCount++
    if ($script:FinalOverride) { return $script:FinalOverride }
    return [EsdeLocalPath]::ReadLocal($Path, $Directory)
}
$cloud = [Convert]::ToUInt32('9000001A', 16)
$symlink = [Convert]::ToUInt32('A000000C', 16)
$junction = [Convert]::ToUInt32('A0000003', 16)
$script:MockInfo[$file] = [pscustomobject]@{Attributes=0x420; Tag=$cloud}
Assert-LocalSourcePath $file $sandbox
Check (@($script:Messages | Where-Object { $_ -match 'SOURCE ALLOW: local non-surrogate' }).Count -gt 0) 'cloud 허용 로그 누락'
Write-Output 'PASS: 정상 읽기 가능한 Dropbox형 reparse metadata'
foreach ($tag in @($symlink, $junction)) {
    $script:MockInfo[$file] = [pscustomobject]@{Attributes=0x420; Tag=$tag}
    $before = $script:ReadCount; $blocked = $false
    try { Assert-LocalSourcePath $file $sandbox } catch { $blocked = $true }
    Check $blocked '실제 링크 tag 차단 실패'
    Check ($script:ReadCount -eq $before) '차단된 링크 읽기 발생'
}
$script:MockInfo.Clear()
$script:MockInfo[$sandbox] = [pscustomobject]@{Attributes=0x410; Tag=$junction}
$blocked = $false
try { Assert-LocalSourcePath $file $sandbox } catch { $blocked = $true }
Check $blocked '원본 루트 junction 차단 실패'
$script:MockInfo.Clear()
$script:FinalOverride = Join-Path (Split-Path $sandbox -Parent) 'outside.txt'
$blocked = $false
try { Assert-LocalSourcePath $file $sandbox } catch { $blocked = $true }
Check $blocked '최종 경로 이탈 차단 실패'
$script:FinalOverride = ''
Write-Output 'PASS: symbolic link, junction, 루트 링크 및 최종 경로 이탈(모의)'
foreach ($flag in @(0x1000, 0x40000, 0x400000)) {
    $script:MockInfo[$file] = [pscustomobject]@{Attributes=(0x420 -bor $flag); Tag=$cloud}
    $before = $script:ReadCount; $blocked = $false
    try { Assert-LocalSourcePath $file $sandbox } catch { $blocked = $true }
    Check $blocked 'placeholder 차단 실패'
    Check ($script:ReadCount -eq $before) 'placeholder 데이터 읽기 발생'
}
$script:MockInfo.Clear()
$before = $script:ReadCount; $blocked = $false
try { Assert-LocalSourcePath $file $sandbox -EnumerationAttributes 0x40000 } catch { $blocked = $true }
Check $blocked '열거 전용 RecallOnOpen 차단 실패'
Check ($script:ReadCount -eq $before) '열거 placeholder 읽기 발생'
$lock = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $blocked = $false
    try { Assert-LocalSourcePath $file $sandbox } catch { $blocked = $true }
    Check $blocked '존재하지만 읽기 불가 파일 허용'
} finally { $lock.Dispose() }
Write-Output 'PASS: Offline/Recall placeholder 데이터 접근 차단 및 읽기 불가 파일'

$script:PreflightFail = $false; $script:StopFail = $false; $script:StartFail = $false
$script:Starts = 0; $script:Stops = 0
function Preflight-CheckForeground { if ($script:PreflightFail) { throw 'PREFLIGHT ORIGINAL' } }
function Stop-Esde { $script:Stops++; if ($script:StopFail) { throw 'STOP ORIGINAL' } }
function Start-Esde { $script:Starts++; if ($script:StartFail) { throw 'RESTART SECONDARY' } }
foreach ($scenario in @('preflight', 'stop', 'work', 'success', 'work-and-restart', 'success-restart-fail')) {
    $script:PreflightFail = $scenario -eq 'preflight'
    $script:StopFail = $scenario -eq 'stop'
    $script:StartFail = $scenario -in @('work-and-restart', 'success-restart-fail')
    $script:Starts = 0; $script:Stops = 0
    $caught = ''
    try {
        Invoke-EsdeSync { if ($scenario -in @('work', 'work-and-restart')) { throw 'WORK ORIGINAL' } }
    } catch { $caught = $_.Exception.Message }
    $expected = if ($scenario -in @('preflight', 'stop')) { 0 } else { 1 }
    Check ($script:Starts -eq $expected) ('재실행 횟수 오류: ' + $scenario)
    if ($scenario -eq 'preflight') { Check ($script:Stops -eq 0) 'preflight 실패 후 종료 발생' }
    if ($scenario -eq 'success') { Check ($caught -eq '') '성공 경로 오류' }
    elseif ($scenario -in @('work', 'work-and-restart')) { Check ($caught -eq 'WORK ORIGINAL') '원래 오류 유실' }
    elseif ($scenario -eq 'success-restart-fail') { Check ($caught -eq 'RESTART SECONDARY') '재실행 오류 유실' }
    else { Check ($caught -match 'ORIGINAL') '종료 전 오류 유실' }
    Write-Output ('PASS: ES-DE 복구 ' + $scenario + ' / starts=' + $script:Starts)
}
Check (@($script:Messages | Where-Object { $_ -match 'ESDE RESTART FAILED' }).Count -eq 2) '복구 실패 로그 누락'
Check (@($script:Messages | Where-Object { $_ -match 'ORIGINAL SYNC ERROR: WORK ORIGINAL' }).Count -eq 2) '원본 오류 로그 누락'
. (Join-Path $repo 'update-common.ps1')
$version = Get-AppVersion (Join-Path $repo 'version.json')
foreach ($path in @((Join-Path $repo 'ESDE-Sync.ps1'), (Join-Path $repo 'sync-worker.ps1'), (Join-Path $repo 'install.ps1'))) {
    Check ([IO.File]::ReadAllText($path) -match 'Get-AppVersion') ('단일 버전 읽기 누락: ' + $path)
}
Check ((Get-Content (Join-Path $repo 'README.txt') -TotalCount 1) -match ([regex]::Escape('v'+$version.version))) 'README 버전 불일치'
Write-Output ('PASS: 단일 버전 / PowerShell ' + $PSVersionTable.PSVersion)
Write-Output ('모의 파일 위치: ' + $sandbox)
