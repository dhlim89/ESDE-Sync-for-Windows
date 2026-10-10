$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'unregistered-move-static.ps1')
$script:Passed=0
$originalShell=(Get-Item Function:Invoke-PromotionShell).ScriptBlock
$originalEnvironment=(Get-Item Function:Get-PromotionEnvironmentEvidence).ScriptBlock
function Directory($path){$path-in@('/storage/emulated/0/ROMs','/storage/emulated/0/ROMs/gb') -or $script:Dirs.ContainsKey($path) -or @($Remote.Keys|Where-Object {$_.StartsWith($path+'/',[StringComparison]::Ordinal)}).Count-gt0}
function Invoke-PromotionShell($cmd){
 $script:NativeCalls+=$cmd
 $paths=@([regex]::Matches($cmd,"'([^']*)'")|ForEach-Object {$_.Groups[1].Value})
 if($cmd.StartsWith('if [ -L') -and $cmd.Contains('printf LINK')){$p=$paths[0];if($p-ceq$script:LinkParent){return 'LINK'};if(Directory $p){return 'DIR'};if($Remote.ContainsKey($p)){return 'OTHER'};return 'ABSENT'}
 if($cmd.StartsWith('if [ -L') -and $cmd.Contains('printf DIR')){if($paths[0]-ceq$script:LinkParent -or -not(Directory $paths[0])){throw 'parent recheck failed'};return 'DIR'}
 if($cmd.StartsWith('if [ -d') -and $cmd.Contains('printf ABSENT')){if(Directory $paths[0]){return 'DIR'};return 'ABSENT'}
 if($cmd.StartsWith('find ')-and$cmd.Contains('-mindepth')){$p=$paths[0];$names=@(@($Remote.Keys)+@($script:Dirs.Keys)|Where-Object {$_.StartsWith($p+'/')}|ForEach-Object {$p+'/'+$_.Substring($p.Length+1).Split('/')[0]}|Sort-Object -Unique);if($names.Count){return ($names-join[char]0)+[char]0};return ''}
 if($cmd.StartsWith('readlink -f')){if($script:Redirect){return '/outside'};return $paths[0]+[char]10}
 if($cmd.StartsWith('stat -c %d')){return '1'+[char]10}
 if($cmd.StartsWith('mkdir ')){$script:Dirs[$paths[0]]=$true;if($script:LateRevision){Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Promo.gb' 'CHANGED'};return ''}
 if($cmd.Contains('mv -n ')){
  if($script:MoveFailure){throw 'native move error'}
  $src=$paths[-2];$dst=$paths[-1]
  if($Remote.ContainsKey($dst)){throw 'destination appeared'}
  $Remote[$dst]=$Remote[$src];$Remote.Remove($src)
  if($script:BadSha){Put $dst 'BAD'}
  if($script:MasterRace){[IO.File]::AppendAllText((Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'),' ')}
  return ''
 }
 throw ('unexpected native mock shell '+$cmd)
}
function Get-PromotionEnvironmentEvidence($sys,$a,$m,$key){[pscustomobject]@{Verified=(-not$script:UnknownEnvironment);System=$sys;ConfigSha256=('a'*64);PathIndependentSaveState=$true;NoMediaRelocationRequired=$true;LocalMetadataResolved=$true;SafeDestinationParent=$true;Reference='MOCK SameBoy evidence'}}
function PromotionSetup($extra=''){
 Setup
 $Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
 $script:Dirs=@{};$script:LinkParent='';$script:Redirect=$false;$script:LateRevision=$false;$script:MoveFailure=$false;$script:BadSha=$false;$script:MasterRace=$false;$script:UnknownEnvironment=$false;$script:NativeCalls=@()
 [void][IO.Directory]::CreateDirectory((Join-Path $SourceRoot 'roms/gb/Hacks'))
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/Hacks/Promo.gb'),'PROMOROM')
 $master='<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>./managed.gb</path><name>Master</name></game><game><path>./Hacks/Promo.gb</path><name>Canonical</name><playcount>99</playcount></game></gameList>'
 [IO.File]::WriteAllText((Join-Path $SourceRoot 'gamelists/gb/gamelist.xml'),$master)
 $XmlJob.GamelistSource=Read-EsdeGamelist (Join-Path $SourceRoot 'gamelists/gb/gamelist.xml')
 Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Promo.gb' 'PROMOROM'
 Put $XmlRemote ('<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>./managed.gb</path><playcount>0</playcount></game><game><path>./_UNREGISTERED/Hacks/Promo.gb</path><name>Local</name><playcount>3</playcount><playtime/><lastplayed/>'+ $extra+'</game></gameList>')
 $script:XmlPlan=Prepare-GamelistSystem $XmlJob $Session -SnapshotOnly
}
function PromotionApply($p){Invoke-ClassificationPromotions @($p) $Context $Session}
PromotionSetup
$p=Prepare
Check ($p.Promotions.Count-eq1-and@($p.Inventory|Where-Object Action -CEQ PROMOTE_TO_MANAGED).Count-eq1) 'production prepare eligible promotion'
Check ($p.ProtectMedia-and$p.ReviewIsolation.Groups.Count-eq0) 'promotion media HOLD canonical not excluded from managed presence'
Check ($p.Promotions[0].XmlEvidence.LocalNodeSha256-ne'ABSENT'-and$p.PreparedXmlSha) 'XML/node/staging evidence bound'
$before=Hash $Remote['/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Promo.gb']
PromotionApply $p
Check ($Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/Promo.gb')-and-not$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Promo.gb')) 'actual adapter commands mock verified move'
Check ((Hash $Remote['/storage/emulated/0/ROMs/gb/Hacks/Promo.gb'])-ceq$before) 'promotion SHA preserved'
Check ($p.CompletedPromotions-eq1-and$p.XmlPlan.ClassificationCommitted) 'completion only after XML'
Check ((Get-Content $Context.File -Raw|ConvertFrom-Json).status-ceq'completed') 'transaction completed state'
Confirm-ClassificationInventory $p $Session
$callStart=$Calls.Count;Sync-ClassifiedManagedRom $RomJob $p 'ROM'
Check (@($Calls|Select-Object -Skip $callStart|Where-Object {$_-match'push .*Hacks/Promo.gb'}).Count-eq0) 'post promotion canonical push zero'
$xml=ConvertFrom-EsdeGamelistBytes $Remote[$XmlRemote];$nodes=@(Get-EsdeGameEntries $xml|Where-Object Key -CEQ './Hacks/Promo.gb')
Check ($nodes.Count-eq1-and$nodes[0].Node.playcount-ceq'3') 'canonical node1 runtime preserved'
Check (@(Get-EsdeGameEntries $xml|Where-Object Key -like '*_UNREGISTERED*').Count-eq0) 'old XML local path absent'
$sum=Get-PromotionSummaryProposal $p.Inventory $p.CompletedPromotions
Check ($sum.PromotedCount-eq1-and$sum.LocalOnlyCount-eq3-and$sum.ReviewCount-eq0) 'official summary promotion independent start counts'
PromotionSetup '<unknown>custom</unknown>';$p=Prepare;Check ($p.Promotions.Count-eq0-and@($p.Inventory|Where-Object Action -CEQ PRESERVE_AND_REVIEW).Count-eq1) 'unknown metadata fallback REVIEW'
PromotionSetup;$UnknownEnvironment=$true;$p=Prepare;Check ($p.Promotions.Count-eq0) 'unverified environment fallback'
PromotionSetup;Put '/storage/emulated/0/ROMs/gb/Hacks/Promo.gb' 'PROMOROM';$p=Prepare;Check ($p.Promotions.Count-eq0) 'canonical existing sameSHA no cleanup'
PromotionSetup;Put '/storage/emulated/0/ROMs/gb/Hacks/Promo.gb' 'OTHER';$p=Prepare;Check ($p.Promotions.Count-eq0) 'canonical existing differentSHA no overwrite'
PromotionSetup;$LinkParent='/storage/emulated/0/ROMs/gb/Hacks';Reject 'parent symlink preflight' {Prepare}
PromotionSetup;$Redirect=$true;Reject 'canonical redirect preflight' {Prepare}
foreach($failure in @('LateRevision','MoveFailure','BadSha','MasterRace')){
 PromotionSetup;$p=Prepare;Set-Variable -Scope Script -Name $failure -Value $true
 Reject ($failure+' transaction') {PromotionApply $p}
 Check ((Get-Content $Context.File -Raw|ConvertFrom-Json).status-ceq'recovery-needed') ($failure+' recovery-needed state')
 Reject ($failure+' next sync gate') {New-ClassificationContext $state $SourceRoot $Serial}
}
PromotionSetup;$p=Prepare;[IO.File]::AppendAllText($p.XmlPlan.Output,' ');Reject 'staging evidence changed before mutation' {PromotionApply $p};Check ($Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Promo.gb')) 'tampered staging ROM untouched'
PromotionSetup;$p=Prepare;$Fail='xml-push';Reject 'ROM move XML failure' {PromotionApply $p};Check ($Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/Promo.gb')) 'no reverse move after XML fail';Reject 'XML failure next sync blocked' {New-ClassificationContext $state $SourceRoot $Serial}
PromotionSetup;$p=Prepare;Put '/storage/emulated/0/ROMs/gb/Hacks/promo.gb' 'OTHER';Reject 'late destination case variant' {PromotionApply $p}
PromotionSetup;$p=Prepare;$Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb');Put '/storage/emulated/0/ROMs/gb/OtherFan.gb' 'NEW UNMANAGED';$p=Prepare;PromotionApply $p;Check ($Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/OtherFan.gb')-and$Remote.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/Promo.gb')) 'mixed normal classification/promotion ROM moves';Check ((Get-Content $Context.File -Raw|ConvertFrom-Json).parentAttempts.Count-gt0) 'parent attempt evidence persisted'
PromotionSetup;$p=Prepare;$broken=[pscustomobject]@{schemaVersion=1;identity=$Context.Identity;status='recovery-needed'};[void][IO.Directory]::CreateDirectory((Split-Path -Parent $Context.File));Write-MediaJson $Context.File $broken $Context.StateRoot;Reject 'direct executor stale context cannot bypass unfinished state' {PromotionApply $p}
PromotionSetup;Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/OtherName.gb' 'PROMOROM';$p=Prepare;Check ($p.Promotions.Count-eq1-and$p.ReviewRequired) 'approved promotion plus different-name local REVIEW coexist';PromotionApply $p;$xml=ConvertFrom-EsdeGamelistBytes $Remote[$XmlRemote];$nodes=@(Get-EsdeGameEntries $xml|Where-Object Key -CEQ './Hacks/Promo.gb');Check ($nodes.Count-eq1-and$nodes[0].Node.name-ceq'Canonical'-and$nodes[0].Node.playcount-ceq'3') 'approved canonical metadata not suppressed by other review candidate';Check ($Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/OtherName.gb')) 'other local review remains untouched'
# Strict native result handling independently tested without Android.
Set-Item Function:Invoke-PromotionShell -Value $originalShell
$originalAdb=(Get-Item Function:Invoke-Adb).ScriptBlock
function Invoke-Adb{[pscustomobject]@{Code=0;StdOut='';StdErr='unexpected warning'}}
Reject 'production shell stderr fail closed' {Invoke-PromotionShell 'readonly'}
Set-Item Function:Invoke-Adb -Value $originalAdb
Set-Item Function:Get-PromotionEnvironmentEvidence -Value $originalEnvironment
$Serial='not-approved'
Check (-not(Get-PromotionEnvironmentEvidence gb $null $null './a.gb').Verified) 'other vendor/serial not approved'
$Serial='7b67d4e2'
$script:EnvironmentFail=''
function Invoke-PromotionShell($cmd){
 if($cmd.StartsWith('sha256sum ')){if($script:EnvironmentFail-ceq'hash'){return 'wrong'};return 'b224183630dd375291bd67c605d31ce247dc3b7fe78aa4e2361cf82fd4fae111  /storage/emulated/0/Android/data/com.retroarch.aarch64/files/retroarch.cfg'+[char]10}
 if($cmd.StartsWith('if pidof')){return 'STOPPED'}
 if($cmd.Contains('-iname')){if($script:EnvironmentFail-ceq'override'){return 'SameBoy/Game.cfg'};return ''}
 if($cmd.Contains('-type l')){if($script:EnvironmentFail-ceq'link'){return 'link'};return ''}
 throw 'unexpected environment query'
}
$envLocal=ConvertFrom-EsdeGamelistBytes (Bytes '<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList/>')
$envMaster=ConvertFrom-EsdeGamelistBytes (Bytes '<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>./Promo.gb</path></game></gameList>')
Check ((Get-PromotionEnvironmentEvidence gb $envLocal $envMaster './Promo.gb').Verified) 'registered actual SameBoy evidence contract'
foreach($reason in @('hash','override','link')){$EnvironmentFail=$reason;Check (-not(Get-PromotionEnvironmentEvidence gb $envLocal $envMaster './Promo.gb').Verified) ('environment '+$reason+' REVIEW')}
$EnvironmentFail=''
$envLocal=ConvertFrom-EsdeGamelistBytes (Bytes '<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>./_UNREGISTERED/Promo.gb</path><altemulator>OtherCore</altemulator></game></gameList>')
Check (-not(Get-PromotionEnvironmentEvidence gb $envLocal $envMaster './Promo.gb').Verified) 'local game other-core override REVIEW'
Check (-not(Get-PromotionEnvironmentEvidence gba $envLocal $envMaster './Promo.gb').Verified) 'unsupported system promotion false'
$reply=[pscustomobject]@{Code=0;StdOut='';StdErr='C:\fixture\staged.xml: 1 file pushed, 0 skipped. 20.0 MB/s (1234 bytes in 0.001s)'+[char]13+[char]10}
Check (Test-PromotionAdbResult $reply @('-s','mock','push','C:\fixture\staged.xml','/remote/gamelist.xml')) 'native successful transfer ack stderr allowed'
$reply.StdErr='/remote/gamelist.xml: 1 file pulled, 0 skipped. 20.0 MB/s (1234 bytes in 0.001s)'
Check (Test-PromotionAdbResult $reply @('-s','mock','pull','/remote/gamelist.xml','C:\fixture\back.xml')) 'native successful pull ack allowed'
$reply.StdErr+=' ERROR'
Check (-not(Test-PromotionAdbResult $reply @('-s','mock','pull','/remote/gamelist.xml','C:\fixture\back.xml'))) 'ack plus error rejected'
$reply.StdErr='other: 1 file pulled, 0 skipped.'
Check (-not(Test-PromotionAdbResult $reply @('-s','mock','pull','/remote/gamelist.xml','C:\fixture\back.xml'))) 'wrong transfer source rejected'
$reply.StdErr='/remote/gamelist.xml: 1 file pulled, 0 skipped.';$reply.Code=1
Check (-not(Test-PromotionAdbResult $reply @('-s','mock','pull','/remote/gamelist.xml','C:\fixture\back.xml'))) 'nonzero transfer rejected even ack'
$reply.Code=0;$reply.StdErr='';$reply.StdOut='unexpected ERROR'
Check (-not(Test-PromotionAdbResult $reply @('-s','mock','pull','/remote/gamelist.xml','C:\fixture\back.xml'))) 'unexpected transfer stdout rejected'
$reply.StdOut='/remote/gamelist.xml: 1 file pulled, 0 skipped.'
Check (Test-PromotionAdbResult $reply @('-s','mock','pull','/remote/gamelist.xml','C:\fixture\back.xml')) 'normal transfer ack stdout accepted'
'production promotion adapter 검증 완료: '+$script:Passed