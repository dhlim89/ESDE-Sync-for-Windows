# production main은 실행하지 않는다. 기존 mock ADB/ROM/XML fixture를 재사용한다.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'unregistered-move-static.ps1')
$script:Passed=0
function Summary($p){Get-RomReviewSummary @($p.Inventory)}
foreach($kind in @('test','unregistered','both')){
 Setup
 $Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
 if($kind-ceq'test'){$Remote.Remove('/storage/emulated/0/ROMs/gb/_UNREGISTERED/existing.gb')}
 if($kind-ceq'unregistered'){$Remote.Remove('/storage/emulated/0/ROMs/gb/_TEST/t.gb')}
 $p=Prepare;$sum=Summary $p
 $expected=if($kind-ceq'both'){2}else{1}
 Check ($sum.LocalOnlyCount-eq$expected) ($kind+' runtime inventory local-only count')
 Check ($sum.ManagedCount-eq1 -and $sum.UnmanagedMoveCount-eq0 -and $sum.ReviewCount-eq0) ($kind+' other counts unchanged')
 Check (@($Calls|Where-Object {$_-match'(pull |sha256sum ).*/_(TEST|UNREGISTERED)/'}).Count-eq0) ($kind+' protected bytes not read/transferred')
}
# local-only sidecars/미확정 extension은 ROM count에 넣지 않고 보존한다.
Setup;$Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
Put '/storage/emulated/0/ROMs/gb/_TEST/notes.txt' 'NOT A ROM'
Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/local.sav' 'SAVE'
$p=Prepare;$sum=Summary $p
Check ($sum.LocalOnlyCount-eq2) 'only verified local-only ROM extensions counted'
Check ($Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_TEST/notes.txt') -and $Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/local.sav')) 'local-only auxiliary files untouched'
# 시작 inventory를 summary에 사용한다. 이동 후 LOCAL_ONLY로 재분류돼도 이번 이동 건수와 중복하지 않는다.
Setup;$p=Prepare;$sum=Summary $p
Check ($sum.UnmanagedMoveCount-eq1 -and $sum.LocalOnlyCount-eq2) 'before move: one new move, two existing local-only'
Apply $p;Confirm-ClassificationInventory $p $Session
$sum=Summary $p
Check ($sum.UnmanagedMoveCount-eq1 -and $sum.LocalOnlyCount-eq2) 'after move: immutable start inventory avoids duplicate count'
$afterRows=@(Get-ClassificationAndroidRows $RomJob $Session -IncludeLocalOnly)
$after=@(New-UnregisteredClassificationPlan gb $p.Source $afterRows @() @('gb'))
Check (@($after|Where-Object Classification -CEQ LOCAL_ONLY).Count-eq3) 'post-move physical local-only three; not completion start count'
Check ($sum.ManagedCount-eq1 -and $sum.ReviewCount-eq0) 'move managed/review count regression'
# 여러 Supported 시스템만 집계하며 unsupported의 보호 파일을 억지로 포함하지 않는다.
$entries=@()
foreach($i in 1..40){$entries+=[pscustomobject]@{System='gb';Classification='MANAGED';Action='SYNC'}}
foreach($i in 1..57){$entries+=[pscustomobject]@{System='gbc';Classification='MANAGED';Action='SYNC'}}
foreach($path in @('_TEST/Test.gb','_UNREGISTERED/Local.gb')){$entries+=[pscustomobject]@{System='gb';RelativePath=$path;Classification='LOCAL_ONLY';Action='PRESERVE'}}
$sum=Get-RomReviewSummary $entries
Check ($sum.ManagedCount-eq97 -and $sum.UnmanagedMoveCount-eq0 -and $sum.LocalOnlyCount-eq2 -and $sum.ReviewCount-eq0) 'GB two + GBC zero: actual 97/0/2/0'
$entries+=[pscustomobject]@{System='gba';Classification='LOCAL_ONLY';Action='PRESERVE'}
$sum=Get-RomReviewSummary $entries
Check ($sum.LocalOnlyCount-eq2) 'unsupported local-only excluded defensively'
$entries=@()
foreach($kind in @('MANAGED','MANAGED_CONFLICT','MANAGED_PATH_MISMATCH','AMBIGUOUS','INVALID')){
 $action=switch($kind){'MANAGED'{'SYNC'}'MANAGED_CONFLICT'{'PRESERVE_AND_WARN'}'INVALID'{'BLOCK'}default{'REVIEW'}}
 $entry=[pscustomobject]@{System='gb';RelativePath='x.gb';Classification=$kind;Action=$action;MatchedDropboxPaths=@();MatchedShaPaths=@();Sha256=('a'*64);AndroidSha256=('a'*64);ManagedSha256=('b'*64);Reason='fixture'}
 $sum=Get-RomReviewSummary @($entry)
 Check ($sum.LocalOnlyCount-eq0) ($kind+' excluded from local-only')
}
# 기존 GUI formatter는 수정하지 않는다.
$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$null,[ref]$null)
$f=$a.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq'Format-SyncCompletionMessage'},$false)[0]
. ([scriptblock]::Create($f.Extent.Text))
$sum=[pscustomobject]@{ManagedCount=97;UnmanagedMoveCount=0;LocalOnlyCount=2;ReviewCount=0;Items=@()}
$expected=@('동기화 완료','','관리 ROM: 97','비관리 ROM 이동: 0','로컬 전용: 2','확인 필요: 0')-join[Environment]::NewLine
Check ((Format-SyncCompletionMessage $sum)-ceq$expected) 'exact GUI 97/0/2/0 text'
# 수신 상태 JSON에서도 canonical fields만 그대로 전달한다.
$StatusFile=Join-Path $root 'summary-status.json';Write-Status done '동기화 완료' 1 1 $sum
$saved=Get-Content $StatusFile -Raw -Encoding UTF8|ConvertFrom-Json
Check ($saved.summary.LocalOnlyCount-eq2 -and (Format-SyncCompletionMessage $saved.summary)-ceq$expected) 'status JSON to GUI local-only unchanged'
Check (@($saved.summary.PSObject.Properties.Name|Where-Object {$_-match'MovedTo'}).Count-eq0) 'no alias'
# mirror의 예약 prune는 그대로이며 classification의 include flag는 준비 단계에만 쓰인다.
Setup;$p=Prepare
Check (@(Get-RemoteFiles $RomJob.RemotePath|Where-Object {Is-LocalOnlyRelativePath $_}).Count-eq0) 'destructive mirror listing still excludes local-only'
Check (@($p.Moves|Where-Object {Is-LocalOnlyRelativePath $_.RelativePath}).Count-eq0) 'local-only never classified as move source'
Write-Output ('local-only summary 검증 완료: '+$script:Passed)