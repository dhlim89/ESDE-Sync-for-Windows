$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$passed=0;function Check($ok,$name){if(-not$ok){throw $name};$script:passed++;Write-Host ('PASS: '+$name)}
function Reject($work,$name){$caught=$false;try{&$work|Out-Null}catch{$caught=$true};Check $caught $name}
function Write-Log($m){}
$Serial='fake';$root=Join-Path $env:TEMP ('inventory-opt-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);$SourceRoot=$root
$remote='/storage/emulated/0/ROMs/gb';$names=@('Game.gb','공백 한글 (괄호) [대괄호].gb',"O'Brien & Unicode Ω.gb")
$text=($names|ForEach-Object {"12`t1700000000`t81b0`t58`t42`t$remote/$_"})-join"`n"
$rows=@(ConvertFrom-BatchFileStats $text $remote);Check ($rows.Count-eq3-and$rows[1].Mtime-eq1700000000) 'batch stat Unicode spaces parentheses apostrophe ampersand'
$sha=('a'*64);$hashes=($names|ForEach-Object {$sha+'  '+$remote+'/'+$_})-join"`n"
$map=ConvertFrom-BatchFileHashes $hashes $remote $rows;Check ($map.Count-eq3-and$map[$names[2]]-ceq$sha) 'batch SHA exact path binding'
Reject {ConvertFrom-BatchFileHashes ($sha+'  '+$remote+'/Game.gb') $remote $rows} 'missing file partial hash BLOCK'
Reject {ConvertFrom-BatchFileHashes ($sha+'  /outside/Game.gb') $remote $rows} 'SHA root escape BLOCK'
Reject {ConvertFrom-BatchFileStats ("12`t1`ta1ff`t58`t42`t$remote/link.gb") $remote} 'symlink mode BLOCK'
Reject {ConvertFrom-BatchFileStats ("12`t1`t81b0`t58`t42`t$remote/../Game.gb") $remote} 'traversal BLOCK'
Reject {ConvertFrom-BatchFileStats ($text+"`n"+($text-split"`n")[0]) $remote} 'duplicate stat BLOCK'
$hundred=@(1..100|ForEach-Object {[pscustomobject]@{RelativePath=('Game '+$_+'.gb')}});$h=($hundred|ForEach-Object {$sha+'  '+$remote+'/'+$_.RelativePath})-join"`n"
Check ((ConvertFrom-BatchFileHashes $h $remote $hundred).Count-eq100) '100 SHA results parsed'
$originalBatch=${function:Get-AndroidBatchInventory}
function Assert-RemotePath($p){}
$script:fakeHashText=$hashes;$script:statReads=0;$script:changed=$false;$script:permission=$false;$script:missingTools=$false;$script:commands=@()
function Invoke-PromotionShell($cmd){
 if($cmd-match'printf DIR'){return 'DIR'};if($cmd-match'readlink'){return $remote};if($cmd-match'-type l'){return ''}
 if($cmd-match'stat -c'){$script:statReads++;if($script:changed-and$script:statReads-gt1){return $text.Replace('1700000000','1700000001')};return $text};throw ('unexpected shell '+$cmd)
}
function Invoke-Adb {
 param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)$script:commands+=($Args-join' ')
 if($script:missingTools){if($Args-ccontains'pull'){[IO.File]::WriteAllBytes($Args[4],(New-Object byte[] 12));return [pscustomobject]@{Code=0;StdOut='';StdErr=''}};return [pscustomobject]@{Code=127;StdOut='';StdErr='not found'}}
 [pscustomobject]@{Code=if($script:permission){1}else{0};StdOut=$script:fakeHashText;StdErr=if($script:permission){'permission denied'}else{''}}
}
$batch=Get-AndroidBatchInventory $remote;Check ($batch.Rows.Count-eq3-and$script:commands.Count-eq1) 'single batch SHA invocation'
Check ($script:commands[0].Contains((Quote-Sh ($remote+'/'+$names[2])))) 'shell apostrophe quoting'
$script:statReads=0;$script:changed=$true;Reject {Get-AndroidBatchInventory $remote} 'changed after inventory BLOCK';$script:changed=$false;$script:permission=$true
Reject {Get-AndroidBatchInventory $remote} 'permission failure BLOCK';$script:permission=$false
$script:statReads=0;$script:missingTools=$true;$fallback=Get-AndroidBatchInventory $remote
Check ($fallback.HashMap.Count-eq3-and$fallback.HashMap['Game.gb']-cmatch'^[a-f0-9]{64}$') 'missing native SHA pull fallback complete binding';$script:missingTools=$false
$savedText=$text;$savedHash=$script:fakeHashText
foreach($n in @(1,100)){
 $text=(1..$n|ForEach-Object {"12`t1700000000`t81b0`t58`t$_`t$remote/Game $_.gb"})-join"`n";$script:fakeHashText=(1..$n|ForEach-Object {$sha+'  '+$remote+'/Game '+$_+'.gb'})-join"`n";$script:commands=@();$script:statReads=0
 $batch=Get-AndroidBatchInventory $remote;Write-Host ("rows="+@($batch.Rows).Count+" commands="+$script:commands.Count);Check (@($batch.Rows).Count-eq$n-and$script:commands.Count-eq1) ('actual adapter batch '+$n+' files')
}
$text="12`t1700000000`t81b0`t58`t42`t$remote/_TEST/Game.gb";Reject {Get-AndroidBatchInventory $remote -ExcludeTest} 'TEST escaped prune hard reject'
$text=$savedText;$script:fakeHashText=$savedHash
$nativeBefore=Get-AndroidBatchInventory $remote;$script:fakeHashText=$savedHash.Replace(('a'*64),('c'*64));$nativeAfter=Get-AndroidBatchInventory $remote
$s=@([pscustomobject]@{RelativePath='Game.gb';Sha256=('a'*64)})
$changedRows=@([pscustomobject]@{RelativePath='Game.gb';Sha256=$nativeAfter.HashMap['Game.gb']})
$changedPlan=@(New-UnregisteredClassificationPlan gb $s $changedRows @() @('gb'))
Check ($nativeBefore.Rows[0].Mtime-eq$nativeAfter.Rows[0].Mtime-and$changedPlan[0].Classification-ceq'MANAGED_CONFLICT') 'Android same-size same-mtime content change detected by SHA'
$script:fakeHashText=$savedHash
Initialize-Perf 'memo';$file=Join-Path $root 'Same Size.gb';[IO.File]::WriteAllText($file,'AAA');Initialize-InventorySession
$one=Get-PerfFileHash -LiteralPath $file;$two=Get-PerfFileHash -LiteralPath $file
Check ($one.Hash-ceq$two.Hash-and$script:Perf.counters.SourceHashMemoHits-eq1) 'guarded session source memo'
Reject {[IO.File]::WriteAllText($file,'BBB')} 'same-size content modification denied while guard alive'
function Invoke-VerifiedHashFixture {Get-PerfFileHash -LiteralPath $file}
$count=$script:Perf.counters.TotalHashCount;[void](Invoke-VerifiedHashFixture);Check ($script:Perf.counters.TotalHashCount-eq$count+1) 'mutation bypasses memo fresh SHA'
$time=(Get-Item -LiteralPath $file).LastWriteTimeUtc;Close-InventorySession;[IO.File]::WriteAllText($file,'BBB');(Get-Item -LiteralPath $file).LastWriteTimeUtc=$time;Initialize-InventorySession
$three=Get-PerfFileHash -LiteralPath $file;Check ($three.Hash-cne$one.Hash) 'same size mtime after invalidation rehashed'
$Serial='changed-device';Check (-not(Test-InventorySession)-and$null-eq$script:InventorySession) 'device changed invalidates snapshot'
$Serial='fake';Initialize-InventorySession;Close-InventorySession;Check ($null-eq$script:InventorySession) 'completion invalidation closes guards'
$savedIdentity=${function:Get-SourceHandleIdentity};function Get-SourceHandleIdentity($h){return $null}
Initialize-InventorySession;$count=$script:Perf.counters.TotalHashCount;[void](Get-PerfFileHash -LiteralPath $file);[void](Get-PerfFileHash -LiteralPath $file)
Check ($script:Perf.counters.TotalHashCount-eq$count+2-and$script:InventorySession.sourceHashes.Count-eq0) 'unreliable filesystem identity fresh SHA fallback'
Close-InventorySession;Set-Item Function:Get-SourceHandleIdentity -Value $savedIdentity
# Differential media plans versus the exact Stage 4A implementation.
$git=@(Get-ChildItem $env:TEMP -Directory -Filter 'esde-baseline-git-*'|ForEach-Object {Join-Path $_.FullName 'git/cmd/git.exe'}|Where-Object {Test-Path $_}|Select-Object -First 1)[0]
$reference=(& $git -C $repo show 014f60fcd378798b3535864256b79ff35d5e1e30:sync-worker.ps1)-join"`n"
$refAst=[Management.Automation.Language.Parser]::ParseInput($reference,[ref]$null,[ref]$null)
$fn=$refAst.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Prepare-MediaPlan'},$false)
. ([scriptblock]::Create($fn.Extent.Text.Replace('function Prepare-MediaPlan(','function Reference-MediaPlan(')))
function Get-RemoteFiles($p){return @($script:remoteHashes.Keys)};function Get-RemoteDirs($p){return @()};function Get-MediaRemoteHash($p,$s){return $script:remoteHashes[$p.Substring($p.LastIndexOf('/')+1)]}
function Get-AndroidBatchInventory {param($Root,[switch]$ExcludeReserved,$HashPaths,$HashPolicy)$r=@($script:remoteHashes.Keys|ForEach-Object {[pscustomobject]@{RelativePath=$_;Size=3}});[pscustomobject]@{Rows=$r;HashMap=$script:remoteHashes}}
function Normalize($plan){ConvertTo-Json -InputObject @($plan|Select-Object kind,system,relativePath,remote,oldHash,newHash) -Compress}
$selectedSystems=@('gb');$Buckets=@(@{Remote='/storage/emulated/0/ES-DE/downloaded_media'});$ReservedFolders=@('_TEST','_UNREGISTERED')
$job=[pscustomobject]@{System='gb';RemotePath='/storage/emulated/0/ES-DE/downloaded_media/gb'};$ctx=[pscustomobject]@{Session=$root;Manifest=[pscustomobject]@{entries=@()}}
$source=@([pscustomobject]@{system='gb';relativePath='Game.png';hash=$three.Hash.ToLowerInvariant();size=3;path=$file})
foreach($case in @('unchanged','create','update','collision')){
 Close-InventorySession;$script:remoteHashes=@{};$ctx.Manifest.entries=@()
 if($case-ceq'unchanged'){$script:remoteHashes['Game.png']=$source[0].hash}
 if($case-ceq'update'){$script:remoteHashes['Game.png']='a'*64;$ctx.Manifest.entries=@([pscustomobject]@{system='gb';relativePath='Game.png';deployedSha256=('a'*64)})}
 if($case-ceq'collision'){$script:remoteHashes['Game.png']='a'*64}
 $before=$null;$beforeError=$false;try{$before=Reference-MediaPlan @($job) $source $ctx}catch{$beforeError=$true;Write-Host ("reference diagnostic "+$_.Exception.Message)}
 Initialize-InventorySession;$after=$null;$afterError=$false;try{$after=Prepare-MediaPlan @($job) $source $ctx}catch{$afterError=$true;Write-Host ("optimized diagnostic "+$_.Exception.Message)};Close-InventorySession
 Check ($beforeError-eq$afterError-and($beforeError-or(Normalize $before)-ceq(Normalize $after))) ('reference media plan '+$case)
 if($case-ceq'create'-or$case-ceq'update'){Check ((Get-FileHash -LiteralPath $after[0].source.path).Hash-ine'BAD'-and$after[0].source.path-cne$file) ('immutable staging before mutation '+$case)}
}
Check ($reference.Contains("Get-RenameRemoteInventory '/storage/emulated/0/ROMs' -ExcludeTest")) 'reference repeat inventory confirmed'
$fn=$refAst.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-ClassificationAndroidRows'},$false)
. ([scriptblock]::Create($fn.Extent.Text.Replace('function Get-ClassificationAndroidRows(','function Reference-AndroidRows(')))
function Assert-ClassificationRemoteLinks($r){}
function Read-ClassificationRom($p,$s){[pscustomobject]@{Sha256=$script:remoteHashes[$p.Substring($p.LastIndexOf('/')+1)]}}
$script:remoteHashes=@{'Game.gb'=($three.Hash.ToLowerInvariant());'Extra.gb'=('b'*64)}
$job=[pscustomobject]@{System='gb';RemotePath='/storage/emulated/0/ROMs/gb'}
Close-InventorySession;$oldRows=@(Reference-AndroidRows $job $root);Initialize-InventorySession;$newRows=@(Get-ClassificationAndroidRows $job $root)
$owned=@([pscustomobject]@{RelativePath='Game.gb';Sha256=$three.Hash.ToLowerInvariant()})
$oldPlan=@(New-UnregisteredClassificationPlan gb $owned $oldRows @() @('gb'));$newPlan=@(New-UnregisteredClassificationPlan gb $owned $newRows @() @('gb'))
Check ((ConvertTo-Json -InputObject @($oldPlan|Sort-Object RelativePath) -Depth 12 -Compress)-ceq(ConvertTo-Json -InputObject @($newPlan|Sort-Object RelativePath) -Depth 12 -Compress)) 'reference classification proposal summary axes identical'
$oldSummary=Get-PromotionSummaryProposal $oldPlan 0;$newSummary=Get-PromotionSummaryProposal $newPlan 0
Check (($oldSummary|ConvertTo-Json -Depth 12 -Compress)-ceq($newSummary|ConvertTo-Json -Depth 12 -Compress)) 'reference official summary identical'
$fn=$refAst.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'New-UnregisteredDuplicateProposal'},$false)
. ([scriptblock]::Create($fn.Extent.Text.Replace('function New-UnregisteredDuplicateProposal(','function Reference-DuplicateProposal(')))
$duplicate=[pscustomobject]@{System='gb';RelativePath='_UNREGISTERED/Old.gb';Sha256=('a'*64);Size=12;Kind='File';IsLink=$false}
$canonical=[pscustomobject]@{System='gb';RelativePath='New.gb';Sha256=('a'*64);Size=12;Kind='File';IsLink=$false}
$master=ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<gameList><game><path>./New.gb</path><name>Master</name></game></gameList>')) 'fixture'
$local=ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<gameList><folder><path>./_UNREGISTERED</path><lastplayed>0</lastplayed></folder><game><path>./_UNREGISTERED/Old.gb</path></game></gameList>')) 'fixture'
$e=[pscustomobject]@{Verified=$true;Core='SameBoy';System='gb';CompleteAssetInventory=$true;CompleteMediaInventory=$true;CompleteSameBoyContentInventory=$true;PathIndependent=$true;Reference='MOCK'}
foreach($grade in @('SAFE_DELETE','SAFE_MERGE_DELETE','REVIEW_ONLY')){
 $saves=if($grade-ceq'SAFE_MERGE_DELETE'){@([pscustomobject]@{RelativePath='SameBoy/Old.srm';Sha256=('b'*64);Size=12;Kind='File';IsLink=$false})}else{@()}
 $media=if($grade-ceq'REVIEW_ONLY'){@([pscustomobject]@{RelativePath='screenshots/Old.png';Sha256=('b'*64);Size=12;Kind='File';IsLink=$false})}else{@()}
 $before=Reference-DuplicateProposal gb $duplicate 'New.gb' @($canonical) @($duplicate,$canonical) $local $master $e @($saves) @() @($media)
 $after=New-UnregisteredDuplicateProposal gb $duplicate 'New.gb' @($canonical) @($duplicate,$canonical) $local $master $e @($saves) @() @($media)
 Check ($before.Grade-ceq$grade-and$after.Grade-ceq$before.Grade-and($before.Operations|ConvertTo-Json -Depth 12 -Compress)-ceq($after.Operations|ConvertTo-Json -Depth 12 -Compress)) ('reference duplicate grade and asset/delete plan '+$grade)
 if($grade-cne'REVIEW_ONLY'){Check ([Convert]::ToBase64String($before.PreparedXml.Bytes)-ceq[Convert]::ToBase64String($after.PreparedXml.Bytes)) ('reference XML semantic bytes '+$grade)}
}
Close-InventorySession
Write-Host ('inventory optimization fixtures PASS: '+$passed)
