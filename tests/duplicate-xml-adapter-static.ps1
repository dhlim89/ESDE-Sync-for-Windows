$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
foreach($file in @('sync-worker.ps1','tests/duplicate-manager-static.ps1')){$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file),[ref]$null,[ref]$null);foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}}
$fake=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'unregistered-move-static.ps1'),[ref]$null,[ref]$null)
foreach($f in $fake.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -In @('Invoke-Adb','Bytes','Hash','Put')){. ([scriptblock]::Create($f.Extent.Text))}
$ReservedFolders=@('_TEST','_UNREGISTERED');$Serial='FAKE';$selectedSystems=@('gb');$Buckets=@(@{Remote='/storage/emulated/0/ROMs'},@{Remote='/storage/emulated/0/ES-DE/gamelists'},@{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$script:Passed=0;function Write-Log($m){}
function Get-PromotionEnvironmentEvidence { [pscustomobject]@{Verified=$true;System='gb';PathIndependentSaveState=$true;Reference='FAKE';ConfigSha256=('b'*64)} }
function Build {
 Setup '<playcount>0</playcount><playtime/><lastplayed/>'
 $script:Local=Xml '<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><folder custom="keep"><path>./_UNREGISTERED</path><lastplayed>20261011T093913</lastplayed></folder><game><path>./_UNREGISTERED/Old.gb</path><name>Local</name><playcount>0</playcount><playtime/><lastplayed/></game><game><path>./New.gb</path><name>Old canonical</name></game><game custom="keep"><path>./Other.gb</path><name>Android Other</name><custom>must retain</custom></game><game custom="manual"><path>./_TEST/Manual.gb</path><unknown>preserve</unknown><!--manual--></game></gameList>'
 $script:Master=Xml '<gameList><game><path>./New.gb</path><name>Managed Display</name></game><game><path>./Other.gb</path><name>Changed Master Other</name></game></gameList>'
 $script:Root=Join-Path $env:TEMP ('esde-duplicate-xml-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($Root)
 $script:Remote=@{};$script:Calls=@();$script:Fail='';$script:XmlRemote='/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml';$Remote[$XmlRemote]=$Local.Bytes
 $pulled=Join-Path $Root 'original.xml';[IO.File]::WriteAllBytes($pulled,$Local.Bytes)
 $xmlplan=[pscustomobject]@{System='gb';RemotePath='/storage/emulated/0/ES-DE/gamelists/gb';RemoteFile=$XmlRemote;Present=$true;Output=$null;Pulled=$pulled;Validated=$true;LocalOnlyCount=1;SourcePresent=$true;Local=$Local;ClassificationCommitted=$false}
 $script:Snapshot=[pscustomobject]@{Android=$Android;Managed=$Managed;Assets=[pscustomobject]@{Saves=@();States=@()};Media=@{gb=@()};Xml=@{gb=[pscustomobject]@{Local=$Local;Master=$Master;Plan=$xmlplan}}}
 $script:Rows=@(New-DuplicateProductionRows $Snapshot);$script:P=$Rows[0]
 $script:Adapter=New-DuplicateAdbAdapter $P $Root
}
Build;Check ($Rows.Count-eq1-and$P.Grade-ceq'SAFE_MERGE_DELETE') 'actual production scan rows safe metadata merge'
$beforeOther=$Local.Document.SelectSingleNode('//game[path="./Other.gb"]').OuterXml;$beforeTest=$Local.Document.SelectSingleNode('//game[path="./_TEST/Manual.gb"]').OuterXml;$beforeFolder=$Local.Document.SelectSingleNode('//folder').OuterXml
& $Adapter.CommitXml $P
$after=ConvertFrom-EsdeGamelistBytes $Remote[$XmlRemote]
Check (@(Get-EsdeGameEntries $after|Where-Object Key -CEQ './New.gb').Count-eq1-and@(Get-EsdeGameEntries $after|Where-Object Key -CEQ './_UNREGISTERED/Old.gb').Count-eq0) 'verified XML transfer canonical one obsolete zero'
Check ($after.Document.SelectSingleNode('//game[path="./New.gb"]/name').InnerText-ceq'Managed Display') 'display name comes from master'
Check ($after.Document.SelectSingleNode('//game[path="./New.gb"]/playcount').InnerText-ceq'0'-and$after.Document.SelectSingleNode('//game[path="./New.gb"]/playtime').InnerText-ceq'') 'runtime zero empty actual transfer'
Check ($after.Document.SelectSingleNode('//game[path="./Other.gb"]').OuterXml-ceq$beforeOther) 'unrelated game whole node unchanged despite changed master'
Check ($after.Document.SelectSingleNode('//game[path="./_TEST/Manual.gb"]').OuterXml-ceq$beforeTest) 'TEST metadata untouched'
Check ($after.Document.SelectSingleNode('//folder').OuterXml-ceq$beforeFolder) 'folder whole node preserved'
Check ($after.Document.SelectSingleNode('//alternativeEmulator/label').InnerText-ceq'SameBoy') 'alternative emulator preserved'
Check (@($Calls|Where-Object {$_-match' push '}).Count-eq1-and@($Calls|Where-Object {$_-match' pull '}).Count-ge2) 'actual temp push re-pull snapshot verification'
Check (@($Calls|Where-Object {$_-match'mv -f'}).Count-eq1) 'same directory XML replacement'
Build;$Fail='concurrent';Reject {& $Adapter.CommitXml $P} 'concurrent XML revision blocks replacement'
Check ([Text.Encoding]::UTF8.GetString($Remote[$XmlRemote]).Contains('userChanged')) 'concurrent user XML retained'
Build;$Fail='xml-push';Reject {& $Adapter.CommitXml $P} 'XML push failure surfaced'
Check ([Convert]::ToBase64String($Remote[$XmlRemote])-ceq[Convert]::ToBase64String($Local.Bytes)) 'push failure original intact'
Build;$Snapshot.Android+=Row '_TEST/Another.gb';$Rows=@(New-DuplicateProductionRows $Snapshot);Check (@($Rows|Where-Object SourceRelativePath -Like '*_TEST*').Count-eq0) 'production scan TEST never listed'
$public=@(Get-DuplicatePublicRows $Rows);Check ($public.Count-eq1-and-not$public[0].Selected-and$public[0].SelectionBinding) 'public rows snapshot binding default unchecked'
$binding=$P.SelectionBinding;$Local.Document.SelectSingleNode('//game[path="./_UNREGISTERED/Old.gb"]/playcount').InnerText='2';$Local.Bytes=ConvertTo-EsdeGamelistBytes $Local;$Rows=@(New-DuplicateProductionRows $Snapshot);Check ($Rows[0].SelectionBinding-cne$binding) 'target runtime changes stale selection binding'
Build;$Snapshot.Managed+=Row 'Second.gb';$Rows=@(New-DuplicateProductionRows $Snapshot);Check ($Rows[0].Grade-ceq'REVIEW_ONLY') 'actual production multiple managed candidate review'
Build;$Snapshot.Media.gb=@(Asset 'covers/Old.png');$Rows=@(New-DuplicateProductionRows $Snapshot);Check ($Rows[0].Grade-ceq'REVIEW_ONLY') 'actual production media review'
Build;$Snapshot|Add-Member ManualNamespace ([pscustomobject]@{Names=@([pscustomobject]@{System='gb';RelativePath='_TEST/Old.gb'});Uncertain=$false});$Rows=@(New-DuplicateProductionRows $Snapshot);Check ($Rows[0].Grade-ceq'REVIEW_ONLY'-and$Rows.Count-eq1) 'shared save basename uses names only TEST not candidate'
Build;$Snapshot|Add-Member ManualNamespace ([pscustomobject]@{Names=@();Uncertain=$true});$Rows=@(New-DuplicateProductionRows $Snapshot);Check ($Rows[0].Grade-ceq'REVIEW_ONLY') 'unknown manual save namespace REVIEW'
Build;Check ($P.ProductionExecutable) 'safe production proposal enabled only with evidence'
$script:NativeInventoryCommands=@()
function Invoke-PromotionShell($command){
 $script:NativeInventoryCommands+=$command
 if($command.Contains('printf DIR')){return 'DIR'}
 if($command.StartsWith('readlink -f')){return '/storage/emulated/0/ROMs'+[char]10}
 if($command.Contains('-type l -print')){return ''}
 if($command.Contains('-type f -exec')){return ('32'+[char]9+('a'*64)+'  /storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb'+[char]10)}
 if($command.Contains('-type f -print0')){return '/storage/emulated/0/ROMs/gb/_TEST/Manual.gb'+[char]0}
 throw 'unexpected inventory command'
}
$inventory=@(Get-RenameRemoteInventory '/storage/emulated/0/ROMs' -ExcludeTest)
Check ($inventory.Count-eq1) 'filtered inventory parsed by existing helper'
Check (@($NativeInventoryCommands|Where-Object {$_-match"-iname '_TEST' -prune -o -type f -exec"}).Count-eq1) 'TEST subtree pruned before hash/file read'
Check (@($NativeInventoryCommands|Where-Object {$_-match"-iname '_TEST' -prune -o -type l"}).Count-eq1) 'TEST excluded duplicate link scan'
$namespace=Get-DuplicateManualNamespaceEvidence
Check ($namespace.Names.Count-eq1-and$namespace.Names[0].RelativePath-ceq'_TEST/Manual.gb') 'separate save ownership namespace names only'
Check (-not@($NativeInventoryCommands|Where-Object {$_-match'sha256sum.*_TEST/'}).Count) 'no TEST ROM SHA request'
'PASS TOTAL: '+$script:Passed