$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
foreach($file in @('sync-worker.ps1','ESDE-Sync.ps1')){
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file),[ref]$null,[ref]$null)
 foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
}
. (Join-Path $PSScriptRoot 'support/duplicate-remote-harness.ps1')
$ReservedFolders=@('_TEST','_UNREGISTERED');$script:Passed=0;$script:AdbCalls=0
function Invoke-Adb {throw 'REMOTE TEST: actual ADB forbidden'}
function Invoke-PromotionShell {throw 'REMOTE TEST: actual shell forbidden'}
function Write-Log($m){}
function Check($ok,$name){if(-not$ok){throw $name};$script:Passed++;'PASS: '+$name}
function Reject($body,$name){$blocked=$false;try{& $body|Out-Null}catch{$blocked=$true};Check $blocked $name}
function Xml($text){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($text))}
$evidence=Join-Path $env:TEMP ('ESDE-v180-remote-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($evidence)
function New-Case($extensions=@(),$extra='',$failure=''){
 $parent=Join-Path $evidence ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($parent)
 $original=Join-Path $parent 'production-master.xml';$m=Xml '<gameList><game><path>./New.gb</path><name>Managed display</name></game></gameList>';Write-EsdeGamelist $m $original|Out-Null
 $ctx=New-DuplicateRemoteStaging $original (Join-Path $parent 'staging')
 $input=Read-EsdeGamelist $ctx.Input;$modified=ConvertFrom-EsdeGamelistBytes $input.Bytes; $desc=$modified.Document.CreateElement('desc');$desc.InnerText='isolated staging fixture';[void]$modified.Document.SelectSingleNode('//game').AppendChild($desc);$modified.Bytes=ConvertTo-EsdeGamelistBytes $modified
 $ctx|Add-Member ManagedFile (Join-Path $ctx.Root 'source/New.gb')
 $bytes=[Text.Encoding]::UTF8.GetBytes('remote test ROM bytes');[IO.File]::WriteAllBytes($ctx.ManagedFile,$bytes)
 $ctx|Add-Member XmlFile (Resolve-DuplicateFakePath $ctx '/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml')
 $local=Xml ('<gameList><folder><path>./_UNREGISTERED</path><lastplayed>20261011T093913</lastplayed><custom>keep</custom></folder><game><path>./_UNREGISTERED/Old.gb</path>'+ $extra+'</game><game><path>./Keep.gb</path><name>Unrelated</name></game></gameList>')
 $ctx|Add-Member BeforeXml $local.Bytes;$ctx|Add-Member Actions (New-Object 'Collections.Generic.List[string]');$ctx|Add-Member Safe $true;$ctx|Add-Member Fail $failure;$ctx|Add-Member Validations 0
 foreach($path in @('/storage/emulated/0/ROMs/gb/New.gb','/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb','/storage/emulated/0/ROMs/gb/_TEST/Protected.gb')){$p=Resolve-DuplicateFakePath $ctx $path;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p));[IO.File]::WriteAllBytes($p,$bytes)}
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ctx.XmlFile));[IO.File]::WriteAllBytes($ctx.XmlFile,$local.Bytes)
 foreach($dir in @('saves','states')){[void][IO.Directory]::CreateDirectory((Resolve-DuplicateFakePath $ctx ('/storage/emulated/0/RetroArch/'+$dir+'/SameBoy')))}
 $media=Resolve-DuplicateFakePath $ctx '/storage/emulated/0/ES-DE/downloaded_media/gb/covers/Keep.png';[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($media));[IO.File]::WriteAllText($media,'protected media')
 $saves=@();$states=@()
 foreach($ext in $extensions){$dir=if($ext-ceq'state'){'states'}else{'saves'};$path='/storage/emulated/0/RetroArch/'+$dir+'/SameBoy/Old.'+$ext;$p=Resolve-DuplicateFakePath $ctx $path;[IO.File]::WriteAllText($p,('asset '+$ext));$f=Get-DuplicateFakeFile $ctx $path;$row=[pscustomobject]@{RelativePath=('SameBoy/Old.'+$ext);Sha256=$f.Sha256;Size=$f.Size;Kind='File';IsLink=$false};if($dir-ceq'states'){$states+=@($row)}else{$saves+=@($row)}}
 $sha=(Get-FileHash -LiteralPath $ctx.ManagedFile).Hash.ToLowerInvariant()
 $source=[pscustomobject]@{System='gb';RelativePath='_UNREGISTERED/Old.gb';Sha256=$sha;Size=$bytes.Length;Kind='File';IsLink=$false}
 $canonical=$source.PSObject.Copy();$canonical.RelativePath='New.gb'
 $env=[pscustomobject]@{Verified=$true;Core='SameBoy';System='gb';CompleteAssetInventory=$true;CompleteMediaInventory=$true;CompleteSameBoyContentInventory=$true;PathIndependent=$true;Reference='REMOTE MOCK, not device verification'}
 $masterPath=Write-DuplicateStagingMaster $ctx $modified (Join-Path $ctx.Root 'master/fixture-master.xml')
 $master=Read-EsdeGamelist $masterPath
 $p=New-UnregisteredDuplicateProposal gb $source 'New.gb' @($canonical) @($source,$canonical) $local $master $env $saves $states @()
 Set-DuplicateScopedXml $p $local
 $p|Add-Member CanonicalNodeSha256 'ABSENT';$p|Add-Member EnvironmentSha256 'REMOTE';$p|Add-Member MediaSha256 'REMOTE'
 $selected=[pscustomobject]@{Id=$p.Id;SelectionBinding=(Get-DuplicateSelectionBinding $p)}
 [pscustomobject]@{Context=$ctx;Proposal=$p;Selected=$selected;IO=(New-DuplicateDiskAdapter $ctx);Local=$local;Master=$master;Source=$source;Canonical=$canonical;Environment=$env;Saves=$saves;States=$states}
}
function Run($case){$p=$case.Proposal;$io=$case.IO;Invoke-DuplicateCleanupBatch @($case.Selected) {param($s)$p}.GetNewClosure() {param($p)$io}.GetNewClosure() (Join-Path $case.Context.Root 'evidence/State') 'remote-identity' 'fake-device'}
function Journal($case){Get-Content -LiteralPath (Get-ChildItem (Join-Path $case.Context.Root 'evidence/State/duplicate-cleanup') -Filter '*.json'|Select-Object -First 1).FullName -Raw -Encoding UTF8|ConvertFrom-Json}
$c=New-Case;$ctx=$c.Context
Check ((Get-FileHash -LiteralPath $ctx.Input).Hash-ceq$ctx.OriginalSha256) 'production fixture to staging copy SHA equal'
Check ((Get-FileHash -LiteralPath $ctx.Master).Hash-cne$ctx.OriginalSha256) 'staging edit changes fixture output only'
Check ((Get-Item -LiteralPath $ctx.Input).Length-eq(Get-Item -LiteralPath $ctx.Original).Length) 'copy size equal'
Check ($ctx.Master.StartsWith($ctx.Root+'\')-and$ctx.Master-cne$ctx.Original) 'resolved master staging only'
Check (($ctx.Original -notin @($c.Master.InputPaths))-and$ctx.Master-notmatch'(?i)Dropbox') 'resolved master no production or Dropbox reference'
Reject {Write-DuplicateStagingMaster $ctx $c.Master $ctx.Original} 'production write blocked'
Reject {Write-DuplicateStagingMaster $ctx $c.Master (Join-Path $evidence 'outside.xml')} 'outside staging blocked'
Reject {Write-EsdeGamelist $c.Master $ctx.Master} 'production writer overwrite protection unchanged'
Check ((Get-FileHash -LiteralPath $ctx.Original).Hash-ceq$ctx.OriginalSha256) 'original SHA unchanged after staging edit'
Reject {Resolve-DuplicateFakePath $ctx '/storage/emulated/0/ROMs/gb/../outside.gb'} 'fake path traversal blocked'
$bad=Join-Path $ctx.Root 'master/bad.xml';[IO.File]::WriteAllText($bad,'<gameList>');Reject {Read-EsdeGamelist $bad} 'malformed staging XML fail closed'
Check ((Test-Path -LiteralPath $bad)-and(Test-Path -LiteralPath $ctx.Input)) 'failure evidence preserved'
Check ($c.Proposal.Grade-ceq'SAFE_DELETE'-and$c.Proposal.Classification-ceq'UNREGISTERED_MANAGED_DUPLICATE') 'disk fixture SAFE_DELETE proposal'
$beforeTest=(Get-DuplicateFakeFile $ctx '/storage/emulated/0/ROMs/gb/_TEST/Protected.gb').Sha256
$r=Run $c;Check ($r.SafeDelete-eq1-and$r.Failed-eq0) 'SAFE_DELETE disk transaction completed'
Check (-not(Get-DuplicateFakeFile $ctx '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Old.gb').Exists) 'duplicate exact source absent'
Check ((Get-DuplicateFakeFile $ctx '/storage/emulated/0/ROMs/gb/New.gb').Sha256-ceq$c.Proposal.ExpectedSha256) 'canonical SHA unchanged'
Check ((Get-DuplicateFakeFile $ctx '/storage/emulated/0/ROMs/gb/_TEST/Protected.gb').Sha256-ceq$beforeTest) 'TEST bytes unchanged'
Check ((Journal $c).status-ceq'completed') 'completed journal retained'
Assert-DuplicateRecoveryGate (Join-Path $ctx.Root 'evidence/State');Check $true 'completed journal gate permits scan'
$again=Run $c;Check ($again.Review-eq1-and@($ctx.Actions|Where-Object {$_-ceq'delete'}).Count-eq1) 'completed rerun safe refusal no second delete'
$c=New-Case @('srm','rtc','state') '<playcount>0</playcount><playtime/><lastplayed>20261011T093913</lastplayed>'
$ctx=$c.Context;$mediaPath=Resolve-DuplicateFakePath $ctx '/storage/emulated/0/ES-DE/downloaded_media/gb/covers/Keep.png';$mediaSha=(Get-FileHash -LiteralPath $mediaPath).Hash;$r=Run $c;Check ($r.SafeMergeDelete-eq1-and$r.Failed-eq0) 'SAFE_MERGE_DELETE real disk mock succeeds'
Check ((Get-FileHash -LiteralPath $mediaPath).Hash-ceq$mediaSha) 'media unchanged after merge delete'
Check ((Get-FileHash -LiteralPath $ctx.Original).Hash-ceq$ctx.OriginalSha256) 'original master unchanged after transaction'
foreach($op in @($c.Proposal.Operations|Where-Object Kind -In @('Save','State'))){$old=Get-DuplicateFakeFile $ctx ($op.Root+'/'+$op.SourceRelativePath);$new=Get-DuplicateFakeFile $ctx ($op.Root+'/'+$op.DestinationRelativePath);Check (-not$old.Exists-and$new.Exists-and$new.Sha256-ceq$op.ExpectedSha256-and$new.Size-eq$op.Size) ($op.Kind+' '+$op.SourceRelativePath+' size SHA preserved')}
Check ($ctx.Actions[-1]-ceq'delete'-and$ctx.Actions[3]-ceq'xml') 'asset migration XML commit ROM delete last'
$after=Read-EsdeGamelist $ctx.XmlFile;$games=@(Get-EsdeGameEntries $after);$node=@($games|Where-Object Key -CEQ './New.gb')[0].Node
Check ($games.Count-eq2-and-not@($games|Where-Object Key -CEQ './_UNREGISTERED/Old.gb').Count) 'canonical one old zero no synthetic duplicate'
Check ($node.playcount-ceq'0'-and$node.playtime-ceq''-and$node.lastplayed-ceq'20261011T093913'-and$node.name-ceq'Managed display') 'runtime zero empty timestamp and master display preserved'
Check (@(Get-EsdeFolderEntries $after)[0].Node.OuterXml-ceq@(Get-EsdeFolderEntries $c.Local)[0].Node.OuterXml) 'folder whole metadata unchanged'
Check (@($games|Where-Object Key -CEQ './Keep.gb')[0].Node.OuterXml-ceq@(Get-EsdeGameEntries $c.Local|Where-Object Key -CEQ './Keep.gb')[0].Node.OuterXml) 'unrelated game semantics unchanged'
foreach($phase in @('prepared','assets_moved','xml_committed','rom_deleted')){
 $ext=if($phase-ceq'assets_moved'){@('srm','rtc','state')}else{@('srm')};$c=New-Case $ext '' $phase;$r=Run $c;$j=Journal $c
 Check ($r.Failed-eq1-and$j.status-ceq'recovery-needed'-and$j.lastSuccessfulPhase-ceq$phase) ($phase+' failure exact recovery phase')
 Reject {Assert-DuplicateRecoveryGate (Join-Path $c.Context.Root 'evidence/State')} ($phase+' shared normal sync recovery gate blocks')
 Reject {Run $c} ($phase+' duplicate cleanup gate blocks')
 $before=Get-ChildItem -LiteralPath $c.Context.Root -Recurse -File|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash};$report=Get-DuplicateRecoveryReport $j $c.IO;$afterHashes=Get-ChildItem -LiteralPath $c.Context.Root -Recurse -File|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash}
 Check (($before-join'|')-ceq($afterHashes-join'|')-and-not$report.AutomaticResumeAllowed-and-not$report.AutomaticRollbackAllowed) ($phase+' read only recovery report no rollback')
}
# Existing proposal helpers are exercised with each independent unsafe input.
foreach($kind in @('srm','rtc','state','slot','auto','media','custom','attribute','multiple','sha','missing','link','traversal','TEST')){
 $c=New-Case;$saves=@();$states=@();$media=@();$managed=@($c.Canonical);$android=@($c.Source,$c.Canonical)
 $asset=[pscustomobject]@{RelativePath='SameBoy/New.'+$kind;Sha256=('b'*64);Size=32;Kind='File';IsLink=$false}
 switch($kind){
  srm {$saves=@($asset)} rtc {$saves=@($asset)} state {$states=@($asset)}
  slot {$asset.RelativePath='SameBoy/Old.state1';$states=@($asset)} auto {$asset.RelativePath='SameBoy/Old.auto';$states=@($asset)}
  media {$asset.RelativePath='covers/Old.png';$media=@($asset)}
  custom {$n=$c.Local.Document.CreateElement('custom');[void]$c.Local.Document.SelectSingleNode('//game').AppendChild($n);$c.Local.Bytes=ConvertTo-EsdeGamelistBytes $c.Local}
  attribute {$c.Local.Document.SelectSingleNode('//game').SetAttribute('custom','x');$c.Local.Bytes=ConvertTo-EsdeGamelistBytes $c.Local}
  multiple {$other=$c.Canonical.PSObject.Copy();$other.RelativePath='Other.gb';$managed+=@($other)}
  sha {$c.Canonical.Sha256='c'*64} missing {$android=@($c.Source)} link {$c.Source.IsLink=$true}
  traversal {$c.Source.RelativePath='_UNREGISTERED/../Old.gb'} TEST {$c.Source.RelativePath='_TEST/Old.gb'}
 }
 $blocked=$false;$p=$null;try{$p=New-UnregisteredDuplicateProposal gb $c.Source 'New.gb' $managed $android $c.Local $c.Master $c.Environment $saves $states $media}catch{$blocked=$true}
 if($kind-ceq'TEST'){Check ($null-eq$p) 'TEST scan count candidate zero';$view=ConvertTo-DuplicateManagerViewModel @();Check ($view.Rows.Count-eq0-and$view.ConfirmedDuplicateCount-eq0) 'TEST GUI row count zero'}else{Check ($blocked-or$p.Grade-ceq'REVIEW_ONLY') ($kind+' REVIEW/BLOCK')}
}
Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
$c=New-Case;$p=$c.Proposal;$p|Add-Member Sha256 $p.ExpectedSha256;$p|Add-Member AssetMoves @();$p|Add-Member MetadataMerge $false
$holder=[pscustomobject]@{Result=$null};$case=$c
$ui=New-DuplicateManagerDialog ([pscustomobject]@{rows=@($p)}) {param($ids)$holder.Result=Run $case}.GetNewClosure() {param($text)$true}
try{
 Check ($ui.Grid.Columns.Count-eq7-and-not[bool]$ui.Grid.Rows[0].Cells[0].Value) 'actual GUI disk proposal seven columns unchecked'
 Set-DuplicateUiSelection $ui $true;Invoke-DuplicateUiSelection $ui
 Check ($holder.Result.SafeDelete-eq1) 'GUI selection to production transaction core fake disk'
 Check ((Format-DuplicateResult $holder.Result).Contains('정리 완료: 1')) 'GUI result formatter transaction count'
}finally{$ui.Dialog.Dispose()}
$summary=@{PassCount=$script:Passed;EvidenceRoot=$evidence;ActualAndroidAccess=0;DropboxMutation=0;RemoteOnly=$true;LiveStage3Complete=$false}
[IO.File]::WriteAllText((Join-Path $evidence 'REMOTE-RESULT.json'),($summary|ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
'EVIDENCE: '+$evidence
'PASS TOTAL: '+$script:Passed
