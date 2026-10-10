$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$ReservedFolders=@('_TEST','_UNREGISTERED');$passed=0
function Check($b,$s){if(-not$b){throw $s};$script:passed++;'PASS: '+$s}
function Row($p,$sha=('a'*64)){[pscustomobject]@{RelativePath=$p;Sha256=$sha}}
$evidence=[pscustomobject]@{Verified=$true;System='gb';PathIndependentSaveState=$true;NoMediaRelocationRequired=$true;LocalMetadataResolved=$true;SafeDestinationParent=$true;Reference='MOCK ONLY - not actual emulator evidence'}
function Proposal($path,$canonical,$extra=@(),$games=@(),$master=@(),$proof=$evidence){
 $android=@(Row $path)+@($extra)
 $entry=@(New-UnregisteredClassificationPlan gb @(Row $canonical) $android @() @('gb'))[0]
 New-SameNamePromotionProposal $entry $android $games $master $proof
}
$p=Proposal '_UNREGISTERED/Game.gb' 'Game.gb'
Check ($p.SafePromotionEligible-and$p.Action-ceq'PROMOTE_TO_MANAGED') 'same path/hash verified mock eligible'
Check ($p.Operations.Count-eq2-and$p.MediaAction-ceq'ReviewSystem'-and$p.SaveStateAction-ceq'Preserve') 'ROM/XML only proposal media hold/save preserve'
$p=Proposal '_UNREGISTERED/Hacks/Game.gb' 'Hacks/Game.gb'
Check $p.SafePromotionEligible 'nested same relative path'
foreach($case in @(@('_UNREGISTERED/Hacks/Game.gb','Game.gb'),@('_UNREGISTERED/Old.gb','New.gb'),@('_TEST/Game.gb','Game.gb'),@('_unregistered/Game.gb','Game.gb'))){$p=Proposal $case[0] $case[1];Check (-not$p.SafePromotionEligible-and$p.Operations.Count-eq0) ($case[0]+' REVIEW')}
foreach($sha in @(('a'*64),('b'*64))){$p=Proposal '_UNREGISTERED/Game.gb' 'Game.gb' @(Row 'Game.gb' $sha);Check (-not$p.SafePromotionEligible-and$p.Operations.Count-eq0) 'existing canonical not cleaned/overwritten'}
$p=Proposal '_UNREGISTERED/Game.gb' 'Game.gb' @(Row 'game.gb');Check (-not$p.SafePromotionEligible) 'case collision review'
$p=Proposal '_UNREGISTERED/Game.gb' 'Game.gb' @() @('./Game.gb');Check (-not$p.SafePromotionEligible) 'canonical game collision review'
$p=Proposal '_UNREGISTERED/Game.gb' 'Game.gb' @() @('./_UNREGISTERED/Game.gb') @();Check (-not$p.SafePromotionEligible) 'runtime merge destination required'
$p=Proposal '_UNREGISTERED/Game.gb' 'Game.gb' @() @('./_UNREGISTERED/Game.gb') @('./Game.gb');Check $p.SafePromotionEligible 'single existing node promotion proposal'
$p=Proposal '_UNREGISTERED/Game.gb' 'Game.gb' @() @() @() $null;Check (-not$p.SafePromotionEligible) 'actual UNKNOWN mapping blocks promotion'
$entry=@(New-UnregisteredClassificationPlan gb @(Row 'Game.gb') @(Row '_UNREGISTERED/Game.gb') @() @('gb'))[0]
$p=New-SameNamePromotionProposal $entry @(Row '_UNREGISTERED/Game.gb' ('b'*64)) @() @() $evidence;Check (-not$p.SafePromotionEligible) 'source evidence changed blocks'
$entry=@(New-UnregisteredClassificationPlan gb @(Row 'Game.gb';Row 'Copy.gb') @(Row '_UNREGISTERED/Game.gb') @() @('gb'))[0]
$p=New-SameNamePromotionProposal $entry @(Row '_UNREGISTERED/Game.gb') @() @() $evidence;Check ($p.Classification-ceq'AMBIGUOUS'-and$p.Action-ceq'REVIEW'-and$p.Operations.Count-eq0) 'ambiguous remains review'
$local=ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<alternativeEmulator a="keep"><child/><!--keep--></alternativeEmulator><gameList><game><path>./_UNREGISTERED/Game.gb</path><name>Android</name><playcount>0</playcount><playtime/><lastplayed/></game></gameList>'))
$master=ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<gameList><game><path>./Game.gb</path><name>Master</name><playcount>9</playcount><playtime>8</playtime><lastplayed>old</lastplayed></game></gameList>'))
# In-memory preview uses existing merger, not a new XML merger or runtime executor.
$before=[Convert]::ToBase64String($local.Bytes)
$preview=ConvertFrom-EsdeGamelistBytes $local.Bytes
(Get-EsdeGameEntries $preview)[0].Node.SelectSingleNode('path').InnerText='./Game.gb'
$preview.Bytes=ConvertTo-EsdeGamelistBytes $preview
$bound=Get-AndroidBoundGamelist $master $preview 'gb'
$games=@(Get-EsdeGameEntries $bound)
Check ($games.Count-eq1-and$games[0].Key-ceq'./Game.gb') 'canonical XML one node'
Check ($games[0].Node.name-ceq'Master') 'managed metadata base'
Check ($games[0].Node.SelectSingleNode('playcount').InnerText-ceq'0') 'runtime zero preserved'
Check ($games[0].Node.SelectSingleNode('playtime').InnerText-ceq''-and$games[0].Node.SelectSingleNode('lastplayed').InnerText-ceq'') 'runtime empty preserved'
Check ($bound.Document.DocumentElement.SelectSingleNode('alternativeEmulator').OuterXml-ceq$local.Document.DocumentElement.SelectSingleNode('alternativeEmulator').OuterXml) 'alternative subtree preserved'
Check ([Convert]::ToBase64String($local.Bytes)-ceq$before) 'original XML unchanged'
Check (@($games|Where-Object {$_.Key-like'*_UNREGISTERED*'}).Count-eq0) 'synthetic local node zero'
$empty=ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<gameList/>'))
$bound=Get-AndroidBoundGamelist $master $empty 'gb'
Check (@(Get-EsdeGameEntries $bound).Count-eq1) 'no local node keeps normal master policy'
$sourceText=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'))
Check (([regex]::Matches($sourceText,'New-SameNamePromotionProposal')).Count-eq2) 'proposal connected only to validated prepare'
$body=($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'New-SameNamePromotionProposal'},$false))[0].Extent.Text
Check ($body-notmatch'Invoke-Adb|Write-MediaJson|File\]::|Ensure-RemoteDir') 'proposal no I/O/save/state/media/Dropbox writes'
'v1.6 same-name promotion proposal 검증 완료: '+$passed