$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'unregistered-move-static.ps1')
$script:Passed=0
foreach($case in @(
 @{Path='_UNREGISTERED/existing.gb';Canonical='existing.gb';Body='EXISTING';Kind='single'},
 @{Path='_UNREGISTERED/existing.gb';Canonical='NewName.gb';Body='EXISTING';Kind='single'},
 @{Path='_TEST/t.gb';Canonical='t.gb';Body='TEST';Kind='single'},
 @{Path='_UNREGISTERED/existing.gb';Canonical='NewName.gb';Body='EXISTING';Kind='multiple'}
)){
 Setup;$Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
 [IO.File]::WriteAllText((Join-Path $SourceRoot ('roms/gb/'+$case.Canonical)),$case.Body)
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/other.gb'),'OTHER')
 if($case.Kind-ceq'multiple'){[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/Copy.gb'),$case.Body)}
 $node='<game custom="local"><path>./'+$case.Path+'</path><name>Local name</name><favorite>true</favorite><playcount>0</playcount><playtime/><lastplayed/><altemulator>Mystery (Standalone)</altemulator><unknown a="keep"/><!--keep--></game>'
 $local='<alternativeEmulator><label>Android</label></alternativeEmulator><gameList><game><path>./managed.gb</path><playcount>0</playcount></game>'+ $node+'</gameList>'
 Put $XmlRemote $local
 $XmlPlan=Prepare-GamelistSystem $XmlJob $Session -SnapshotOnly
 $master='<gameList><game><path>./managed.gb</path><name>Master</name></game><game><path>./'+$case.Canonical+'</path><name>Canonical</name></game><game><path>./other.gb</path><name>Other</name></game>'
 if($case.Kind-ceq'multiple'){$master+='<game><path>./Copy.gb</path><name>Copy</name></game>'}
 $master+='</gameList>'
 $XmlJob.GamelistSource=ConvertFrom-EsdeGamelistBytes (Bytes $master)
 $p=Prepare
 $entry=@($p.Inventory|Where-Object RelativePath -CEQ $case.Path)[0]
 if($case.Kind-ceq'single'){
  Check ($entry.Classification-ceq'LOCAL_ONLY_MANAGED_MATCH' -and $entry.Action-ceq'PRESERVE_AND_REVIEW') ($case.Path+' single managed match')
 }else{Check ($entry.Classification-ceq'AMBIGUOUS' -and $entry.Action-ceq'REVIEW' -and $entry.MatchedShaPaths.Count-eq2) 'local-only multiple candidates ambiguous'}
 Check ($entry.IsLocalOnly -and $entry.MatchedShaPaths-ccontains$case.Canonical) 'namespace protected; canonical candidate recorded'
 Check ($p.ReviewRequired -and $p.ProtectMedia -and $p.ReviewIsolation.HoldMedia) 'review/media hold'
 Check ($p.Moves.Count-eq0) 'local-only move/rename plan zero'
 $sum=Get-RomReviewSummary $p.Inventory
 Check ($sum.LocalOnlyCount-eq2 -and $sum.ReviewCount-eq1 -and $sum.UnmanagedMoveCount-eq0) 'independent local-only/review axes'
 $notice=Get-RomClassificationNotice $entry
 Check (-not[string]::IsNullOrWhiteSpace($notice.Message)) 'Korean notice'
 $bound=Read-EsdeGamelist $p.XmlPlan.Output
 $existing=$bound.Document.DocumentElement.SelectSingleNode('gameList/game[path="./'+$case.Path+'"]')
 $original=(ConvertFrom-EsdeGamelistBytes (Bytes ('<gameList>'+$node+'</gameList>'))).Document.DocumentElement.SelectSingleNode('gameList/game')
 Check ($existing.OuterXml-ceq$original.OuterXml) 'local node whole-node/path/runtime/altemulator/unknown preserved'
 Check ($null-eq$bound.Document.DocumentElement.SelectSingleNode('gameList/game[path="./'+$case.Canonical+'"]')) 'canonical game duplicate absent'
 Confirm-ClassificationInventory $p $Session
 Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
 Check (-not$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/'+$case.Canonical)) 'canonical ROM push suppressed'
 if($case.Kind-ceq'multiple'){Check (-not$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Copy.gb')) 'all ambiguous candidate pushes suppressed'}
 Check ((Hash $Remote['/storage/emulated/0/ROMs/gb/'+$case.Path])-ceq(Hash (Bytes $case.Body))) 'local ROM SHA preserved'
 Check ((Hash $Remote['/storage/emulated/0/ROMs/gb/other.gb'])-ceq(Hash (Bytes 'OTHER'))) 'unrelated managed push continues'
 Check (@($Calls|Where-Object {$_-match'(push |mv |rm ).*/_(TEST|UNREGISTERED)/'}).Count-eq0) 'local-only overwrite/delete/move zero'
 Check (@($Calls|Where-Object {$_-match'(push |mv |rm ).*(saves|states|downloaded_media)'}).Count-eq0) 'save/state/media mutation zero'
}
Setup;$Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb');$p=Prepare
Check (@($p.Inventory|Where-Object Classification -CEQ LOCAL_ONLY).Count-eq2 -and -not$p.ReviewRequired) 'unmatched local-only stays Preserve'
Setup;$Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/Canonical.gb'),'EXISTING')
$XmlJob.GamelistSource=ConvertFrom-EsdeGamelistBytes (Bytes '<gameList><game><path>./Canonical.gb</path><name>New</name></game></gameList>')
$p=Prepare;$bound=Read-EsdeGamelist $p.XmlPlan.Output
Check ($null-eq$bound.Document.DocumentElement.SelectSingleNode('gameList/game[path="./Canonical.gb"]') -and $null-eq$bound.Document.DocumentElement.SelectSingleNode('gameList/game[path="./_UNREGISTERED/existing.gb"]')) 'no existing local node -> no synthetic/duplicate'
Setup;[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/Canonical.gb'),'EXISTING')
$p=Prepare;Apply $p;Confirm-ClassificationInventory $p $Session
$s=Get-RomReviewSummary $p.Inventory
Check ($s.UnmanagedMoveCount-eq1 -and $s.LocalOnlyCount-eq2 -and $s.ReviewCount-eq1) 'newly moved ROM not double counted/reviewed'
Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/existing.gb' 'CHANGED'
Reject 'local-only managed presence concurrent change' {Confirm-ClassificationInventory $p $Session}
$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$null,[ref]$null)
$f=$a.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq'Format-SyncCompletionMessage'},$false)[0];. ([scriptblock]::Create($f.Extent.Text))
$t=Format-SyncCompletionMessage $s
Check ($t.Contains('중복 전송') -and $t.Contains('기기의 ROM을 보존') -and $t-notmatch'LOCAL_ONLY_MANAGED_MATCH|[a-f0-9]{64}') 'GUI plain Korean no enum/SHA'
$unknown=New-ManagedCanonicalizationPlan $entry $null @() @()
Check ($unknown.Status-ceq'REVIEW' -and $unknown.Operations.Count-eq0) 'canonical migration not enabled'
Reject 'unsupported classifier unchanged' {New-UnregisteredClassificationPlan gba @() @() @() @('gba')}
'local-only managed match 검증 완료: '+$script:Passed