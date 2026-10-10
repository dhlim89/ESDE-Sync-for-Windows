$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'same-name-promotion-static.ps1')
$script:passed=0
function Xml($s){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($s))}
function Setup([string]$extras=''){
 $script:Local=Xml ('<alternativeEmulator><label>Android</label></alternativeEmulator><gameList><game><path>./_UNREGISTERED/Hacks/Game.gb</path><name>Local</name><playcount>3</playcount><playtime/><lastplayed/>'+ $extras+'</game></gameList>')
 $script:Master=Xml '<gameList><game><path>./Hacks/Game.gb</path><name>Managed Name</name><playcount>99</playcount></game></gameList>'
 $script:Safety=Get-PromotionMetadataSafety $Local $Master './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb'
 $entry=@(New-UnregisteredClassificationPlan gb @(Row 'Hacks/Game.gb') @(Row '_UNREGISTERED/Hacks/Game.gb') @() @('gb'))[0]
 $script:Plan=New-SameNamePromotionProposal $entry @(Row '_UNREGISTERED/Hacks/Game.gb') @('./_UNREGISTERED/Hacks/Game.gb') @('./Hacks/Game.gb') $evidence
 $script:Files=@{
 '/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb'=('a'*64)
 '/save/Game.srm'='SAVE';'/save/Game.rtc'='RTC';'/state/Game.state'='STATE';'/media/Game.png'='MEDIA'
 }
 $script:Events=New-Object 'Collections.Generic.List[string]';$script:Records=@();$script:ParentSafe=$true;$script:LateRevision=$false;$script:FailMove=$false;$script:BadDest=$false;$script:FailXml=$false;$script:XmlRace=$false;$script:Fingerprint='before';$script:Committed=$false;$script:ParentCreated=$false
 $script:IO=[pscustomobject]@{Mode='Mock';Stat={param($p) [pscustomobject]@{Exists=$script:Files.ContainsKey($p);Kind='File';IsLink=$false;Sha256=$script:Files[$p];Device='dev1'}};Parent={param($root,$p,$create) if(-not$p.StartsWith($root+'/',[StringComparison]::Ordinal)-and$p-cne$root){throw 'outside root'};if($create){$script:ParentCreated=$true;if($script:LateRevision){$script:Files['/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb']='b'*64}};[pscustomobject]@{Safe=$script:ParentSafe;Device='dev1';Kind='Directory';CanonicalPath=$p;Exists=($p.Contains('_UNREGISTERED')-or$script:ParentCreated)}};MoveNoClobber={param($s,$d) if($script:FailMove){throw 'mock move failed'};if($script:Files.ContainsKey($d)){throw 'no clobber'};$script:Files[$d]=$script:Files[$s];$script:Files.Remove($s);if($script:BadDest){$script:Files[$d]='b'*64};if($script:XmlRace){$script:Fingerprint='changed'}};Record={param($state,$move)$script:Events.Add($state);$script:Records+=($move|ConvertTo-Json -Compress)};ValidateXml={param($x)if(-not$x){throw 'missing staging'};[void](ConvertFrom-EsdeGamelistBytes $x.Bytes)};GamelistFingerprint={$script:Fingerprint};CommitXml={param($xml,$expected)if($script:FailXml-or$script:Fingerprint-cne$expected){throw 'XML commit failed'};$script:Committed=$true}}
}
function Execute { $bound=Get-PromotionBoundGamelist $Local $Master gb './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb';Invoke-SameNamePromotionMock $Plan $Safety $IO $bound 'before' }
function Block([scriptblock]$body,$name){$hit=$false;try{& $body|Out-Null}catch{$hit=$true};Check $hit $name}
Setup
Check $Safety.Safe 'known metadata SAFE-MERGEABLE'
$out=Execute
Check ($out.Completed-and$Files.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/Game.gb')-and-not$Files.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb')) 'mock internal ROM move verified'
Check ($Files['/save/Game.srm']-ceq'SAVE'-and$Files['/save/Game.rtc']-ceq'RTC'-and$Files['/state/Game.state']-ceq'STATE') 'save/rtc/state bytes and paths unchanged'
Check ($Files['/media/Game.png']-ceq'MEDIA') 'media untouched'
Check ($Events-join',' -ceq'prepared,moving,rom-verified,completed') 'transaction ordering/state'
Check ($ParentCreated-and$Committed) 'parent creation and XML commit'
Check (@($Records|Where-Object {$_-notmatch'"MediaAction":"HOLD"'}).Count-eq0) 'transaction media HOLD evidence'
Check ($Records[0]-match'InitialSourceSha256'-and$Records[0]-match'DestinationExpectedAbsent') 'transaction minimum evidence'
# Existing managed send helper detects destination SHA without calling USB push.
$script:UsbPush=0
function Read-ClassificationRom($p,$s){if($script:Files.ContainsKey($p)){[pscustomobject]@{Sha256=$script:Files[$p]}}}
function Get-FileHash {param($LiteralPath)[pscustomobject]@{Hash=('a'*64)}}
$r=Send-ClassifiedManagedFile ([pscustomobject]@{FullName='mock';Sha256=('a'*64)}) '/storage/emulated/0/ROMs/gb/Hacks/Game.gb' 'mock' {$script:UsbPush++}
Check ($r.Code-eq0-and$UsbPush-eq0) 'post-promotion canonical managed duplicate push zero'
Remove-Item Function:Get-FileHash
foreach($extra in @('<unknown>x</unknown>','<favorite>true</favorite>','<!--local comment-->','<desc custom="x">text</desc>')){
 Setup $extra;Check (-not$Safety.Safe-and$Safety.Category-ceq'LOCAL-EXTRA-METADATA') ('extra metadata REVIEW '+$extra);Block {Execute} 'unsafe metadata no executor'
}
Setup;$Local.Document.SelectSingleNode('//game').SetAttribute('custom','x');$Local.Bytes=ConvertTo-EsdeGamelistBytes $Local
$s=Get-PromotionMetadataSafety $Local $Master './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb';Check (-not$s.Safe-and$s.UnsupportedAttributes.Count-eq1) 'custom game attribute REVIEW'
Setup;$Local=Xml '<gameList/>'; $Safety=Get-PromotionMetadataSafety $Local $Master './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb';$bound=Get-PromotionBoundGamelist $Local $Master gb './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb';Check ($Safety.Safe-and@(Get-EsdeGameEntries $bound).Count-eq1) 'absent local node normal canonical master only'
Setup;$ParentSafe=$false;Block {Execute} 'symlink/unsafe parent blocks';Check (-not$ParentCreated-and$Files.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb')) 'unsafe parent zero move'
Setup;$LateRevision=$true;Block {Execute} 'late source revision blocks';Check (-not$Committed-and$Files.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb')) 'late revision XML unchanged'
foreach($failure in @('FailMove','BadDest','FailXml','XmlRace')){
 Setup;Set-Variable -Scope Script -Name $failure -Value $true;Block {Execute} ($failure+' stops');Check ($Events[-1]-ceq'recovery-needed') ($failure+' state retained');Check (-not$Committed) ($failure+' no successful XML commit')
}
Setup;$FailXml=$true;Block {Execute} 'ROM success/XML failure';Check ($Files.ContainsKey('/storage/emulated/0/ROMs/gb/Hacks/Game.gb')-and-not$Files.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb')) 'no automatic reverse move';Check $ParentCreated 'created parent retained no cleanup'
Setup;$IO.Mode='Actual';Block {Execute} 'real adapter prohibited'
Block {Xml '<gameList>'} 'malformed XML preflight blocked'
Setup;$Local=Xml '<gameList><game><path>./Hacks/Game.gb</path></game><game><path>./_UNREGISTERED/Hacks/Game.gb</path></game></gameList>'; $s=Get-PromotionMetadataSafety $Local $Master './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb';Check $s.Collision 'canonical game collision'
Setup;$Local=Xml '<gameList><game><path>./_UNREGISTERED/Hacks/Game.gb</path><playcount>1</playcount><playcount>2</playcount></game></gameList>'; $s=Get-PromotionMetadataSafety $Local $Master './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb';Check $s.Collision 'duplicate runtime tags block'
Setup;$entry=@(New-UnregisteredClassificationPlan gb @(Row 'Hacks/Game.gb') @(Row '_UNREGISTERED/Hacks/Game.gb') @() @('gb'))[0]
Check ($entry.Action-ceq'PRESERVE_AND_REVIEW') 'production classifier remains REVIEW'
$entry.Action='PROMOTE_TO_MANAGED';$sum=Get-PromotionSummaryProposal @($entry,(New-UnregisteredClassificationPlan gb @() @(Row '_UNREGISTERED/Other.gb') @() @('gb'))[0]) 1
Check ($sum.LocalOnlyCount-eq2-and$sum.PromotedCount-eq1-and$sum.UnmanagedMoveCount-eq0-and$sum.ReviewCount-eq0) 'start local2 completed promotion1 independent axes'
$legacy=Get-RomReviewSummary @($entry);Check ($legacy.PromotedCount-eq0) 'production summary defaults promotion0'
$source=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'))
Check (([regex]::Matches($source,'Invoke-SameNamePromotionMock')).Count-eq1) 'mock executor has no production caller'
Setup
$IO.Parent={param($root,$p,$create)[pscustomobject]@{Safe=$true;Device='dev1';Kind='Directory';CanonicalPath='/outside';Exists=$true}}
Block {Execute} 'parent canonical redirect blocks'
Setup
$move=[pscustomobject]@{System='gb';SourceRelativePath='Hacks/Game.gb';DestinationRelativePath='_UNREGISTERED/Hacks/Game.gb';ExpectedSha256=('a'*64);InitialSourceSha256=('a'*64);DestinationExpectedAbsent=$true}
$Files.Remove('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb');$Files['/storage/emulated/0/ROMs/gb/Hacks/Game.gb']='a'*64
$ParentCreated=$true
$r=Invoke-VerifiedAndroidRomMoveMock $move $IO
Check ($r.Completed-and$Files.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb')) 'common primitive supports caller-selected opposite direction'
Setup;$move.SourceRelativePath='../Game.gb';Block {Invoke-VerifiedAndroidRomMoveMock $move $IO} 'traversal primitive blocked'
Setup;$move.SourceRelativePath='/Game.gb';Block {Invoke-VerifiedAndroidRomMoveMock $move $IO} 'absolute primitive blocked'
Setup;$IO.Parent={param($root,$p,$create)[pscustomobject]@{Safe=$true;Device='different';Kind='Directory';CanonicalPath=$p;Exists=$true}};Block {Execute} 'filesystem mismatch blocks'
Setup;$bound=Get-PromotionBoundGamelist $Local $Master gb './_UNREGISTERED/Hacks/Game.gb' './Hacks/Game.gb';$g=@(Get-EsdeGameEntries $bound)[0]
Check ($g.Key-ceq'./Hacks/Game.gb'-and$g.Node.name-ceq'Managed Name'-and$g.Node.playcount-ceq'3') 'nested canonical metadata/runtime'
Check (@(Get-EsdeGameEntries $bound).Count-eq1) 'nested canonical duplicate node zero'
Setup;$IO.ValidateXml={param($x)throw 'malformed prepared XML'};Block {Execute} 'bad staging blocked before move';Check ($Events.Count-eq0-and$Files.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/Hacks/Game.gb')) 'bad staging mutation zero'
'v1.6 metadata/move mock 검증 완료: '+$passed