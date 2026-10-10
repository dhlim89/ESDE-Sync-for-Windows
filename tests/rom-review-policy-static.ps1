$ErrorActionPreference='Stop'
# Reuse the verified production-function mock fixture; no real ADB/provider is loaded.
. (Join-Path $PSScriptRoot 'unregistered-move-static.ps1')
$script:Passed=0
function Row($p,$h){[pscustomobject]@{RelativePath=$p;Sha256=$h}}
$map=@{MANAGED='SYNC';MANAGED_CONFLICT='PRESERVE_AND_WARN';MANAGED_PATH_MISMATCH='REVIEW';UNMANAGED='MOVE_TO_UNREGISTERED';AMBIGUOUS='REVIEW';LOCAL_ONLY='PRESERVE';INVALID='BLOCK'}
$fixture=Get-Content (Join-Path $PSScriptRoot 'rom-classification/cases.json') -Raw -Encoding UTF8|ConvertFrom-Json
$entries=@()
foreach($case in $fixture){$r=@(New-UnregisteredClassificationPlan gb $case.Source $case.Android @() @('gb'))[0];$entries+=$r;Check ($r.Action-ceq$map[$r.Classification]) ($r.Classification+' final action')}
$conflict=@($entries|Where-Object Classification -CEQ MANAGED_CONFLICT)[0]
$n=Get-RomClassificationNotice $conflict
Check ($n.ManagedSha256-ceq('a'*64) -and $n.AndroidSha256-ceq('b'*64)) 'conflict managed/Android SHA retained'
Check ($n.Message-like'*리비전*' -or $n.Message-like'*리비전*') 'conflict user revision warning'
$script:Logs=@();Write-RomClassificationNotice $conflict
Check ($Logs[0]-like'*action=PRESERVE_AND_WARN*' -and $Logs[0]-like'*managedSHA=*' -and $Logs[0]-like'*androidSHA=*') 'conflict diagnostic log'
Setup
$script:Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
Put '/storage/emulated/0/ROMs/gb/managed.gb' 'PATCHED'
[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/other.gb'),'OTHER')
$p=Prepare
Check (@($p.Inventory|Where-Object Classification -CEQ MANAGED_CONFLICT).Count-eq1) 'conflict classification'
Check ($p.Moves.Count-eq0) 'conflict move 0'
Check (-not$p.ReviewRequired) 'conflict does not block system'
$old=Hash $script:Remote['/storage/emulated/0/ROMs/gb/managed.gb']
Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/managed.gb'])-ceq$old) 'conflict ROM preserve'
Check (@($Calls|Where-Object {$_-match'push .*ROMs/gb/managed.gb'}).Count-eq0) 'conflict push 0'
Check (@($Calls|Where-Object {$_-match'(rm |mv ).*ROMs/gb/managed.gb'}).Count-eq0) 'conflict delete/move 0'
Check ((Hash $script:Remote['/storage/emulated/0/ROMs/gb/other.gb'])-ceq(Hash (Bytes 'OTHER'))) 'other managed sync unaffected'
Sync-GamelistSystem $p.XmlPlan
$doc=ConvertFrom-EsdeGamelistBytes $script:Remote[$XmlRemote]
$node=$doc.Document.DocumentElement.SelectSingleNode('gameList/game[path="./managed.gb"]')
Check ($node.SelectSingleNode('name').InnerText-ceq'Master') 'conflict managed metadata'
Check ($node.SelectSingleNode('playcount').InnerText-ceq'0') 'conflict runtime'
# Existing fixture additionally verified actual production media transaction for a conflict.
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'unregistered-move-static.ps1'))
Check ($source.Contains('conflict media managed deployment')) 'conflict media integration fixture retained'
foreach($kind in @('MANAGED_PATH_MISMATCH','AMBIGUOUS')){
 Setup
 $script:Remote.Remove('/storage/emulated/0/ROMs/gb/Hacks/fan.gb')
 $script:Remote.Remove('/storage/emulated/0/ROMs/gb/managed.gb');Put '/storage/emulated/0/ROMs/gb/renamed.gb' 'MANAGED'
 if($kind-ceq'AMBIGUOUS'){[IO.File]::WriteAllText((Join-Path $SourceRoot 'roms/gb/copy.gb'),'MANAGED')}
 $p=Prepare;$beforeCalls=$Calls.Count;$beforeXml=Hash $script:Remote[$XmlRemote]
 $item=@($p.Inventory|Where-Object Classification -CEQ $kind)[0];$n=Get-RomClassificationNotice $item
 Check ($item.Action-ceq'REVIEW') ($kind+' action')
 Check ($p.ReviewRequired -and $p.Moves.Count-eq0 -and $p.ProtectMedia -and $p.ReviewIsolation.ExcludedRomPaths.Count-ge2) ($kind+' ROM/XML/media gate')
 Apply $p;Sync-ClassifiedManagedRom $RomJob $p 'MOCK'
 Check (@($Calls|Select-Object -Skip $beforeCalls|Where-Object {$_-match' push |mv |rm '}).Count-eq0) ($kind+' mutation jobs 0')
 Check ((Hash $script:Remote[$XmlRemote])-ceq$beforeXml) ($kind+' gamelist rewrite 0')
 Check (-not$script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/managed.gb')) ($kind+' duplicate canonical suppressed')
 Check ($n.CanonicalPaths -contains'managed.gb' -and $n.ShaCandidates.Count-eq$(if($kind-ceq'AMBIGUOUS'){2}else{1})) ($kind+' candidate paths retained')
 Check (-not[string]::IsNullOrWhiteSpace($n.Message)) ($kind+' Korean warning')
 Check ($p.Moves.Count-eq0) ($kind+' save/state/media rename 0')
}
$summary=Get-RomReviewSummary $entries
Check ($summary.ReviewCount-eq3 -and $summary.NoMutationReviewCount-eq2) 'review count including conflict warning'
Check ($summary.ManagedCount-eq1 -and $summary.UnmanagedMoveCount-eq1) 'managed/move counts unaffected'
Check ($summary.LocalOnlyCount-eq2) 'local-only count'
Check ($summary.Reasons.Count-eq3 -and @($summary.Reasons|Where-Object Count -NE 1).Count-eq0) 'per-reason counts'
Check ($summary.Items.Count-eq3) 'per-item reasons/messages'
$empty=Get-RomReviewSummary @()
Check ($empty.ReviewCount-eq0 -and $empty.ManagedCount-eq0) 'empty summary'
Write-Output ('review policy 검증 완료: '+$script:Passed)