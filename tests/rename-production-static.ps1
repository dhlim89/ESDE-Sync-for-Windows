$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'unregistered-move-static.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'promotion-production-static.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Directory','PromotionSetup')){$f=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -CEQ $name)[0];. ([scriptblock]::Create($f.Extent.Text))}
$script:Passed=0;$script:ExtraDirs=@('/storage/emulated/0/RetroArch','/storage/emulated/0/RetroArch/saves','/storage/emulated/0/RetroArch/states','/storage/emulated/0/RetroArch/saves/SameBoy','/storage/emulated/0/RetroArch/states/SameBoy','/storage/emulated/0/ES-DE/downloaded_media/gb','/storage/emulated/0/ES-DE/downloaded_media/gbc')
function Directory($p){$p-in$script:ExtraDirs-or$p-in@('/storage/emulated/0/ROMs','/storage/emulated/0/ROMs/gb')-or$script:Dirs.ContainsKey($p)-or@($Remote.Keys|Where-Object {$_.StartsWith($p+'/',[StringComparison]::Ordinal)}).Count-gt0}
function Get-PromotionEnvironmentEvidence($sys,$a,$m,$key,$source){[pscustomobject]@{Verified=(-not$script:UnknownEnvironment);System=$sys;ConfigSha256=('a'*64);PathIndependentSaveState=$true;NoMediaRelocationRequired=$true;LocalMetadataResolved=$true;SafeDestinationParent=$true;Reference='mock Stage2 SameBoy'}}
function Invoke-PromotionShell($cmd){
 $script:NativeCalls+=$cmd;$paths=@([regex]::Matches($cmd,"'([^']*)'")|ForEach-Object {$_.Groups[1].Value})
 if($cmd.StartsWith('find ')-and$cmd.Contains('-mindepth')){$p=$paths[0];$names=@(@($Remote.Keys)+@($script:Dirs.Keys)+$script:ExtraDirs|Where-Object {$_.StartsWith($p+'/',[StringComparison]::Ordinal)}|ForEach-Object {$p+'/'+$_.Substring($p.Length+1).Split('/')[0]}|Sort-Object -Unique);if($names.Count){return ($names-join[char]0)+[char]0};return ''}
 if($cmd.StartsWith('find ')-and$cmd.Contains('-type l')){if($script:LinkParent-and$script:LinkParent.StartsWith($paths[0]+'/')){return $script:LinkParent};return ''}
 if($cmd.StartsWith('find ')-and$cmd.Contains('-type f -exec')){$p=$paths[0];return (@($Remote.Keys|Where-Object {$_.StartsWith($p+'/',[StringComparison]::Ordinal)}|Sort-Object|ForEach-Object {[string]$Remote[$_].Length+[char]9+(Hash $Remote[$_])+'  '+$_})-join[char]10)}
 if($cmd.Contains('mv -n ')){
  $src=$paths[-2];$dst=$paths[-1]
  if($src-ceq$script:FailMovePath){throw 'injected move failure'}
  if($Remote.ContainsKey($dst)-or-not$Remote.ContainsKey($src)){throw 'no-clobber guard'}
  if($cmd.Contains('hash=$(sha256sum')){$expected=$paths[-3];if((Hash $Remote[$src])-cne$expected){throw 'atomic SHA guard'}}
  $Remote[$dst]=$Remote[$src];$Remote.Remove($src);$script:MovedPaths+=$src
  if($src.Contains('/ROMs/')-and$script:XmlAfterRom){[IO.File]::AppendAllText((Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'),' ')}
  return ''
 }
 if($cmd.StartsWith('if [ -L')-and$cmd.Contains('printf LINK')){$p=$paths[0];if($p-ceq$script:LinkParent){return 'LINK'};if($cmd.Contains('printf FILE')-and$Remote.ContainsKey($p)){return 'FILE'};if(Directory $p){return 'DIR'};if($Remote.ContainsKey($p)){return 'OTHER'};return 'ABSENT'}
 if($cmd.StartsWith('if [ -L')-and$cmd.Contains('readlink -f')){if($paths[0]-ceq$script:LinkParent-or-not(Directory $paths[0])){throw 'parent safety'};return $paths[0]+[char]10}
 if($cmd.StartsWith('if [ -L')-and$cmd.Contains('printf DIR')){if($paths[0]-ceq$script:LinkParent){throw 'parent link'};return 'DIR'}
 if($cmd.StartsWith('if [ -d')){if(Directory $paths[0]){return 'DIR'};return 'ABSENT'}
 if($cmd.StartsWith('readlink -f')){if($script:Redirect){return '/outside'};return $paths[0]+[char]10}
 if($cmd.StartsWith('stat -c %s:%d')){return ([string]$Remote[$paths[0]].Length+':1')}
 if($cmd.StartsWith('stat -c %d')){return '1'+[char]10}
 if($cmd.StartsWith('sha256sum')){return (Hash $Remote[$paths[0]])+'  '+$paths[0]+[char]10}
 if($cmd.StartsWith('mkdir ')){$script:Dirs[$paths[0]]=$true;return ''}
 throw ('unexpected mocked native shell '+$cmd)
}
function RenameSetup($old='_UNREGISTERED/OldName.gb',$new='New Name.gb',$extra=''){
 PromotionSetup
 Remove-Item -LiteralPath (Join-Path $SourceRoot 'roms/gb/Hacks/Promo.gb')
 $Remote.Remove('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Promo.gb')
 $script:Old=$old;$script:New=$new;$script:FailMovePath='';$script:MovedPaths=@();$script:XmlAfterRom=$false
 $dest=Join-Path $SourceRoot ('roms/gb/'+$new);[void][IO.Directory]::CreateDirectory((Split-Path $dest));[IO.File]::WriteAllText($dest,'RENAME')
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'),('<gameList><game><path>./managed.gb</path><name>Master</name></game><game><path>./'+$new+'</path><name>Display is not filename</name><playcount>99</playcount></game></gameList>'))
 $XmlJob.GamelistSource=Read-EsdeGamelist (Join-Path $SourceRoot 'gamelists/gb/gamelist.xml')
 Put ('/storage/emulated/0/ROMs/gb/'+$old) 'RENAME'
 Put $XmlRemote ('<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><folder><path>./_UNREGISTERED</path><lastplayed>20261011T000000</lastplayed></folder><game><path>./managed.gb</path><playcount>0</playcount></game><game><path>./'+$old+'</path><name>Local display</name><playcount>0</playcount><playtime/><lastplayed/>'+$extra+'</game></gameList>')
 $script:XmlPlan=Prepare-GamelistSystem $XmlJob $Session -SnapshotOnly
}
function OldAsset($ext){$kind=if($ext-ceq'.state'){'states'}else{'saves'};Put ('/storage/emulated/0/RetroArch/'+$kind+'/SameBoy/OldName'+$ext) ('BYTES'+$ext)}
function ApplyRename($p){Invoke-ClassificationPromotions @($p) $Context $Session}
RenameSetup;$p=Prepare;Check ($p.Promotions.Count-eq1-and$p.Promotions[0].Action-ceq'PROMOTE_WITH_RENAME') 'production eligibility no assets'
Check ($p.ProtectMedia-and-not$p.ReviewRequired) 'promotion plus first-run media HOLD'
foreach($ext in @('.srm','.rtc','.state')){RenameSetup;OldAsset $ext;$p=Prepare;ApplyRename $p;Check ($Remote.ContainsKey('/storage/emulated/0/RetroArch/'+$(if($ext-ceq'.state'){'states'}else{'saves'})+'/SameBoy/New Name'+$ext)-and$MovedPaths.Count-eq2) ($ext+' actual adapter production mocked rename')}
RenameSetup;foreach($ext in @('.srm','.rtc','.state')){OldAsset $ext};$saveBefore=Hash $Remote['/storage/emulated/0/RetroArch/saves/SameBoy/OldName.srm'];$p=Prepare;ApplyRename $p
Check ((Hash $Remote['/storage/emulated/0/RetroArch/saves/SameBoy/New Name.srm'])-ceq$saveBefore) 'asset bytes SHA preserved'
Check ($MovedPaths.Count-eq4) 'ROM save rtc state exactly four verified moves'
$journal=Get-Content $Context.File -Raw|ConvertFrom-Json
Check ($journal.status-ceq'completed'-and$journal.completedAssets.Count-eq3) 'durable completed asset evidence'
foreach($phase in @('prepared','rom_moved','saves_moved','states_moved','xml_committed','media_completed_or_held','completed')){Check ($phase-in@($journal.events.Phase)) ('transaction phase '+$phase)}
Check ($journal.moves[0].PromotionType-ceq'RENAME') 'internal promotion type'
Confirm-ClassificationInventory $p $Session;Check $true 'inventory refresh MANAGED'
$callStart=$Calls.Count;Sync-ClassifiedManagedRom $RomJob $p 'ROM';Check (@($Calls|Select-Object -Skip $callStart|Where-Object {$_-match'push .*New Name.gb'}).Count-eq0) 'canonical push zero after rename'
$x=ConvertFrom-EsdeGamelistBytes $Remote[$XmlRemote];$node=@(Get-EsdeGameEntries $x|Where-Object Key -CEQ './New Name.gb')
Check ($node.Count-eq1-and$node[0].Node.name-ceq'Display is not filename') 'one canonical node display follows master metadata'
Check ($node[0].Node.playcount-ceq'0'-and$node[0].Node.playtime-ceq''-and$node[0].Node.lastplayed-ceq'') 'runtime zero and empty preserved'
Check (@(Get-EsdeGameEntries $x|Where-Object Key -CEQ './_UNREGISTERED/OldName.gb').Count-eq0) 'old local node removed no synthetic duplicate'
Check ($x.Document.SelectSingleNode('//alternativeEmulator/label').InnerText-ceq'SameBoy'-and$x.Document.SelectSingleNode('//folder/lastplayed').InnerText-ceq'20261011T000000') 'alternative emulator and folder preserved'
$sum=Get-PromotionSummaryProposal $p.Inventory $p.CompletedPromotions;Check ($sum.PromotedCount-eq1-and$sum.LocalOnlyCount-eq3-and$sum.ReviewCount-eq0) 'PromotedCount and start inventory axes'
RenameSetup;$p=Prepare;ApplyRename $p;Check ($MovedPaths.Count-eq1) 'no save source means no-op'
foreach($value in @('BYTES.srm','DIFFERENT')){RenameSetup;OldAsset '.srm';Put '/storage/emulated/0/RetroArch/saves/SameBoy/New Name.srm' $value;$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) ('save destination collision '+$value+' REVIEW')}
foreach($ext in @('.state1','.state2','.state.auto','.auto','.autosave')){RenameSetup;Put ('/storage/emulated/0/RetroArch/states/SameBoy/OldName'+$ext) 'UNKNOWN';$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) ($ext+' REVIEW')}
RenameSetup;Put '/storage/emulated/0/RetroArch/states/SameBoy/OldNameElse.state1' 'UNRELATED';$p=Prepare;Check ($p.Promotions.Count-eq1) 'unrelated prefix state not false positive'
RenameSetup;Put '/storage/emulated/0/ES-DE/downloaded_media/gb/covers/OldName.png' 'LOCAL';$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) 'old local media REVIEW'
RenameSetup;[void][IO.Directory]::CreateDirectory((Join-Path $SourceRoot 'downloaded_media/gb/covers'));[IO.File]::WriteAllText((Join-Path $SourceRoot 'downloaded_media/gb/covers/New Name.png'),'MANAGED MEDIA');$p=Prepare;Check ($p.Promotions.Count-eq1-and$p.ProtectMedia) 'managed media only eligibility plus HOLD'
foreach($pair in @(@('_UNREGISTERED/Hacks/OldName.gb','OldName.gb'),@('_UNREGISTERED/Hacks/OldName.gb','RPG/NewName.gb'),@('_UNREGISTERED/OldName.gb','oldname.gb'),@('_TEST/OldName.gb','NewName.gb'))){RenameSetup $pair[0] $pair[1];$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) ('excluded path kind '+$pair[0]+' -> '+$pair[1])}
RenameSetup;Put '/storage/emulated/0/ROMs/gb/New Name.gb' 'RENAME';$p=Prepare;Check ($p.Promotions.Count-eq0) 'existing canonical ROM same SHA REVIEW'
RenameSetup '_UNREGISTERED/OldName.gb' 'New Name.gb' '<unknown>custom</unknown>';$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) 'unknown metadata REVIEW'
RenameSetup;$UnknownEnvironment=$true;$p=Prepare;Check ($p.Promotions.Count-eq0) 'uncertain core environment REVIEW'
RenameSetup;[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/Other.gb'),'RENAME');$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) 'multiple SHA candidates AMBIGUOUS'
RenameSetup;$p=Prepare;Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/OldName.gb' 'CHANGED';Reject 'late ROM SHA' {ApplyRename $p};Check ($MovedPaths.Count-eq0) 'late ROM zero mutation'
RenameSetup;OldAsset '.srm';$p=Prepare;Put '/storage/emulated/0/RetroArch/saves/SameBoy/OldName.srm' 'CHANGED';Reject 'late save SHA preflight' {ApplyRename $p};Check ($MovedPaths.Count-eq0) 'late save zero mutation'
foreach($path in @('/storage/emulated/0/RetroArch/saves/SameBoy/OldName.srm','/storage/emulated/0/RetroArch/states/SameBoy/OldName.state')){RenameSetup;OldAsset '.srm';OldAsset '.state';$p=Prepare;$FailMovePath=$path;Reject ('failure '+$path) {ApplyRename $p};$j=Get-Content $Context.File -Raw|ConvertFrom-Json;Check ($j.status-ceq'recovery-needed'-and$j.lastSuccessfulPhase-cin@('rom_moved','saves_moved')) 'partial asset failure recovery last phase';Reject 'unfinished gate' {New-ClassificationContext $state $SourceRoot $Serial}}
RenameSetup;OldAsset '.srm';$p=Prepare;$Fail='xml-push';Reject 'XML failure after state phase' {ApplyRename $p};$j=Get-Content $Context.File -Raw|ConvertFrom-Json;Check ($j.status-ceq'recovery-needed'-and$j.lastSuccessfulPhase-ceq'states_moved') 'XML failure no reverse move recovery-needed'
RenameSetup;$p=Prepare;$XmlAfterRom=$true;Reject 'XML evidence changed after move' {ApplyRename $p};Check ((Get-Content $Context.File -Raw|ConvertFrom-Json).status-ceq'recovery-needed') 'master race recovery gate'
RenameSetup;OldAsset '.srm';$LinkParent='/storage/emulated/0/RetroArch/saves/SameBoy';$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) 'asset parent symlink fallback REVIEW'
RenameSetup;$p=Prepare;$LinkParent='/storage/emulated/0/RetroArch/states/SameBoy';Reject 'late parent symlink block' {ApplyRename $p};Check ($MovedPaths.Count-eq0) 'late parent no mutation'
RenameSetup;OldAsset '.srm'
[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/Same.gb'),'SAME-CONTENT');Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Same.gb' 'SAME-CONTENT'
foreach($target in @('Master','Android')){
 $xml=if($target-ceq'Master'){$XmlJob.GamelistSource}else{ConvertFrom-EsdeGamelistBytes $Remote[$XmlRemote]}
 $game=$xml.Document.CreateElement('game');$path=$xml.Document.CreateElement('path');$path.InnerText=if($target-ceq'Master'){'./Same.gb'}else{'./_UNREGISTERED/Same.gb'};[void]$game.AppendChild($path);[void]$xml.Document.SelectSingleNode('//gameList').AppendChild($game);$xml.Bytes=ConvertTo-EsdeGamelistBytes $xml
 if($target-ceq'Master'){[IO.File]::WriteAllBytes((Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'),$xml.Bytes);$XmlJob.GamelistSource=$xml}else{$Remote[$XmlRemote]=$xml.Bytes}
}
$XmlPlan=Prepare-GamelistSystem $XmlJob $Session -SnapshotOnly;$p=Prepare;Check ($p.Promotions.Count-eq2) 'mixed same-name and rename plans'
ApplyRename $p;Check ($p.CompletedPromotions-eq2-and$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Same.gb')-and$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/New Name.gb')) 'mixed transaction transformed asset evidence remains valid'
RenameSetup;[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/Unrelated.gb'),'UNRELATED NEW');Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Elsewhere.gb' 'RENAME'
$p=Prepare;Check ($p.Promotions.Count-eq1-and$p.ReviewRequired) 'rename eligible with existing different-path REVIEW'
ApplyRename $p;Sync-ClassifiedManagedRom $RomJob $p 'ROM'
Check ($Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Unrelated.gb')-and$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Elsewhere.gb')) 'unrelated managed push continues and other review ROM preserved'
RenameSetup;Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Second.gb' 'RENAME';$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) 'multiple local rename claims same canonical remain REVIEW'
# Stage 1 mock and same-name suites separately cover the unchanged ROM core; no real Android API is reachable.
'RENAME PRODUCTION INTEGRATION PASS: '+$script:Passed