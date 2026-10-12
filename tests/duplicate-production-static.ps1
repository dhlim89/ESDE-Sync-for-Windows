$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
foreach($file in @('sync-worker.ps1','tests/duplicate-manager-static.ps1')){
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file),[ref]$null,[ref]$null)
 foreach($fn in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
}
$ReservedFolders=@('_TEST','_UNREGISTERED');$script:Passed=0
$script:NativeShell=(Get-Item Function:Invoke-PromotionShell).ScriptBlock
function Write-Log($message){}
function Assert-PromotionFileCase($path){if($script:CaseCollision){throw 'case collision'}}
function Assert-RenameFileCase($path){if($script:CaseCollision){throw 'case collision'}}
function Get-VerifiedRomParent($root,$parent,$create){if($script:ParentLink){throw 'parent symlink'};[pscustomobject]@{Safe=$true;Exists=$true;Kind='Directory';CanonicalPath=$parent;Device='1'}}
function Invoke-PromotionShell($cmd){
 $script:Commands+=$cmd
 $paths=@([regex]::Matches($cmd,"'([^']*)'")|ForEach-Object {$_.Groups[1].Value})
 if($cmd.Contains('; rm -- ')){
  $target=$paths[-1];if($script:FailDelete){throw 'injected delete failure'}
  if($cmd.Contains('rm -r')-or$target-notmatch'/gb/_UNREGISTERED/'){throw 'unsafe rm'}
  [void]$script:Store.Remove($target);$script:Actions+='delete'
  if($script:BadAfterDelete){$script:Store['/storage/emulated/0/ROMs/gb/New.gb'].Sha256='c'*64};return ''
 }
 if($cmd.Contains('mv -n ')){
  $s=$paths[-2];$d=$paths[-1];if($script:FailAsset){throw 'injected asset move'};if($script:Store.ContainsKey($d)){throw 'destination collision'}
  $script:Store[$d]=$script:Store[$s];[void]$script:Store.Remove($s);$script:Actions+='asset';return ''
 }
 if($cmd.StartsWith('if [ -L')-and$cmd.Contains('printf LINK')){
  $p=$paths[0];if($script:Store.ContainsKey($p)){if($script:Store[$p].IsLink){return 'LINK'};return 'FILE'};return 'ABSENT'
 }
 if($cmd.StartsWith('if [ -L')-and$cmd.Contains('readlink -f')){if($script:ParentLink){throw 'parent link'};return $paths[0]+[char]10}
 if($cmd.StartsWith('readlink -f ')){return $paths[0]+[char]10}
 if($cmd.StartsWith('stat -c %s:%d:%i ')){$f=$script:Store[$paths[0]];return ([string]$f.Size+':1:'+ $f.Inode+[char]10)}
 if($cmd.StartsWith('stat -c %s:%d ')){$f=$script:Store[$paths[0]];return ([string]$f.Size+':1'+[char]10)}
 if($cmd.StartsWith('stat -c %d ')){return '1'+[char]10}
 if($cmd.StartsWith('sha256sum ')){return $script:Store[$paths[0]].Sha256+'  '+$paths[0]+[char]10}
 throw ('fake shell unsupported: '+$cmd)
}
function Fixture($extensions=@(),$extra=''){
 Setup $extra;$script:CaseCollision=$false;$script:ParentLink=$false;$script:FailAsset=$false;$script:FailDelete=$false;$script:BadAfterDelete=$false;$script:FailXml=$false;$script:FailValidate=$false
 foreach($ext in $extensions){if($ext-ceq'state'){$script:States+=Asset 'SameBoy/Old.state'}else{$script:Saves+=Asset ('SameBoy/Old.'+$ext)}}
 $script:P=Plan;Set-DuplicateScopedXml $script:P $Local
 $script:P|Add-Member CanonicalNodeSha256 'ABSENT';$script:P|Add-Member EnvironmentSha256 'MOCK';$script:P|Add-Member MediaSha256 'MOCK'
 $script:P|Add-Member SelectionBinding (Get-DuplicateSelectionBinding $script:P)
 $script:Selected=[pscustomobject]@{Id=$P.Id;SelectionBinding=$P.SelectionBinding}
 $script:Store=@{};$index=0
 foreach($r in @($Android)+@($Saves)+@($States)){$index++;$path=if($r.RelativePath.StartsWith('SameBoy/')){if($r.RelativePath.EndsWith('.state')){'/storage/emulated/0/RetroArch/states/'+$r.RelativePath}else{'/storage/emulated/0/RetroArch/saves/'+$r.RelativePath}}else{'/storage/emulated/0/ROMs/gb/'+$r.RelativePath};$script:Store[$path]=[pscustomobject]@{Exists=$true;Kind='File';IsLink=$false;Sha256=$r.Sha256;Size=$r.Size;Device='1';Inode=[string]$index}}
 $script:Initial=@{};foreach($k in $Store.Keys){$Initial[$k]=$Store[$k].PSObject.Copy()}
 $script:XmlBytes=$Local.Bytes;$script:Actions=@();$script:Commands=@();$script:Safe=$true;$script:ManagedSha='a'*64;$script:RefreshStale=$false
 $script:JournalRoot=Join-Path $env:TEMP ('esde-duplicate-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($JournalRoot)
 $script:IO=[pscustomobject]@{Mode='Fixture';Asset=(New-RenameAssetAdbAdapter)
  AssertSafety={if(-not$script:Safe){throw 'unsafe foreground'}}
  Stat={param($path)Read-DuplicateAndroidFile $path 'gb'}
  Managed={param($p)[pscustomobject]@{Exists=$true;Kind='File';IsLink=$false;Sha256=$script:ManagedSha;Size=32}}
  DeleteExact={param($s,$c,$sha,$size)Invoke-DuplicateExactDeleteShell $s $c $sha $size 'gb'}
  Validate={param($p,$completed,$xml)
   if($script:FailValidate){throw 'late evidence'}
   [void](Read-DuplicateAndroidFile '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb' 'gb');[void](Read-DuplicateAndroidFile '/storage/emulated/0/ROMs/gb/New.gb' 'gb')
   foreach($k in $script:Initial.Keys){$expected=$k;foreach($op in $completed){if($k-ceq($op.Root+'/'+$op.SourceRelativePath)){$expected=$op.Root+'/'+$op.DestinationRelativePath}}
    if(-not$script:Store.ContainsKey($expected)-or$script:Store[$expected].Sha256-cne$script:Initial[$k].Sha256){throw 'late source/canonical/asset SHA'}
   }
   if($script:ManagedSha-cne$p.ExpectedSha256){throw 'managed source SHA'}
   $wanted=if($xml){$p.PreparedXml.Bytes}else{$script:Local.Bytes};if([Convert]::ToBase64String($script:XmlBytes)-cne[Convert]::ToBase64String($wanted)){throw 'XML evidence revision'}
  }
  ReadXmlFingerprint={Get-MediaTextHash ([Convert]::ToBase64String($script:XmlBytes))}
  CommitXml={param($p)if($script:FailXml){throw 'XML injected failure'};$script:XmlBytes=$p.PreparedXml.Bytes;$script:Actions+='xml'}
  Verify={param($p,$completed)if(-not$script:Store.ContainsKey('/storage/emulated/0/ROMs/gb/New.gb')-or$script:Store['/storage/emulated/0/ROMs/gb/New.gb'].Sha256-cne$p.ExpectedSha256){throw 'canonical verification'};foreach($op in $completed){if($script:Store[$op.Root+'/'+$op.DestinationRelativePath].Sha256-cne$op.ExpectedSha256){throw 'asset verification'}}}
 }
}
function Run {Invoke-DuplicateCleanupBatch @($script:Selected) {param($s)if($script:RefreshStale){throw 'stale row'};$script:P} {param($p)$script:IO} $script:JournalRoot 'fixture-identity' 'fixture-device'}
function Journal {Get-Content (Get-ChildItem (Join-Path $JournalRoot 'duplicate-cleanup') -Filter '*.json'|Select-Object -First 1).FullName -Raw -Encoding UTF8|ConvertFrom-Json}
Fixture;$r=Run;Check ($r.SafeDelete-eq1-and$r.Failed-eq0) 'SAFE_DELETE actual delete adapter fixture'
Check ($Store.ContainsKey('/storage/emulated/0/ROMs/gb/New.gb')-and-not$Store.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb')) 'source absent canonical unchanged'
Check ((Journal).status-ceq'completed') 'completed journal preserved'
Assert-DuplicateRecoveryGate $JournalRoot;Check $true 'completed gate permits next scan'
Check (@($Commands|Where-Object {$_-match'; rm -- '}).Count-eq1-and-not@($Commands|Where-Object {$_-match'rm -r'}).Count) 'exact single delete no wildcard recursive rm'
foreach($ext in @('srm','rtc','state')){Fixture @($ext);$r=Run;Check ($r.SafeMergeDelete-eq1-and$r.Failed-eq0) ($ext+' production move adapter fixture');$op=@($P.Operations|Where-Object Kind -In @('Save','State'))[0];Check ($Store[$op.Root+'/'+$op.DestinationRelativePath].Sha256-ceq$op.ExpectedSha256-and-not$Store.ContainsKey($op.Root+'/'+$op.SourceRelativePath)) ($ext+' hash and source absence')}
Fixture @('srm','rtc','state') '<playcount>0</playcount><playtime/><lastplayed/>';$r=Run;Check ($r.SafeMergeDelete-eq1) 'all 3 migration succeeds';$node=@(Get-EsdeGameEntries (ConvertFrom-EsdeGamelistBytes $XmlBytes))[0].Node
Check ($node.playcount-ceq'0'-and$node.playtime-ceq'') 'runtime zero empty preserved'
Check (@(Get-EsdeFolderEntries (ConvertFrom-EsdeGamelistBytes $XmlBytes)).Count-eq1) 'folder retained even last duplicate removed'
Check ([Array]::LastIndexOf($Actions,'asset')-lt[Array]::IndexOf($Actions,'xml')-and[Array]::IndexOf($Actions,'xml')-lt[Array]::IndexOf($Actions,'delete')) 'assets XML delete order'
Fixture;$RefreshStale=$true;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) 'stale revalidation no mutation'
foreach($path in @('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb','/storage/emulated/0/ROMs/gb/New.gb')){Fixture;$Store[$path].Sha256='c'*64;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) ('SHA changed before execution '+$path)}
foreach($path in @('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb','/storage/emulated/0/ROMs/gb/New.gb')){Fixture;[void]$Store.Remove($path);$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) ('file disappeared '+$path)}
Fixture;$ManagedSha='c'*64;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) 'managed source changed no mutation'
Fixture;$ParentLink=$true;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) 'parent symlink blocks delete'
Fixture;$P.SourceRelativePath='_TEST/Old.gb';$P.Binding=Get-DuplicateProposalBinding $P;$Selected.SelectionBinding=Get-DuplicateSelectionBinding $P;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) 'TEST hard rejected before journal'
Fixture;$P.SourceRelativePath='_UNREGISTERED/../Old.gb';$Selected.SelectionBinding=Get-DuplicateSelectionBinding $P;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) 'traversal blocked before mutation'
Fixture @('srm');$FailXml=$true;$r=Run;Check ($r.Failed-eq1-and(Journal).lastSuccessfulPhase-ceq'assets_moved') 'assets moved failure recovery journal'
Check ($Store.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb')) 'XML failure retains duplicate ROM'
Reject {Assert-DuplicateRecoveryGate $JournalRoot} 'incomplete gate blocks cleanup and normal sync'
$recovery=Get-DuplicateRecoveryReport (Journal) $IO;Check (-not$recovery.AutomaticResumeAllowed-and$recovery.Source.Exists) 'recovery report read only no automatic resume'
Fixture;$FailDelete=$true;$r=Run;Check ($r.Failed-eq1-and(Journal).lastSuccessfulPhase-ceq'xml_committed') 'XML committed failure journal'
Fixture;$BadAfterDelete=$true;$r=Run;Check ($r.Failed-eq1-and(Journal).lastSuccessfulPhase-ceq'rom_deleted') 'ROM deleted verification failure phase'
Fixture;$r=Run;$again=Run;Check ($again.Review-eq1-and@($Actions|Where-Object {$_-ceq'delete'}).Count-eq1) 'completed item cannot delete twice'
Fixture;$Safe=$false;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) 'unsafe foreground before journal no mutation'
Fixture;$Store['/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb'].IsLink=$true;$r=Run;Check ($r.Review-eq1-and-not@($Actions|Where-Object {$_-ceq'delete'}).Count) 'source symlink refused'
Fixture;$CaseCollision=$true;$r=Run;Check ($r.Review-eq1-and-not@($Actions|Where-Object {$_-ceq'delete'}).Count) 'case collision refused'
Setup;$Saves=@((Asset 'SameBoy/Old.srm'),(Asset 'SameBoy/New.srm'));Check ((Plan).Grade-ceq'REVIEW_ONLY') 'destination collision REVIEW'
Setup;$Media=@(Asset 'covers/Old.png');Check ((Plan).Grade-ceq'REVIEW_ONLY') 'media REVIEW'
foreach($ext in @('state1','auto','autosave')){Setup;$States=@(Asset ('SameBoy/Old.'+$ext));Check ((Plan).Grade-ceq'REVIEW_ONLY') ($ext+' REVIEW')}
Setup '<custom>x</custom>';Check ((Plan).Grade-ceq'REVIEW_ONLY') 'custom metadata REVIEW'
Setup;$Managed+=Row 'Another.gb';Check ((Plan).Grade-ceq'REVIEW_ONLY') 'multiple managed candidate REVIEW'
Fixture
$base=$P;$plans=@();$selections=@();$Store=@{}
foreach($i in 1..3){
 $item=$base.PSObject.Copy();$item.Id='gb:item'+$i;$item.SourceRelativePath='_UNREGISTERED/Old'+$i+'.gb';$item.CanonicalRelativePath='New'+$i+'.gb';$item.ExpectedSha256=([string][char](96+$i))*64
 $item.FileEvidence=@([pscustomobject]@{RelativePath=$item.SourceRelativePath;Sha256=$item.ExpectedSha256;Size=32},[pscustomobject]@{RelativePath=$item.CanonicalRelativePath;Sha256=$item.ExpectedSha256;Size=32})
 $item.Operations=@([pscustomobject]@{Kind='XmlCommit'},[pscustomobject]@{Kind='DeleteRomLast';SourceRelativePath=$item.SourceRelativePath;CanonicalRelativePath=$item.CanonicalRelativePath;ExpectedSha256=$item.ExpectedSha256})
 $item.PreparedXml=Xml ('<gameList><game><path>./'+$item.CanonicalRelativePath+'</path><name>Master</name></game></gameList>');$item.Binding=Get-DuplicateProposalBinding $item;$item.SelectionBinding=Get-DuplicateSelectionBinding $item
 $plans+=$item;$selections+=[pscustomobject]@{Id=$item.Id;SelectionBinding=$item.SelectionBinding}
 $Store['/storage/emulated/0/ROMs/gb/'+$item.SourceRelativePath]=[pscustomobject]@{Exists=$true;Kind='File';IsLink=$false;Sha256=$item.ExpectedSha256;Size=32;Device='1';Inode=[string]($i*2)}
 $Store['/storage/emulated/0/ROMs/gb/'+$item.CanonicalRelativePath]=[pscustomobject]@{Exists=$true;Kind='File';IsLink=$false;Sha256=$item.ExpectedSha256;Size=32;Device='1';Inode=[string]($i*2+1)}
}
$IO.Validate={param($p,$completed,$xml)};$IO.Verify={param($p,$completed)};$IO.Managed={param($p)[pscustomobject]@{Exists=$true;Kind='File';IsLink=$false;Sha256=$p.ExpectedSha256;Size=32}}
$factory={param($p)$script:FailDelete=($p.Id-ceq'gb:item2');$script:IO}
$r=Invoke-DuplicateCleanupBatch $selections {param($s)@($script:plans|Where-Object Id -CEQ $s.Id)[0]} $factory $JournalRoot 'fixture' 'device'
Check ($r.SafeDelete-eq1-and$r.Failed-eq1-and$r.Unprocessed-eq1) 'partial success failure stops subsequent item'
Check (-not$Store.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old1.gb')-and$Store.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old2.gb')-and$Store.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old3.gb')) 'completed previous preserved later untouched'
Check (@(Get-ChildItem (Join-Path $JournalRoot 'duplicate-cleanup') -Filter '*.json').Count-eq2) 'journals only for started selected items'
Fixture;$rows=@([pscustomobject]@{Id=$P.Id;SelectionBinding=$P.SelectionBinding});$r=Invoke-DuplicateCleanupBatch $rows {param($s)$script:P} {param($p)$script:IO} $JournalRoot 'fixture' 'device';Check ($r.SafeDelete-eq1-and$r.Items.Count-eq1) 'explicit subset only processed'
Fixture;$j=[pscustomobject]@{sourcePath='gb/_TEST/Test.gb';events=@();status='prepared';lastSuccessfulPhase='prepared'};Reject {Save-DuplicateJournal ([pscustomobject]@{File=(Join-Path $JournalRoot 'bad.json');StateRoot=$JournalRoot}) $j 'prepared'} 'TEST journal creation rejected'
Check (-not(Test-Path -LiteralPath (Join-Path $JournalRoot 'bad.json'))) 'TEST journal mutation zero'
# The production shell transport itself remains fail-closed on error/unknown stderr.
function Invoke-Adb {param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)[pscustomobject]@{Code=0;StdOut='';StdErr='unexpected error'}}
Reject {& $script:NativeShell 'any'} 'actual shell stderr rejected'
$worker=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'));Check ($worker.Contains('Assert-DuplicateRecoveryGate $StateDir')-and$worker.Contains('if($Operation-cne''Sync''){Invoke-DuplicateWorkerOperation;exit 0}')) 'normal sync separate route and shared recovery gate'
Check (-not$worker.Contains('Invoke-DuplicateTransactionMock')) 'no mock runtime or automatic cleanup'
Fixture @('srm');$FailXml=$true;$r=Run;$report=Get-DuplicateRecoveryReport (Journal) $IO;Check ($report.Xml.MatchesBefore-and-not$report.Xml.MatchesAfter) 'recovery XML before/after evidence read only'
$beforeFiles=@($Store.Keys|Sort-Object)-join'|';$beforeXml=[Convert]::ToBase64String($XmlBytes);[void](Get-DuplicateRecoveryReport (Journal) $IO);Check ((@($Store.Keys|Sort-Object)-join'|')-ceq$beforeFiles-and[Convert]::ToBase64String($XmlBytes)-ceq$beforeXml) 'recovery report no mutations'
Fixture @('srm');$Store['/storage/emulated/0/ROMs/gb/New.gb'].Inode=$Store['/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb'].Inode;$r=Run;Check ($r.Review-eq1-and$Actions.Count-eq0) 'same file inode rejected before asset XML mutation'
'PASS TOTAL: '+$script:Passed