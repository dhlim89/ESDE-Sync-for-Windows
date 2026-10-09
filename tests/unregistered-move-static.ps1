$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$root=Join-Path $env:TEMP ('clmove-'+[guid]::NewGuid().ToString('N').Substring(0,8));[void][IO.Directory]::CreateDirectory($root)
$Serial='MOCK';$selectedSystems=@('gb');$ReservedFolders=@('_TEST','_UNREGISTERED')
$Buckets=@(@{Remote='/storage/emulated/0/ROMs'},@{Remote='/storage/emulated/0/ES-DE/gamelists'},@{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$work){$blocked=$false;try{& $work|Out-Null}catch{$blocked=$true};Check $blocked ($name+' 차단')}
function Write-Log($m){$script:Logs+=$m}
function Bytes($s){[Text.Encoding]::UTF8.GetBytes($s)}
function Hash($b){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($b)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Put($path,$s){$script:Remote[$path]=Bytes $s}
function Get-RemoteFiles($path){@($script:Remote.Keys|Where-Object {$_.StartsWith($path+'/') -and -not(Is-LocalOnlyRelativePath $_.Substring($path.Length+1))}|ForEach-Object {$_.Substring($path.Length+1)}|Sort-Object)}
function Get-RemoteDirs($path){@()}
function Invoke-Adb{
 $r=[pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}
 $script:Calls+=($args-join' ')
 if($args[2]-eq'pull'){
  if(-not$script:Remote.ContainsKey($args[3])){$r.Code=1;return $r}
  [IO.File]::WriteAllBytes($args[4],$script:Remote[$args[3]]);return $r
 }
 if($args[2]-eq'push'){
  if($script:Fail-ceq'xml-push'){$r.Code=1;return $r}
  $offset=if($args[3]-ceq'--sync'){4}else{3}
  $script:Remote[$args[$offset+1]]=[IO.File]::ReadAllBytes($args[$offset])
  if($script:Fail-ceq'concurrent'){Put $script:XmlRemote '<gameList><userChanged/></gameList>'}
  return $r
 }
 $cmd=[string]$args[3]
 if($cmd.Contains('-type l -print')){
  if($script:Fail-ceq'link'){$r.StdOut='link'}
  return $r
 }
 if($cmd-match"find '([^']+)' -type f -print0"){
  $prefix=$matches[1]+'/'
  $files=@($script:Remote.Keys|Where-Object {$_.StartsWith($prefix,[StringComparison]::Ordinal)}|Sort-Object)
  $r.StdOut=if($files.Count){($files-join[char]0)+[char]0}else{''}
  return $r
 }
 if($cmd.Contains('printf PRESENT')){
  if($cmd-match"-f '([^']+)'"){$path=$matches[1];$r.StdOut=if($script:Remote.ContainsKey($path)){'PRESENT'}else{'ABSENT'}}
  else{$r.StdOut=if(@($script:Remote.Keys|Where-Object {$_ -match '/_(TEST|UNREGISTERED)/'}).Count){'PRESENT'}else{'ABSENT'}}
  return $r
 }
 if($cmd-match"^(?:toybox )?sha256sum '([^']+)'$"){$path=$matches[1];$r.StdOut=(Hash $script:Remote[$path])+'  '+$path;return $r}
 if($cmd-match'^stat -c %d '){$r.StdOut=if($script:Fail-ceq'device'){"1"+[char]10+"2"}else{"1"+[char]10+"1"};return $r}
 if($cmd-match"^stat -c %s '([^']+)'$"){$r.StdOut=[string]$script:Remote[$matches[1]].Length;return $r}
 if($cmd-match"^mv -n '([^']+)' '([^']+)'$"){
  if($script:Fail-ceq'move'){$r.Code=1;return $r}
  $a=$matches[1];$b=$matches[2]
  if(-not$script:Remote.ContainsKey($b)){$script:Remote[$b]=$script:Remote[$a];$script:Remote.Remove($a)}
  if($script:Fail-ceq'sha'){Put $b 'corrupt'}
  return $r
 }
 if($cmd-match"^mv -f '([^']+)' '([^']+)'$"){$script:Remote[$matches[2]]=$script:Remote[$matches[1]];$script:Remote.Remove($matches[1]);return $r}
 if($cmd-match"^rm -f '([^']+)'$"){$script:Remote.Remove($matches[1]);return $r}
 if($cmd-match'^mkdir -p |^rmdir '){return $r}
 throw ('unexpected mock ADB '+$cmd)
}
function Setup($node=$true){
 $case=Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0,8));$script:SourceRoot=Join-Path $case 'library';$state=Join-Path $case 'State';$script:Session=Join-Path $case 'session'
 foreach($d in @($state,$Session,(Join-Path $SourceRoot 'roms/gb'),(Join-Path $SourceRoot 'gamelists/gb'))){[void][IO.Directory]::CreateDirectory($d)}
 $script:Remote=@{};$script:Fail='';$script:Calls=@();$script:Logs=@()
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/managed.gb'),'MANAGED')
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'),'<alternativeEmulator><label>master</label></alternativeEmulator><gameList><game><path>./managed.gb</path><name>Master</name><playcount>2</playcount></game></gameList>')
 Put '/storage/emulated/0/ROMs/gb/managed.gb' 'MANAGED'
 Put '/storage/emulated/0/ROMs/gb/Hacks/fan.gb' 'FAN'
 Put '/storage/emulated/0/ROMs/gb/_TEST/t.gb' 'TEST'
 Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/existing.gb' 'EXISTING'
 $script:XmlRemote='/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml'
 $script:FanNode='<game custom="yes"><path>./Hacks/fan.gb</path><name>Local</name><desc>full node</desc><favorite>true</favorite><playcount>0</playcount><playtime/><lastplayed/><altemulator>Mystery (Standalone)</altemulator><image>/local/media.png</image><unknown a="yes"><child>한글</child></unknown><!--comment--></game>'
 $xml='<alternativeEmulator custom="yes"><!--keep--><label>Android</label></alternativeEmulator><gameList><game><path>./managed.gb</path><name>Old</name><playcount>0</playcount></game>'
 if($node){$xml+=$FanNode}
 $xml+='<game><path>./stale.gb</path><unknown>stale preserve</unknown></game><game><path>./_TEST/t.gb</path><unknown>reserved</unknown></game></gameList>'
 Put $XmlRemote $xml
 $script:OriginalXml=$script:Remote[$XmlRemote]
 $script:RomJob=[pscustomobject]@{System='gb';LocalPath=(Join-Path $SourceRoot 'roms/gb');RemotePath='/storage/emulated/0/ROMs/gb'}
 $script:XmlJob=[pscustomobject]@{System='gb';LocalPath=(Join-Path $SourceRoot 'gamelists/gb');RemotePath='/storage/emulated/0/ES-DE/gamelists/gb';GamelistSource=(Read-EsdeGamelist (Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'))}
 $script:Context=New-ClassificationContext $state $SourceRoot $Serial
 $script:XmlPlan=Prepare-GamelistSystem $XmlJob $Session -PreserveNonMasterNodes -SnapshotOnly
}
function Prepare{Prepare-ClassificationSystem $RomJob $XmlJob $XmlPlan $Session}
function Apply($p){Invoke-ClassificationMoves @($p) $Context $Session}
Setup
$p=Prepare
Check ($p.Moves.Count-eq1 -and $script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')) 'prepare no ROM mutation'
$sourceHash=(Get-FileHash (Join-Path $SourceRoot 'gamelists/gb/gamelist.xml')).Hash
Apply $p
Check (-not$script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')) 'source rename 후 제거'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/fan.gb'])-ceq(Hash (Bytes 'FAN'))) 'destination SHA 동일'
$d=ConvertFrom-EsdeGamelistBytes $script:Remote[$XmlRemote]
$before=ConvertFrom-EsdeGamelistBytes (Bytes ('<gameList>'+$FanNode+'</gameList>'))
$expected=$before.Document.DocumentElement.SelectSingleNode('gameList/game');$expected.SelectSingleNode('path').InnerText='./_UNREGISTERED/Hacks/fan.gb'
$actual=$d.Document.DocumentElement.SelectSingleNode('gameList/game[path="./_UNREGISTERED/Hacks/fan.gb"]')
Check ($actual.OuterXml-ceq$expected.OuterXml) 'path 외 whole-node metadata/comment/attributes 동일'
foreach($tag in @('playcount','playtime','lastplayed','favorite','altemulator','image','unknown')){Check ($actual.SelectSingleNode($tag).OuterXml-ceq$expected.SelectSingleNode($tag).OuterXml) ($tag+' 보존')}
Check ($d.Document.DocumentElement.SelectSingleNode('gameList/game[path="./stale.gb"]/unknown').InnerText-ceq'stale preserve') 'ROM 없는 stale metadata 유지'
Check ($d.Document.DocumentElement.SelectSingleNode('gameList/game[path="./managed.gb"]/name').InnerText-ceq'Master') 'managed master metadata'
Check ($d.Document.DocumentElement.SelectSingleNode('gameList/game[path="./managed.gb"]/playcount').InnerText-ceq'0') 'managed runtime 0 유지'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/_TEST/t.gb'])-ceq(Hash (Bytes 'TEST'))) '_TEST ROM untouched'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/_UNREGISTERED/existing.gb'])-ceq(Hash (Bytes 'EXISTING'))) 'existing _UNREGISTERED untouched'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/managed.gb'])-ceq(Hash (Bytes 'MANAGED'))) 'managed ROM untouched'
Check ((Get-FileHash (Join-Path $SourceRoot 'gamelists/gb/gamelist.xml')).Hash-ceq$sourceHash) 'Dropbox XML writes 0'
Check (@(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File).Count-eq2) 'Dropbox file create/list writes 0'
Check ((Get-Content $Context.File -Raw|ConvertFrom-Json).status-ceq'completed') 'minimal classification state completed'
Confirm-ClassificationInventory $p $Session
Check (@(Get-RemoteFiles $RomJob.RemotePath).Count-eq1) 'inventory refresh local-only excluded'
Setup $false;$p=Prepare;Apply $p
$d=ConvertFrom-EsdeGamelistBytes $script:Remote[$XmlRemote]
Check ($null-eq$d.Document.DocumentElement.SelectSingleNode('gameList/game[path="./_UNREGISTERED/Hacks/fan.gb"]')) 'no node synthetic game 없음'
Setup
$script:Remote[$XmlRemote]=Bytes '<broken>'
Reject 'malformed XML before move' {Prepare-GamelistSystem $XmlJob $Session}
Check ($script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')) 'malformed 원본 ROM 유지'
Setup
$xml=[Text.Encoding]::UTF8.GetString($OriginalXml).Replace('</gameList>','<game><path>./_UNREGISTERED/Hacks/fan.gb</path></game></gameList>')
Put $XmlRemote $xml;$XmlPlan=Prepare-GamelistSystem $XmlJob $Session -PreserveNonMasterNodes -SnapshotOnly
Reject 'destination game node collision' {Prepare}
foreach($failure in @('move','sha','xml-push','concurrent','device')){
 Setup;$p=Prepare;$script:Fail=$failure
 Reject ($fail+' failure') {Apply $p}
 if($failure-ceq'concurrent'){
  Check ([Text.Encoding]::UTF8.GetString($script:Remote[$XmlRemote])-ceq'<gameList><userChanged/></gameList>') 'concurrent XML 덮어쓰기 금지'
 }else{Check ((Hash $script:Remote[$XmlRemote])-ceq(Hash $OriginalXml)) ($fail+' XML commit 없음')}
 Check ((Get-Content $Context.File -Raw|ConvertFrom-Json).status-ceq'recovery-needed') ($fail+' recovery-needed')
 Reject ($fail+' pending state') {New-ClassificationContext $Context.StateRoot $SourceRoot $Serial}
}
Setup;$script:Fail='link'
Reject 'symlink inventory' {Prepare}
Setup
Put '/storage/emulated/0/ROMs/gb/Hacks/second.gb' 'SECOND'
$p=Prepare;Apply $p
Check ($script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/second.gb') -and $script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/fan.gb')) 'multiple unrelated nested classification 정확'
Check ($p.ProtectMedia) 'classification/local-only system media no relocation 보호'
# Same-path conflict: do not push the ROM even through the old directory fast path.
Setup
$script:Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
$script:Remote.Remove('/storage/emulated/0/ROMs/gb/_TEST/t.gb')
$script:Remote.Remove('/storage/emulated/0/ROMs/gb/_UNREGISTERED/existing.gb')
Put '/storage/emulated/0/ROMs/gb/managed.gb' 'PATCHED'
Put '/storage/emulated/0/RetroArch/saves/SameBoy/managed.srm' 'SAVE'
Put '/storage/emulated/0/RetroArch/states/SameBoy/managed.state1' 'STATE'
Put $XmlRemote '<gameList><game><path>./managed.gb</path><name>Old</name><playcount>0</playcount><playtime/><lastplayed/></game></gameList>'
$script:XmlPlan=Prepare-GamelistSystem $XmlJob $Session -SnapshotOnly
$p=Prepare
Check ($p.Inventory[0].Classification-ceq'MANAGED_CONFLICT' -and $p.Moves.Count-eq0) 'conflict no move job'
Check (-not$p.ReviewRequired -and -not$p.ProtectMedia) 'conflict managed XML/media eligible'
Check (@($Logs|Where-Object {$_ -like'*MANAGED_CONFLICT*'}).Count-eq1) 'conflict warning'
Sync-GamelistSystem $p.XmlPlan
$d=ConvertFrom-EsdeGamelistBytes $script:Remote[$XmlRemote]
$n=$d.Document.DocumentElement.SelectSingleNode('gameList/game[path="./managed.gb"]')
Check ($n.SelectSingleNode('name').InnerText-ceq'Master') 'conflict managed master metadata'
foreach($tag in @('playcount','playtime','lastplayed')){Check ($null-ne$n.SelectSingleNode($tag)) ('conflict runtime presence '+$tag)}
Check ($n.SelectSingleNode('playcount').InnerText-ceq'0' -and $n.SelectSingleNode('playtime').InnerText-ceq'' -and $n.SelectSingleNode('lastplayed').InnerText-ceq'') 'conflict runtime 0/empty'
Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/managed.gb'])-ceq(Hash (Bytes 'PATCHED'))) 'conflict Android ROM SHA preserved'
Check (@($Calls|Where-Object {$_ -match 'push .*ROMs/gb'}).Count-eq0) 'conflict ROM overwrite jobs zero'
Check ((Hash $script:Remote['/storage/emulated/0/RetroArch/saves/SameBoy/managed.srm'])-ceq(Hash (Bytes 'SAVE'))) 'conflict save untouched'
Check ((Hash $script:Remote['/storage/emulated/0/RetroArch/states/SameBoy/managed.state1'])-ceq(Hash (Bytes 'STATE'))) 'conflict state untouched'
# The unchanged media engine remains usable for a conflict with no local-only ambiguity.
$mediaDir=Join-Path $SourceRoot 'downloaded_media/gb/covers';[void][IO.Directory]::CreateDirectory($mediaDir)
[IO.File]::WriteAllText((Join-Path $mediaDir 'managed.png'),'MASTER-MEDIA')
$mediaJob=[pscustomobject]@{System='gb';LocalPath=(Split-Path $mediaDir -Parent);RemotePath='/storage/emulated/0/ES-DE/downloaded_media/gb'}
$mc=New-MediaContext $Context.StateRoot $SourceRoot $Serial
$ms=@(Get-MediaSourceFiles @($mediaJob) $mc);$mp=Prepare-MediaPlan @($mediaJob) $ms $mc
Invoke-MediaTransaction $mp $mc
Check ((Hash $script:Remote['/storage/emulated/0/ES-DE/downloaded_media/gb/covers/managed.png'])-ceq(Hash (Bytes 'MASTER-MEDIA'))) 'conflict media managed deployment'
Check (@((Get-Content $mc.ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json).entries).Count-eq1) 'conflict media ownership'
# Unknown mapping: freeze the selected system rather than duplicate canonical content.
Setup
$script:Remote.Remove('/storage/emulated/0/ROMs/gb/managed.gb')
Put '/storage/emulated/0/ROMs/gb/renamed.gb' 'MANAGED'
$xmlBefore=Hash $script:Remote[$XmlRemote]
$p=Prepare
Check (@($p.Inventory|Where-Object Classification -CEQ MANAGED_PATH_MISMATCH).Count-eq1) 'path mismatch recognized'
Check ($p.ReviewRequired -and $p.Moves.Count-eq1 -and $p.ProtectMedia -and $p.ReviewIsolation.ExcludedRomPaths -contains 'managed.gb') 'path mismatch per-file ROM/whole-node isolation'
$callStart=$Calls.Count
Apply $p;Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/renamed.gb'])-ceq(Hash (Bytes 'MANAGED'))) 'path mismatch review ROM preserved'
Check (-not$script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/managed.gb')) 'canonical duplicate not copied'
# Duplicate SHA: whole system remains unchanged.
Setup
[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/copy.gb'),'MANAGED')
$script:Remote.Remove('/storage/emulated/0/ROMs/gb/managed.gb');Put '/storage/emulated/0/ROMs/gb/renamed.gb' 'MANAGED'
$p=Prepare
Check (@($p.Inventory|Where-Object Classification -CEQ AMBIGUOUS).Count-eq1) 'ambiguous multiple managed candidates'
Check ($p.ReviewRequired -and $p.Moves.Count-eq1 -and $p.ProtectMedia -and $p.ReviewIsolation.ExcludedRomPaths.Count-eq3) 'ambiguous candidate group isolation'
# Managed fast path still deploys missing source files in a read-only source fixture.
Setup;$p=Prepare
Apply $p
[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/new.gb'),'NEW')
$p.Source=@(Get-ClassificationSourceRows $RomJob)
Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/new.gb'])-ceq(Hash (Bytes 'NEW'))) 'normal source-to-Android mirror still works'
Check ((Get-FileHash (Join-Path $SourceRoot 'roms/gb/new.gb')).Hash-ieq(Hash (Bytes 'NEW'))) 'normal Dropbox source bytes unchanged'
# Save sidecars are not managed ROM SHA candidates or transfer jobs.
Setup
[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/managed.sav'),'MASTER-SAVE')
Put '/storage/emulated/0/ROMs/gb/managed.sav' 'LOCAL-SAVE'
$p=Prepare;Apply $p;Confirm-ClassificationInventory $p $Session
Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/managed.sav'])-ceq(Hash (Bytes 'LOCAL-SAVE'))) 'ROM directory save sidecar untouched'
Check (@($p.Inventory|Where-Object RelativePath -CEQ 'managed.sav').Count-eq0) 'save sidecar excluded from ROM classifier'
Check (@($Calls|Where-Object {$_ -match 'push .*managed\.sav'}).Count-eq0) 'save sidecar transfer jobs zero'
# A late Android revision must be preserved, not overwritten by a stale MANAGED plan.
Setup;$p=Prepare;Apply $p
Put '/storage/emulated/0/ROMs/gb/managed.gb' 'LATE-PATCH'
Reject 'late Android ROM revision' {Sync-ClassifiedManagedRom $RomJob $p 'MOCK'}
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/managed.gb'])-ceq(Hash (Bytes 'LATE-PATCH'))) 'late conflict revision preserved'
Write-Output ('move/gamelist 검증 완료: '+$script:Passed+' / fixture '+$root)
