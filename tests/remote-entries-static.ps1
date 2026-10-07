# 실제 ADB/Android 호출 없이 명령 생성, prune 모델, NUL 파서를 검증한다.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
function Check($value, $message) { if (-not $value) { throw $message } }
$ReservedFolders = @('_TEST', '_UNREGISTERED')
$Buckets = @(@{Remote='/storage/emulated/0/ROMs'}, @{Remote='/storage/emulated/0/ES-DE/gamelists'}, @{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$selectedSystems = @('uzebox'); $Serial = 'MOCK'
$root = '/storage/emulated/0/ROMs/uzebox'
$script:Raw = $null; $script:Code = 0; $script:Stderr = ''; $script:Visited = @(); $script:Command = ''
# 고정 트리로 예약 하위가 visited에 들어가지 않는지도 확인한다.
$tree = @(
    @{Path='';Type='d'}, @{Path='systeminfo.txt';Type='f'},
    @{Path='normal';Type='d'}, @{Path='normal/a.txt';Type='f'}, @{Path='empty';Type='d'},
    @{Path='_TEST';Type='d'}, @{Path='_TEST/keep-test.txt';Type='f'},
    @{Path='_TEST/nested';Type='d'}, @{Path='_TEST/nested/x.txt';Type='f'},
    @{Path='_UNREGISTERED';Type='d'}, @{Path='_UNREGISTERED/keep-unregistered.txt';Type='f'}
)
function Invoke-Adb {
    $script:Command = $args[-1]
    Check ($script:Command -notmatch '-mindepth|-depth|-L|-H') 'depth/follow 옵션 회귀'
    $type = if ($script:Command -match '-type f -print0') { 'f' } elseif ($script:Command -match '-type d -print0') { 'd' } else { throw '잘못된 조회 식' }
    $prune = @([regex]::Matches($script:Command, "-iname '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    Check ($prune.Count -eq 2 -and $prune -contains '_TEST' -and $prune -contains '_UNREGISTERED') '공통 예약 prune 누락'
    Check ($script:Command.Contains("\( -iname '_TEST' -o -iname '_UNREGISTERED' \) -prune -o -type $type -print0")) '명령 그룹 구조 오류'
    $script:Visited = @()
    $out = @()
    foreach ($entry in $tree) {
        $segments = $entry.Path -split '/'
        if ($segments.Count -gt 1 -and $prune -contains $segments[0]) { continue }
        $script:Visited += $entry.Path
        if ($prune -contains $entry.Path) { continue }
        if ($entry.Type -eq $type) { $out += $(if ($entry.Path) { $root + '/' + $entry.Path } else { $root }) }
    }
    $stdout = if ($null -ne $script:Raw) { $script:Raw } elseif ($out.Count) { ($out -join [char]0) + [char]0 } else { '' }
    return [pscustomobject]@{Code=$script:Code;StdErr=$script:Stderr;StdOut=$stdout;Output=@()}
}
$files = @(Get-RemoteFiles $root)
Check (($files -join '|') -ceq 'systeminfo.txt|normal/a.txt') '일반 파일 fixture 불일치'
Check (@($script:Visited | Where-Object { $_ -match '^(_TEST|_UNREGISTERED)/' }).Count -eq 0) '예약 하위 탐색 발생'
$dirs = @(Get-RemoteDirs $root)
Check (($dirs -join '|') -ceq 'normal|empty') '일반/빈 폴더 fixture 불일치'
Check ($dirs -notcontains $root -and $dirs -notcontains 'uzebox') '시스템 루트 출력 회귀'
Write-Output 'PASS: fixture 파일/폴더 목록, 정확한 시작점 제외, 예약 자체/하위 prune, 빈 폴더'

$special = "normal/공백 (괄호) 'quote' [x] & `$ dollar.txt"
$script:Raw = $root + '/' + $special + [char]0
Check (@(Get-RemoteFiles $root)[0] -ceq $special) '특수문자 파일명 손상'
$selectedSystems = @("uzebox ' (test) & `$", 'uzebox')
$quotedRoot = "/storage/emulated/0/ROMs/uzebox ' (test) & `$"
$script:Raw = $quotedRoot + '/a.txt' + [char]0
Check (@(Get-RemoteFiles $quotedRoot)[0] -ceq 'a.txt') '특수문자 루트 파싱 실패'
Check ($script:Command.Contains('find ' + (Quote-Sh $quotedRoot) + ' ')) '루트 shell 인용 누락'
Write-Output 'PASS: 공백/괄호/따옴표/한글/특수문자 및 루트 shell 인용'
$selectedSystems = @('uzebox')
foreach ($bad in @('/storage/emulated/0/ROMs/gb/a.txt', "$root-other/a.txt", "$root/../gb/a.txt", "$root/_TEST/keep.txt", "$root/_UNREGISTERED/nested/keep.txt", "$root/normal/_TEST/keep.txt", "$root/a`nb.txt", $root)) {
    $script:Raw = $bad + [char]0
    $blocked = $false
    try { [void]@(Get-RemoteFiles $root) } catch { $blocked = $true }
    Check $blocked ('잘못된 원격 결과 허용: ' + $bad)
}
# 정확한 시작점 이외의 trailing slash/루트 유사 결과도 통과시키지 않는다.
$script:Raw = $root + '/' + [char]0
$blocked = $false
try { [void]@(Get-RemoteDirs $root) } catch { $blocked = $true }
Check $blocked '시작점 유사 경로 허용'
$script:Raw = $root + '/a.txt'
$blocked = $false
try { [void]@(Get-RemoteFiles $root) } catch { $blocked = $true }
Check $blocked 'NUL 종료 누락 허용'
Write-Output 'PASS: 범위 밖/미선택/예약/제어문자/잘못된 형식 차단'
foreach ($failure in @('exit', 'stderr')) {
    $script:Raw = ''; $script:Code = if ($failure -eq 'exit') { 1 } else { 0 }
    $script:Stderr = if ($failure -eq 'stderr') { 'find: permission denied' } else { '' }
    $blocked = $false
    try { [void]@(Get-RemoteFiles $root) } catch { $blocked = $true }
    Check $blocked 'find 실패를 빈 목록으로 취급'
}
$script:Code = 0; $script:Stderr = ''; $script:Raw = ''
Check (@(Get-RemoteFiles $root).Count -eq 0) '성공한 빈 파일 목록 오류'
Check (@(Get-RemoteDirs $root).Count -eq 0) '성공한 빈 폴더 목록 오류'
Write-Output ('PASS: ADB/find 오류와 정상 빈 목록 구분 / PowerShell ' + $PSVersionTable.PSVersion)
