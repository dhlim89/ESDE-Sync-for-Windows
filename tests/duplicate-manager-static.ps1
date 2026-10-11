$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
. (Join-Path $PSScriptRoot 'support/duplicate-manager-proposal.ps1')
$ReservedFolders=@('_TEST','_UNREGISTERED');$script:Passed=0
function Check($ok,$name){if(-not$ok){throw $name};$script:Passed++;'PASS: '+$name}
function Xml($s){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($s))}
function Row($path,$sha=('a'*64)){[pscustomobject]@{System='gb';RelativePath=$path;Sha256=$sha;Size=32;Kind='File';IsLink=$false}}
function Setup($extra='',$path='_UNREGISTERED/Old.gb'){
 $script:Source=Row $path;$script:Managed=@(Row 'New.gb');$script:Android=@($Source,(Row 'New.gb'))
 $script:Local=Xml ('<gameList><folder><path>./_UNREGISTERED</path><lastplayed>20261011T093913</lastplayed></folder><game><path>./'+$path+'</path>'+ $extra+'</game></gameList>')
 $script:Master=Xml '<gameList><game><path>./New.gb</path><name>Master</name></game></gameList>'
 $script:Evidence=[pscustomobject]@{Verified=$true;Core='SameBoy';System='gb';CompleteAssetInventory=$true;CompleteMediaInventory=$true;CompleteSameBoyContentInventory=$true;PathIndependent=$true;Reference='MOCK'}
 $script:Saves=@();$script:States=@();$script:Media=@()
}
function Plan {New-UnregisteredDuplicateProposal gb $Source 'New.gb' $Managed $Android $Local $Master $Evidence $Saves $States $Media}
function Asset($p){Row $p ('b'*64)}
function Reject($body,$name){$hit=$false;try{& $body|Out-Null}catch{$hit=$true};Check $hit $name}
Setup;$p=Plan;Check ($p.Grade-ceq'SAFE_DELETE') 'triple SHA no data SAFE_DELETE'
Check (-not$p.Selected-and$p.CheckboxEnabled-and-not$p.ProductionExecutable) 'default unchecked mock only'
Check (@($p.Operations|Where-Object Kind -In @('Save','State')).Count-eq0) 'SAFE_DELETE assets untouched'
Check ($p.Operations[-1].Kind-ceq'DeleteRomLast') 'ROM deletion last'
Check (@(Get-EsdeFolderEntries $p.PreparedXml).Count-eq1) 'folder preserved'
Check (@(Get-EsdeGameEntries $p.PreparedXml).Count-eq1) 'canonical single node no synthetic duplicate'
foreach($path in @('_TEST/Old.gb','_UNREGISTERED/_test/Old.gb')){Setup '' $path;Check ($null-eq(Plan)) ('TEST excluded '+$path)}
foreach($ext in @('srm','rtc')){Setup;$Saves=@(Asset ('SameBoy/Old.'+$ext));$p=Plan;Check ($p.Grade-ceq'SAFE_MERGE_DELETE'-and$p.Operations[0].Kind-ceq'Save') ($ext+' migration')}
Setup;$States=@(Asset 'SameBoy/Old.state');Check ((Plan).Grade-ceq'SAFE_MERGE_DELETE') 'state migration'
Setup;$Saves=@((Asset 'SameBoy/Old.srm'),(Asset 'SameBoy/Old.rtc'));$States=@(Asset 'SameBoy/Old.state');Check (@((Plan).Operations|Where-Object Kind -In @('Save','State')).Count-eq3) 'three asset mappings'
Setup;$Saves=@((Asset 'SameBoy/Old.srm'),(Asset 'SameBoy/New.srm'));Check ((Plan).Grade-ceq'REVIEW_ONLY') 'same SHA destination collision'
foreach($suffix in @('state1','state2','auto','autosave','state.auto')){Setup;$States=@(Asset ('SameBoy/Old.'+$suffix));Check ((Plan).Grade-ceq'REVIEW_ONLY') ('unknown slot '+$suffix)}
foreach($extra in @('<playcount>0</playcount><playtime/><lastplayed/>','<name>Local</name><playcount>1</playcount>')){Setup $extra;$p=Plan;Check ($p.Grade-ceq'SAFE_MERGE_DELETE') 'known metadata merges'}
Setup '<playcount>0</playcount><playtime/><lastplayed/>';$p=Plan;$n=@(Get-EsdeGameEntries $p.PreparedXml)[0].Node;Check ($n.playcount-ceq'0'-and$n.playtime-ceq'') 'zero empty runtime preserve'
foreach($extra in @('<custom>x</custom>','<!--keep-->','<desc><custom>x</custom></desc>')){Setup $extra;Check ((Plan).Grade-ceq'REVIEW_ONLY') 'custom metadata review'}
Setup;$Local.Document.SelectSingleNode('//game').SetAttribute('custom','x');$Local.Bytes=ConvertTo-EsdeGamelistBytes $Local;Check ((Plan).Grade-ceq'REVIEW_ONLY') 'unknown attribute review'
Setup;$Media=@(Asset 'covers/Old.png');Check ((Plan).Grade-ceq'REVIEW_ONLY') 'media review'
Setup;$Android=@($Source);Check ((Plan).Grade-ceq'REVIEW_ONLY') 'canonical absent review'
Setup;$Android[1].Sha256='c'*64;Check ((Plan).Grade-ceq'REVIEW_ONLY') 'canonical SHA mismatch'
Setup;$Managed[0].Sha256='c'*64;Check ((Plan).Grade-ceq'REVIEW_ONLY') 'managed SHA mismatch'
Setup;$Managed+=Row 'Other.gb';Check ((Plan).Grade-ceq'REVIEW_ONLY') 'multiple candidate review'
Setup;$Source.IsLink=$true;Check ((Plan).Grade-ceq'REVIEW_ONLY') 'symlink review'
Setup '' '_UNREGISTERED/../Old.gb';Reject {Plan} 'traversal blocked'
Setup;$Evidence.Core='Other';$p=Plan;Check ($p.Grade-ceq'REVIEW_ONLY'-and-not$p.CheckboxEnabled) 'unsupported core disabled'
Setup;$p=Plan;Reject {Invoke-DuplicateTransactionMock $p ([pscustomobject]@{Mode='Mock'})} 'unselected transaction blocked'
$rows=@();foreach($i in 1..5){Setup;$p=Plan;$p.Id='gb:item'+$i;$p.CanonicalRelativePath='New'+$i+'.gb';$p.Binding=Get-DuplicateProposalBinding $p;$rows+=$p}
$selection=New-DuplicateSelectionPlan $rows @('gb:item1','gb:item3');Check ($selection.Count-eq2) 'selected 2 of 5 only'
Check (@($rows|Where-Object Selected).Count-eq0) 'no auto checkbox'
$rows[0].Operations[0].Action='tampered';Reject {New-DuplicateSelectionPlan $rows @('gb:item1')} 'stale plan blocked'
Setup;$p=Plan;$script:Files=@{$p.SourceRelativePath=('a'*64);$p.CanonicalRelativePath=('a'*64)};$script:Events=@();$script:FailXml=$false
$io=[pscustomobject]@{Mode='Mock';Stat={param($path)[pscustomobject]@{Exists=$script:Files.ContainsKey($path);Kind='File';IsLink=$false;Sha256=$script:Files[$path]}};Managed={param($path)[pscustomobject]@{Exists=$true;Kind='File';IsLink=$false;Sha256=('a'*64)}};DeleteExact={param($path)$script:Events+='delete';$script:Files.Remove($path)};Validate={param($p)};Record={param($phase,$p)$script:Events+=$phase};CommitXml={param($xml)if($script:FailXml){throw 'injected XML failure'};$script:Events+='xml'}}
$selection=New-DuplicateSelectionPlan @($p) @($p.Id);Invoke-DuplicateTransactionMock $p $io $selection
Check (-not$Files.ContainsKey($p.SourceRelativePath)-and$Files[$p.CanonicalRelativePath]-ceq('a'*64)) 'exact source delete canonical unchanged mock'
Check ($Events[-1]-ceq'completed'-and[Array]::IndexOf($Events,'xml')-lt[Array]::IndexOf($Events,'delete')) 'commit before delete completed'
$Files[$p.SourceRelativePath]='a'*64;$Events=@();$FailXml=$true;Reject {Invoke-DuplicateTransactionMock $p $io $selection} 'XML failure stops transaction'
Check ($Files.ContainsKey($p.SourceRelativePath)-and$Events[-1]-ceq'recovery-needed') 'recovery retains ROM no reverse'
$worker=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'));Check (-not$worker.Contains('New-UnregisteredDuplicateProposal')-and-not$worker.Contains('Invoke-DuplicateTransactionMock')) 'normal sync no cleanup connection'
Setup '<playcount>1</playcount>';$Saves=@((Asset 'SameBoy/Old.srm'),(Asset 'SameBoy/Old.rtc'));$States=@(Asset 'SameBoy/Old.state');$p=Plan
$script:Files=@{$p.SourceRelativePath=('a'*64);$p.CanonicalRelativePath=('a'*64)};foreach($op in @($p.Operations|Where-Object Kind -In @('Save','State'))){$Files[$op.Root+'/'+$op.SourceRelativePath]=$op.ExpectedSha256}
$Events=@();$FailXml=$false;$script:FailMove=$false
$io.Stat={param($path)[pscustomobject]@{Exists=$script:Files.ContainsKey($path);Kind='File';IsLink=$false;Sha256=$script:Files[$path];Size=32;Device='dev1'}}
$io|Add-Member Parent {param($root,$path,$create)[pscustomobject]@{Safe=$true;Exists=$true;Kind='Directory';CanonicalPath=$path;Device='dev1'}}
$io|Add-Member MoveNoClobber {param($s,$d)if($script:FailMove){throw 'injected asset failure'};if($script:Files.ContainsKey($d)){throw 'collision'};$script:Files[$d]=$script:Files[$s];$script:Files.Remove($s);$script:Events+='asset'}
$selection=New-DuplicateSelectionPlan @($p) @($p.Id);Invoke-DuplicateTransactionMock $p $io $selection
Check (@($p.Operations|Where-Object {$_.Kind-cin@('Save','State')-and$Files.ContainsKey($_.Root+'/'+$_.DestinationRelativePath)-and-not$Files.ContainsKey($_.Root+'/'+$_.SourceRelativePath)}).Count-eq3) 'mock migrations all three preserve hashes'
Check ([Array]::LastIndexOf($Events,'asset')-lt[Array]::IndexOf($Events,'xml')-and$Events[-1]-ceq'completed') 'migrations before XML before delete'
$Files[$p.SourceRelativePath]='a'*64;foreach($op in @($p.Operations|Where-Object Kind -In @('Save','State'))){$Files.Remove($op.Root+'/'+$op.DestinationRelativePath);$Files[$op.Root+'/'+$op.SourceRelativePath]=$op.ExpectedSha256};$Events=@();$FailMove=$true
Reject {Invoke-DuplicateTransactionMock $p $io $selection} 'asset failure stops delete'
Check ($Files.ContainsKey($p.SourceRelativePath)-and$Events[-1]-ceq'recovery-needed') 'asset failure ROM remains recovery gate'
$view=ConvertTo-DuplicateManagerViewModel @($p);Check ($view.Rows.Count-eq1-and-not$view.Rows[0].Selected-and$view.Columns.Count-eq7) 'UI seven columns unchecked model'
Setup;$Evidence.Core='unknown';$review=Plan;$view=ConvertTo-DuplicateManagerViewModel @($review);Check (-not$view.Rows[0].CheckboxEnabled-and$view.Rows[0].Status-ceq'검토 필요') 'review disabled UI'
Setup '' '_TEST/Old.gb';$view=ConvertTo-DuplicateManagerViewModel @(Plan|Where-Object {$null-ne$_});Check ($view.Rows.Count-eq0-and$view.ConfirmedDuplicateCount-eq0) 'TEST absent UI and count'
Setup '<altemulator>Other</altemulator>';Check ((Plan).Grade-ceq'REVIEW_ONLY') 'per game core override blocks'
Setup '<playcount>1</playcount>';$Local=Xml '<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>./_UNREGISTERED/Old.gb</path><playcount>1</playcount></game></gameList>';$p=Plan
Check ($p.PreparedXml.Document.SelectSingleNode('//alternativeEmulator/label').InnerText-ceq'SameBoy') 'alternativeEmulator subtree preserved'
Setup '<playcount>1</playcount>';$Local=Xml '<gameList><game><path>./_UNREGISTERED/Old.gb</path><playcount>1</playcount></game><game><path>./New.gb</path><playcount>2</playcount></game></gameList>';Check ((Plan).Grade-ceq'REVIEW_ONLY') 'canonical local runtime conflict review'
Setup;$Local=Xml '<gameList><game><path>./_UNREGISTERED/Old.gb</path></game><game><path>./_UNREGISTERED/Old.gb</path></game></gameList>';Check ((Plan).Grade-ceq'REVIEW_ONLY') 'duplicate XML review'
Setup;$Saves=@((Asset 'SameBoy/Old.srm'),(Row 'SameBoy/New.srm' ('c'*64)));Check ((Plan).Grade-ceq'REVIEW_ONLY') 'different SHA destination review'
Setup;$p=Plan;$io.Mode='Adb';Reject {Invoke-VerifiedAndroidDuplicateDeleteMock $p $io} 'mock rejects actual adb backend'
Setup;$Local=Xml '<gameList/>';$p=Plan;Check ($p.Grade-ceq'SAFE_DELETE') 'no local node safe delete'
Check (@(Get-EsdeGameEntries $p.PreparedXml).Count-eq1) 'no synthetic local node without existing local'
Setup;$Android[1].RelativePath='new.gb';Check ((Plan).Grade-ceq'REVIEW_ONLY') 'canonical case collision review'
Setup;$Evidence.CompleteSameBoyContentInventory=$false;Check ((Plan).Grade-ceq'REVIEW_ONLY') 'incomplete content inventory review'
Setup;$Source.System='gba';$p=New-UnregisteredDuplicateProposal gba $Source 'New.gb' $Managed $Android $Local $Master $Evidence @() @() @();Check ($p.Grade-ceq'REVIEW_ONLY') 'unsupported system review'
Setup;$p=Plan;$io.Mode='Mock';$Files=@{$p.SourceRelativePath=('c'*64);$p.CanonicalRelativePath=('a'*64)};Reject {Invoke-VerifiedAndroidDuplicateDeleteMock $p $io} 'late source SHA blocks deletion'
Check ($Files.ContainsKey($p.SourceRelativePath)-and$Files[$p.CanonicalRelativePath]-ceq('a'*64)) 'late evidence failure mutation zero'
'PASS TOTAL: '+$script:Passed