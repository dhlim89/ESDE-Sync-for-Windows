$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'unregistered-move-static.ps1')
$script:Passed=0
foreach($kind in @('MANAGED_PATH_MISMATCH','AMBIGUOUS')){
 Setup
 $Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
 $Remote.Remove('/storage/emulated/0/ROMs/gb/managed.gb');Put '/storage/emulated/0/ROMs/gb/renamed.gb' 'MANAGED'
 if($kind-ceq'AMBIGUOUS'){[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/copy.gb'),'MANAGED')}
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/other.gb'),'OTHER')
 $master='<gameList><game><path>./managed.gb</path><name>Master candidate</name></game><game><path>./other.gb</path><name>Updated other</name><playcount>5</playcount></game></gameList>'
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'),$master)
 $XmlJob.GamelistSource=Read-EsdeGamelist (Join-Path $SourceRoot 'gamelists/gb/gamelist.xml')
 $reviewNode='<game custom="yes"><path>./renamed.gb</path><name>Review original</name><playcount>0</playcount><altemulator>Unknown (Standalone)</altemulator><unknown>x</unknown><!--keep--></game>'
 Put $XmlRemote ('<gameList>'+$reviewNode+'<game><path>./other.gb</path><name>Old other</name><playcount>0</playcount></game></gameList>')
 $XmlPlan=Prepare-GamelistSystem $XmlJob $Session -SnapshotOnly
 $p=Prepare
 Check ($p.ReviewIsolation.Groups.Count-eq1) ($kind+' group')
 Check ($p.ReviewIsolation.ExcludedRomPaths-contains'renamed.gb' -and $p.ReviewIsolation.ExcludedRomPaths-contains'managed.gb') ($kind+' source/canonical exclusions')
 Check ($p.ProtectMedia) ($kind+' media system hold')
 $out=Read-EsdeGamelist $p.XmlPlan.Output
 $node=$out.Document.DocumentElement.SelectSingleNode('gameList/game[path="./renamed.gb"]')
 Check ($node.OuterXml-ceq$reviewNode) ($kind+' existing whole-node exact preserve')
 Check ($null-eq$out.Document.DocumentElement.SelectSingleNode('gameList/game[path="./managed.gb"]')) ($kind+' absent canonical game not synthesized')
 Check ($out.Document.DocumentElement.SelectSingleNode('gameList/game[path="./other.gb"]/name').InnerText-ceq'Updated other') ($kind+' unrelated metadata updated')
 Check ($out.Document.DocumentElement.SelectSingleNode('gameList/game[path="./other.gb"]/playcount').InnerText-ceq'0') ($kind+' unrelated runtime retained')
 Sync-GamelistSystem $p.XmlPlan;Confirm-ClassificationInventory $p $Session
 Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
 Check ((Hash $Remote['/storage/emulated/0/ROMs/gb/renamed.gb'])-ceq(Hash (Bytes 'MANAGED'))) ($kind+' review ROM preserve')
 Check (-not$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/managed.gb')) ($kind+' canonical push zero')
 if($kind-ceq'AMBIGUOUS'){Check (-not$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/copy.gb')) 'second candidate push zero'}
 Check ((Hash $Remote['/storage/emulated/0/ROMs/gb/other.gb'])-ceq(Hash (Bytes 'OTHER'))) ($kind+' unrelated managed push works')
 Check (@($Calls|Where-Object {$_-match'(mv |rm ).*(renamed|managed|copy)\.gb'}).Count-eq0) ($kind+' review delete/move/save/state zero')
 Check ($p.ReviewIsolation.Groups[0].GamelistAction-ceq'PreserveExisting' -and $p.ReviewIsolation.Groups[0].MediaAction-ceq'ReviewSystem') ($kind+' subsystem actions')
}
Write-Output ('per-file review 검증 완료: '+$script:Passed)