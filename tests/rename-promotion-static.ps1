$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
. (Join-Path $PSScriptRoot 'support/rename-promotion-proposal.ps1')
$ReservedFolders=@('_TEST','_UNREGISTERED');$script:Passed=0
function Check($ok,$name){if(-not$ok){throw $name};$script:Passed++;'PASS: '+$name}
function Xml($s){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($s))}
function Asset($path,$sha=('b'*64)){[pscustomobject]@{RelativePath=$path;Sha256=$sha;Size=32;Kind='File';IsLink=$false}}
function Setup($source='_UNREGISTERED/OldName.gb',$canonical='NewName.gb',$extra=''){
 $script:SourcePath=$source;$script:Canonical=$canonical;$script:Android=@([pscustomobject]@{System='gb';RelativePath=$source;Sha256=('a'*64)})
 $script:Managed=@([pscustomobject]@{System='gb';RelativePath=$canonical;Sha256=('a'*64)})
 $script:Entry=@(New-UnregisteredClassificationPlan gb $Managed $Android @() @('gb','gbc'))[0]
 $script:Local=Xml ('<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>./'+$source+'</path><name>Local</name><playcount>0</playcount><playtime/><lastplayed/>'+$extra+'</game></gameList>')
 $script:Master=Xml ('<gameList><game><path>./'+$canonical+'</path><name>Managed</name><playcount>99</playcount></game></gameList>')
 $script:Evidence=[pscustomobject]@{Verified=$true;Core='SameBoy';System='gb';CompleteAssetInventory=$true;CompleteMediaInventory=$true;CompleteSameBoyContentInventory=$true;PathIndependent=$true;Reference='MOCK ONLY: not actual rename/runtime evidence';ManagedContents=$Managed}
 $script:Saves=@();$script:States=@();$script:Media=@();$script:ManagedMedia=@()
}
function Plan {New-RenamePromotionProposal $Entry $Android $Local $Master $Evidence $Saves $States $Media $ManagedMedia}
function SetupIO($p){
 $script:Files=@{};foreach($op in $p.Operations){$script:Files[$op.Root+'/'+$op.SourceRelativePath]=$op.ExpectedSha256}
 $script:Events=New-Object 'Collections.Generic.List[string]';$script:LastRecovery=$null;$script:FailSave=$false;$script:FailState=$false;$script:FailXml=$false;$script:BadXmlEvidence=$false;$script:XmlCommitted=$false;$script:Refreshed=$false;$script:Moves=0
 $script:IO=[pscustomobject]@{Mode='Mock';Stat={param($path)[pscustomobject]@{Exists=$script:Files.ContainsKey($path);Kind='File';IsLink=$false;Sha256=$script:Files[$path];Size=32;Device='dev1'}};Parent={param($root,$path,$create)[pscustomobject]@{Safe=$path.StartsWith($root+'/',[StringComparison]::Ordinal)-or$path-ceq$root;Exists=$true;Kind='Directory';CanonicalPath=$path;Device='dev1'}};MoveNoClobber={param($s,$d)if(($script:FailSave-and$s.Contains('/saves/'))-or($script:FailState-and$s.Contains('/states/'))){throw 'mock injected asset move failure'};if($script:Files.ContainsKey($d)){throw 'mock no clobber'};$script:Files[$d]=$script:Files[$s];[void]$script:Files.Remove($s);$script:Moves++};Record={param($phase,$e)$script:Events.Add($phase);if($phase-ceq'recovery-needed'){$script:LastRecovery=$e}};ValidateEvidence={param($proposal)if($script:BadXmlEvidence){throw 'mock master/local XML fingerprint changed'}};CommitXml={param($xml,$fingerprints)if($script:FailXml){throw 'mock XML commit failure'};$script:XmlCommitted=$true};Refresh={param($proposal)$row=[pscustomobject]@{RelativePath=$proposal.CanonicalRelativePath;Sha256=$script:Files['/storage/emulated/0/ROMs/gb/'+$proposal.CanonicalRelativePath]};$classification=@(New-UnregisteredClassificationPlan gb @([pscustomobject]@{RelativePath=$row.RelativePath;Sha256=$row.Sha256}) @($row) @() @('gb'))[0];if($classification.Classification-cne'MANAGED'){throw 'refresh not managed'};$script:Refreshed=$true}}
}
function Reject($body,$name){$hit=$false;try{& $body|Out-Null}catch{$hit=$true};Check $hit $name}
Setup;$p=Plan;Check ($p.Eligible-and$p.Action-ceq'PROMOTE_WITH_RENAME') 'rename-only same SHA no assets safe proposal'
Check ($p.MediaAction-ceq'HOLD'-and$p.Operations.Count-eq1) 'no local media first-run HOLD; ROM only asset set'
Setup '_UNREGISTERED/Game.gb' 'Game.gb';Check ((Plan).ChangeType-ceq'SAME_NAME'-and-not(Plan).Eligible) 'same-name delegates existing v1.6'
Setup '_UNREGISTERED/Hacks/Game.gb' 'Game.gb';Check ((Plan).ChangeType-ceq'PATH_ONLY'-and-not(Plan).Eligible) 'path-only REVIEW'
Setup '_UNREGISTERED/Hacks/Game.gb' 'RPG/New.gb';Check ((Plan).ChangeType-ceq'RENAME_AND_PATH'-and-not(Plan).Eligible) 'rename and path REVIEW'
Setup '_TEST/OldName.gb';Check (-not(Plan).Eligible) '_TEST never rename promoted'
Setup '_UNREGISTERED/OldName.gb' 'oldname.gb';Check ((Plan).ChangeType-ceq'CASE_ONLY'-and-not(Plan).Eligible) 'case-only REVIEW'
foreach($ext in @('.srm','.rtc')){Setup;$Saves=@(Asset ('SameBoy/OldName'+$ext));$p=Plan;Check ($p.Eligible-and@($p.Operations|Where-Object Kind -CEQ Save).Count-eq1) ($ext+' explicit save rename candidate')}
Setup;$States=@(Asset 'SameBoy/OldName.state');Check ((Plan).Eligible-and(Plan).AssetPlan.Operations.Count-eq1) 'standard state rename candidate'
Setup;$Saves=@((Asset 'SameBoy/OldName.srm'),(Asset 'SameBoy/NewName.srm'));Check (-not(Plan).Eligible) 'same-SHA save destination REVIEW no deletion'
Setup;$Saves=@((Asset 'SameBoy/OldName.srm'),(Asset 'SameBoy/NewName.srm' ('c'*64)));Check (-not(Plan).Eligible) 'different-SHA save destination REVIEW'
Setup;$Saves=@(Asset 'SameBoy/NewName.srm');Check (-not(Plan).Eligible) 'destination-only save ownership unknown REVIEW'
Setup;$States=@((Asset 'SameBoy/OldName.state1'),(Asset 'SameBoy/OldName.state2'));Check (-not(Plan).Eligible) 'state slots mapping potential but runtime unverified REVIEW'
Setup;$States=@(Asset 'SameBoy/OldName.state.auto');Check (-not(Plan).Eligible) 'autostate naming REVIEW'
Setup;$Saves=@(Asset 'OtherCore/OldName.srm');Check (-not(Plan).Eligible) 'other core directory REVIEW'
Setup;$Saves=@(Asset 'SameBoy/OldName.sav');Check (-not(Plan).Eligible) 'unknown save extension REVIEW'
Setup;$Saves=@(Asset 'SameBoy/oldname.srm');Check (-not(Plan).Eligible) 'case variant source REVIEW'
Setup;$Saves=@(Asset 'SameBoy/OldName.srm');$Saves[0].IsLink=$true;Check (-not(Plan).Eligible) 'asset symlink REVIEW'
Setup;$Saves=@(Asset '../OldName.srm');Check (-not(Plan).Eligible) 'asset traversal REVIEW'
Setup;$ManagedMedia=@(Asset 'covers/NewName.png');Check ((Plan).Eligible-and(Plan).MediaAction-ceq'HOLD') 'managed canonical media only SAFE/HOLD'
Setup;$Media=@(Asset 'covers/OldName.png');$p=Plan;Check (-not$p.Eligible-and$p.MediaPlan.Status-ceq'LOCAL_MEDIA_RENAMEABLE'-and$p.MediaPlan.Candidates.Count-eq1-and$p.Operations.Count-eq0) 'local media one-to-one diagnostic candidate not executable'
Setup;$Media=@((Asset 'covers/OldName.png'),(Asset 'covers/NewName.png'));Check ((Plan).MediaPlan.Status-ceq'MEDIA_COLLISION_OR_UNKNOWN') 'old/new same SHA media collision REVIEW'
Setup;$Media=@(Asset 'covers/OldName.png');$ManagedMedia=@(Asset 'covers/NewName.png' ('c'*64));Check (-not(Plan).Eligible) 'master media and old local media never decide/delete'
Setup;$Media=@(Asset 'custom/OldName.png');Check (-not(Plan).Eligible) 'unknown media category REVIEW'
Setup;$Media=@(Asset 'covers/Hacks/OldName.png');Check (-not(Plan).Eligible) 'nested media layout REVIEW'
Setup '_UNREGISTERED/OldName.gb' 'NewName.gb' '<custom>x</custom>';Check (-not(Plan).Eligible) 'unknown local XML REVIEW'
Setup;$Local.Document.SelectSingleNode('//game').SetAttribute('custom','x');$Local.Bytes=ConvertTo-EsdeGamelistBytes $Local;Check (-not(Plan).Eligible) 'custom attribute REVIEW'
Setup '_UNREGISTERED/OldName.gb' 'NewName.gb' '<!--local-->';Check (-not(Plan).Eligible) 'comment loss REVIEW'
Setup;$p=Plan;$game=@(Get-EsdeGameEntries $p.PreparedXml)[0].Node;Check ($game.SelectSingleNode('playcount').InnerText-ceq'0'-and$game.SelectSingleNode('playtime').InnerText-ceq''-and$game.SelectSingleNode('lastplayed').InnerText-ceq'') 'runtime zero/empty preserved'
Check ($game.SelectSingleNode('name').InnerText-ceq'Managed') 'master metadata authoritative'
Check ($p.PreparedXml.Document.SelectSingleNode('//alternativeEmulator/label').InnerText-ceq'SameBoy') 'system alternativeEmulator preserved'
Check (@(Get-EsdeGameEntries $p.PreparedXml).Count-eq1-and@(Get-EsdeGameEntries $p.PreparedXml|Where-Object Key -CEQ './_UNREGISTERED/OldName.gb').Count-eq0) 'canonical one node no old/synthetic duplicate'
Setup;$Android+=@([pscustomobject]@{System='gb';RelativePath='NewName.gb';Sha256=('a'*64)});Check (-not(Plan).Eligible) 'ROM destination same SHA REVIEW'
Setup;$Managed+=@([pscustomobject]@{System='gb';RelativePath='Copy.gb';Sha256=('a'*64)});$Entry=@(New-UnregisteredClassificationPlan gb $Managed $Android @() @('gb'))[0];Check ($Entry.Classification-ceq'AMBIGUOUS'-and-not(Plan).Eligible) 'multiple candidates AMBIGUOUS REVIEW'
Setup;$Entry.System='gba';Check (-not(Plan).Eligible) 'unsupported system REVIEW'
Setup;$Evidence.Core='OtherCore';Check (-not(Plan).Eligible) 'other core not generalized'
Setup;$Evidence.CompleteAssetInventory=$false;Check (-not(Plan).Eligible) 'absence requires complete inventory'
Setup;$Android+=@([pscustomobject]@{System='gbc';RelativePath='OldName.gbc';Sha256=('c'*64)});Check (-not(Plan).Eligible) 'cross-system SameBoy basename sharing REVIEW'
Setup;$Evidence.ManagedContents+=@([pscustomobject]@{System='gbc';RelativePath='NewName.gbc';Sha256=('c'*64)});Check (-not(Plan).Eligible) 'future managed basename sharing REVIEW'
Setup;$Saves=@((Asset 'SameBoy/OldName.srm'),(Asset 'SameBoy/OldName.rtc'));$States=@(Asset 'SameBoy/OldName.state');$p=Plan;SetupIO $p;$out=Invoke-RenamePromotionMock $p $IO
Check ($out.Completed-and$out.PromotedCount-eq1-and$Refreshed) 'mock rename refresh MANAGED counted as promotion'
Check ($Files.ContainsKey('/storage/emulated/0/RetroArch/saves/SameBoy/NewName.srm')-and$Files.ContainsKey('/storage/emulated/0/RetroArch/states/SameBoy/NewName.state')-and$Moves-eq4) 'ROM/srm/rtc/state mock moves exactly four'
Check ($XmlCommitted-and$Events.Contains('saves_moved')-and$Events.Contains('states_moved')-and$Events.Contains('media_completed_or_held')) 'multi-asset phase evidence'
SetupIO $p;$FailSave=$true;Reject {Invoke-RenamePromotionMock $p $IO} 'failure after ROM move no auto rollback';Check ($LastRecovery.LastSuccessfulPhase-ceq'rom_moved'-and$Files.ContainsKey('/storage/emulated/0/ROMs/gb/NewName.gb')) 'ROM moved recovery evidence retained'
SetupIO $p;$FailState=$true;Reject {Invoke-RenamePromotionMock $p $IO} 'failure after save rename recovery-needed';Check ($LastRecovery.LastSuccessfulPhase-ceq'saves_moved') 'last successful save phase recorded'
SetupIO $p;$FailXml=$true;Reject {Invoke-RenamePromotionMock $p $IO} 'XML failure preserves moves recovery-needed'
SetupIO $p;$BadXmlEvidence=$true;Reject {Invoke-RenamePromotionMock $p $IO} 'XML fingerprint change before mutation BLOCK';Check ($Moves-eq0) 'preflight failure mutation zero'
SetupIO $p;$Files['/storage/emulated/0/ROMs/gb/_UNREGISTERED/OldName.gb']='c'*64;Reject {Invoke-RenamePromotionMock $p $IO} 'late ROM SHA BLOCK';Check ($Moves-eq0) 'late SHA no moves'
SetupIO $p;$p.Operations[1].DestinationRelativePath='SameBoy/Unexpected.srm';Reject {Invoke-RenamePromotionMock $p $IO} 'tampered asset plan binding BLOCK';Check ($Moves-eq0) 'tampered plan mutation zero'
Setup;$p=Plan;SetupIO $p;$IO.Mode='Adb';Reject {Invoke-RenamePromotionMock $p $IO} 'real adapter prohibited by test-only executor'
Setup;$p=Plan;$Local.Document.SelectSingleNode('//game').ParentNode.RemoveChild($Local.Document.SelectSingleNode('//game'))|Out-Null;$Local.Bytes=ConvertTo-EsdeGamelistBytes $Local;$p=Plan;Check ($p.Eligible-and@(Get-EsdeGameEntries $p.PreparedXml).Count-eq1) 'no local node: existing master only no synthetic local'
Setup;$Master=Xml '<gameList/>';Check (-not(Plan).Eligible) 'missing canonical master metadata REVIEW'
Setup;$clone=$Local.Document.SelectSingleNode('//game').CloneNode($true);$clone.SelectSingleNode('path').InnerText='./NewName.gb';[void]$Local.Document.SelectSingleNode('//gameList').AppendChild($clone);$Local.Bytes=ConvertTo-EsdeGamelistBytes $Local;Check ((Plan).Action-ceq'BLOCK') 'canonical XML collision BLOCK'
Reject {Xml '<gameList><game>'} 'malformed XML cannot enter planner'
Setup;$Android+=@([pscustomobject]@{System='gb';RelativePath='NewName.gb';Sha256=('c'*64)});Check (-not(Plan).Eligible) 'ROM destination different SHA REVIEW'
Setup;$p=Plan;SetupIO $p;$Files['/storage/emulated/0/ROMs/gb/NewName.gb']='c'*64;Reject {Invoke-RenamePromotionMock $p $IO} 'late destination collision BLOCK';Check ($Moves-eq0) 'late destination no moves'
Setup;$Saves=@(Asset 'SameBoy/OldName.srm');$p=Plan;SetupIO $p;$IO.Parent={param($root,$path,$create)[pscustomobject]@{Safe=(-not$path.Contains('/saves/'));Exists=$true;Kind='Directory';CanonicalPath=$path;Device='dev1'}};Reject {Invoke-RenamePromotionMock $p $IO} 'unsafe asset parent blocks before ROM';Check ($Moves-eq0) 'parent preflight mutation zero'
Setup;$p=Plan;SetupIO $p;$IO.Parent={param($root,$path,$create)[pscustomobject]@{Safe=$true;Exists=$true;Kind='Directory';CanonicalPath=$path;Device='other'}};Reject {Invoke-RenamePromotionMock $p $IO} 'cross filesystem BLOCK';Check ($Moves-eq0) 'filesystem failure no mutation'
Setup '_UNREGISTERED/OldName.gbc' 'NewName.gbc';$Android[0].System='gbc';$Managed[0].System='gbc';$Evidence.System='gbc';$Entry=@(New-UnregisteredClassificationPlan gbc $Managed $Android @() @('gb','gbc'))[0];Check ((Plan).Eligible) 'GBC same conservative mock gates'
Setup;$Saves=@(Asset 'SameBoy/OldName.srm');$p=Plan;SetupIO $p;$Files['/storage/emulated/0/RetroArch/saves/SameBoy/OldName.srm']='d'*64;Reject {Invoke-RenamePromotionMock $p $IO} 'late save SHA before ROM BLOCK';Check ($Moves-eq0) 'late save fingerprint mutation zero'
Setup;$p=Plan;SetupIO $p;$script:RunPlan=$p;$script:OriginalMove=$IO.MoveNoClobber;$IO.MoveNoClobber={param($s,$d)& $script:OriginalMove $s $d;$script:RunPlan.PreparedXml.Bytes=[Text.Encoding]::UTF8.GetBytes('<gameList/>')};Reject {Invoke-RenamePromotionMock $p $IO} 'staging changed after ROM move recovery-needed';Check (-not$XmlCommitted-and$null-ne$LastRecovery) 'late staging never commits tampered XML'
# Exercise unchanged v1.6 duplicate-transfer guard using a PC temporary file and a read-only mock.
$temp=Join-Path $env:TEMP ('rename-presence-'+[guid]::NewGuid().ToString('N')+'.gb');[IO.File]::WriteAllText($temp,'fixture');$script:PresenceSha=(Get-FileHash $temp).Hash.ToLowerInvariant();$script:PushCount=0
function Read-ClassificationRom($path,$session){[pscustomobject]@{Sha256=$script:PresenceSha}}
$row=[pscustomobject]@{FullName=$temp;Sha256=$PresenceSha};$r=Send-ClassifiedManagedFile $row '/storage/emulated/0/ROMs/gb/NewName.gb' $env:TEMP {param($args)$script:PushCount++;[pscustomobject]@{Code=0}}
Check ($PushCount-eq0-and$r.Code-eq0) 'existing MANAGED canonical content USB duplicate push zero'
$runtime=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'));Check ($runtime.Contains('New-RenameProductionProposal')-and$runtime.Contains('Invoke-VerifiedRenameAssetMoveCore')) 'Stage 3 production uses shared strict planner and verified asset adapter'
'rename promotion Stage 1 검증 완료: '+$script:Passed
