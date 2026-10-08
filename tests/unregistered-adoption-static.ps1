# AST로 production 순수 함수 정의만 로드한다. worker entrypoint/ADB/Dropbox는 실행하지 않는다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$work){$blocked=$false;try{& $work|Out-Null}catch{$blocked=$true};Check $blocked ($name+' 차단')}
function Doc($text){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($text))}
$sha='a'*64;$other='b'*64
$c=[pscustomobject]@{System='gb';RelativePath='_UNREGISTERED/sub/Mole Mania.gb';AndroidSha256=$sha;StagedSha256=$sha}
$plan=@(New-UnregisteredAdoptionPlan @($c) @() @('gb'))
Check ($plan.Count-eq1 -and $plan[0].Action-ceq'InstallNew') '신규 ROM 채택 계획'
Check ($plan[0].ManagedPath-ceq'./sub/Mole Mania.gb') '상대 하위 구조 유지'
Check (-not$plan[0].RemoveAndroidSource) '계획만으로 원본 삭제 금지'
$d=[pscustomobject]@{System='gb';RelativePath='sub/Mole Mania.gb';Sha256=$sha}
Check ((New-UnregisteredAdoptionPlan @($c) @($d) @('gb')).Action-ceq'ReuseIdentical') '동일 SHA 목적지/중간 재실행 중복 설치 없음'
$d.Sha256=$other
Reject '다른 SHA 충돌 전체 계획' {New-UnregisteredAdoptionPlan @($c) @($d) @('gb')}
$bad=$c|ConvertTo-Json|ConvertFrom-Json;$bad.StagedSha256=$null
Reject 'pull 실패' {New-UnregisteredAdoptionPlan @($bad) @() @('gb')}
$bad.StagedSha256=$other
Reject 'pull/hash 실패' {New-UnregisteredAdoptionPlan @($bad) @() @('gb')}
foreach($path in @('_TEST/a.gb','folder/_UNREGISTERED/a.gb','_UNREGISTERED/../a.gb','_UNREGISTERED/_TEST/a.gb','_UNREGISTERED/CON.gb','_UNREGISTERED/a.gb.','C:\_UNREGISTERED\a.gb','/storage/a.gb','_UNREGISTERED/a?.gb')){
 Reject $path {Get-UnregisteredAdoptionPath 'gb' $path @('gb')}
}
Reject '비선택 시스템' {Get-UnregisteredAdoptionPath 'gbc' '_UNREGISTERED/a.gbc' @('gb')}
$second=$c|ConvertTo-Json|ConvertFrom-Json;$second.RelativePath='_UNREGISTERED/sub/mole mania.gb'
Reject 'Windows 목적지 대소문자 충돌/중복 game 후보' {New-UnregisteredAdoptionPlan @($c,$second) @() @('gb')}
foreach($state in @('discovered','staged','source-verified','dropbox-installed','gamelist-prepared','dropbox-gamelist-installed','android-rom-installed')){
 Check (-not(Get-AdoptionSourceRemovalDecision $state $true $true $true $true $true $true)) ($state+' 원본 삭제 차단')
 Check ((Get-AdoptionResumeDisposition $state)-ceq'BlockedManualReview') ($state+' 중단 재실행 차단')
}
Check (-not(Get-AdoptionSourceRemovalDecision 'android-gamelist-installed' $false $true $true $true $true $true)) 'Dropbox install 실패 원본 보존'
Check (-not(Get-AdoptionSourceRemovalDecision 'android-gamelist-installed' $true $false $true $true $true $true)) 'Dropbox gamelist 실패 원본 보존'
Check (-not(Get-AdoptionSourceRemovalDecision 'android-gamelist-installed' $true $true $false $true $true $true)) 'Android gamelist 실패 원본 보존'
Check (-not(Get-AdoptionSourceRemovalDecision 'android-gamelist-installed' $true $true $true $false $true $true)) '원본 concurrent 변경 삭제 차단'
Check (Get-AdoptionSourceRemovalDecision 'android-gamelist-installed' $true $true $true $true $true $true) '모든 검증 완료 후에만 삭제 gate 열림'
Check ((Get-AdoptionResumeDisposition 'failed')-ceq'BlockedManualReview') 'Android 원본 삭제 실패 후 journal 차단'
Check ((Get-AdoptionResumeDisposition 'completed')-ceq'VerifyCompleted') '완료 재실행 검증 전용'
# 위 테스트는 계획/삭제 gate만 검증한다. 실제 I/O failure rollback은 Stage 2 테스트 대상.
foreach($name in @('Get-UnregisteredAdoptionPath','New-UnregisteredAdoptionPlan','Get-AdoptionSourceRemovalDecision','Get-AdoptionResumeDisposition')){
 $fn=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq$name},$false)
 $calls=@($fn.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]},$false)|ForEach-Object GetCommandName)
 Check (-not@($calls|Where-Object {$_-in@('Invoke-Adb','Remove-Item','Move-Item','Copy-Item')}).Count) ($name+' 실제 mutation 없음')
}
$inbox=(Doc '<gameList><game><path>./_UNREGISTERED/a.gb</path><name>Local</name><playcount>7</playcount><lastplayed>20261008T120000</lastplayed><playtime>99</playtime><unknown>preserve</unknown></game></gameList>').Document.DocumentElement.SelectSingleNode('gameList/game')
$p=New-AdoptionGamePromotion $inbox './a.gb' $null $null
Check ($p.DropboxNode.SelectSingleNode('path').InnerText-ceq'./a.gb' -and $p.AndroidNode.SelectSingleNode('path').InnerText-ceq'./a.gb') 'Dropbox/Android 양쪽 정식 path proposal'
Check ($null-eq$p.DropboxNode.SelectSingleNode('playcount') -and $p.AndroidNode.SelectSingleNode('playcount').InnerText-ceq'7') '공유 새 metadata와 기기 runtime 분리'
Check ($p.DropboxNode.SelectSingleNode('unknown').InnerText-ceq'preserve' -and $p.AndroidNode.SelectSingleNode('unknown').InnerText-ceq'preserve') '신규 entry unknown metadata 양쪽 보존'
Check ($inbox.SelectSingleNode('path').InnerText-ceq'./_UNREGISTERED/a.gb') 'Android 원본 metadata 불변'
$baseNode=(Doc '<gameList><game><path>./a.gb</path><name>Dropbox</name><playcount>2</playcount></game></gameList>').Document.DocumentElement.SelectSingleNode('gameList/game')
$p=New-AdoptionGamePromotion $inbox './a.gb' $baseNode $null
Check ($p.AndroidNode.SelectSingleNode('name').InnerText-ceq'Dropbox' -and $p.AndroidNode.SelectSingleNode('playcount').InnerText-ceq'7') '기존 정식 BASE 우선 + local runtime'
Check (-not(New-AdoptionGamePromotion $null './a.gb' $null $null).CreateGame) 'ROM만 존재하면 새 game 합성 안 함'
$existing=$baseNode.CloneNode($true)
Reject '정식/예약 중복 runtime 충돌' {New-AdoptionGamePromotion $inbox './a.gb' $baseNode $existing}
$flagged=$inbox.CloneNode($true);$flag=$flagged.OwnerDocument.CreateElement('favorite');$flag.InnerText='true';[void]$flagged.AppendChild($flag)
Check (New-AdoptionGamePromotion $flagged './a.gb' $null $null).NeedsPolicyDecision '미확정 preference 공유는 adoption commit 전 정책 gate'
Reject '예약 target 승격' {New-AdoptionGamePromotion $inbox './_TEST/a.gb' $null $null}
Check (-not(Get-AdoptionSourceRemovalDecision 'android-gamelist-installed' $true $true $true $true $false $true)) 'Android 정식 ROM 미검증 원본 보존'
Check (-not(Get-AdoptionSourceRemovalDecision 'android-gamelist-installed' $true $true $true $true $true $false)) '공유 metadata 미확정 원본 보존'
$notRom=$c|ConvertTo-Json|ConvertFrom-Json;$notRom.RelativePath='_UNREGISTERED/systeminfo.txt'
Reject 'non-ROM inbox 파일' {New-UnregisteredAdoptionPlan @($notRom) @() @('gb')}
Reject 'wrong promotion path' {New-AdoptionGamePromotion $inbox './different.gb' $null $null}
$canonicalDest=[pscustomobject]@{System='gb';RelativePath='sub/MOLE MANIA.gb';Sha256=$sha}
Check ((New-UnregisteredAdoptionPlan @($c) @($canonicalDest) @('gb')).ManagedPath-ceq'./sub/MOLE MANIA.gb') '동일 SHA 재사용 시 기존 source path 대소문자 보존'
Write-Output ('adoption 순수 계획 검증 완료: '+$script:Passed)