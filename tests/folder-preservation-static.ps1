$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Write-Log($m){}
$script:FolderPassed=0
function FolderCheck($ok,$name){if(-not$ok){throw ('folder fixture: '+$name)};$script:FolderPassed++;'FOLDER PASS: '+$name}
function Xml($s){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($s))}
function Folder($path,$value='20261011T093913'){return '<folder><path>'+ $path+'</path><lastplayed>'+ $value+'</lastplayed></folder>'}
function Bound($master,$local){Get-AndroidBoundGamelist (Xml ('<gameList>'+$master+'</gameList>')) (Xml ('<gameList>'+$local+'</gameList>')) 'gb'}
foreach($path in @('./_UNREGISTERED','./_TEST','_UNREGISTERED','./_UNREGISTERED/')){$x=Bound '' (Folder $path);$entries=@(Get-EsdeFolderEntries $x);FolderCheck ($entries.Count-eq1-and$entries[0].Node.lastplayed-ceq'20261011T093913') ('promotion 0 reserved '+$path)}
foreach($value in @('','0','20261011T093913')){$x=Bound (Folder './Same' 'MASTER') (Folder 'Same/' $value);FolderCheck ($x.Document.SelectSingleNode('//folder/lastplayed').InnerText-ceq$value) ('runtime tag presence '+$value)}
$x=Bound '<folder><path>./Same</path><name>Master</name><desc>Base</desc></folder>' '<folder note="local"><path>Same/</path><name>Local</name><custom>keep</custom><!--local comment--><lastplayed>0</lastplayed></folder>'
$f=$x.Document.SelectSingleNode('//folder');FolderCheck ($f.name-ceq'Master'-and$f.desc-ceq'Base') 'same path master metadata base';FolderCheck ($f.custom-ceq'keep'-and$f.GetAttribute('note')-ceq'local'-and$f.SelectNodes('comment()').Count-eq1) 'same path custom fields attributes comment preserve'
$x=Bound '<folder><path>./X</path><!--repeat--></folder>' '<folder><path>./X</path><!--repeat--><!--repeat--><custom>A</custom><custom>A</custom></folder>'
FolderCheck ($x.Document.SelectSingleNode('//folder').SelectNodes('comment()').Count-eq2) 'local comment multiplicity preserved'
FolderCheck ($x.Document.SelectSingleNode('//folder').SelectNodes('custom').Count-eq2) 'local-only repeated custom elements preserved'
$whole='<folder note="x"><path>./_TEST</path><name>Local</name><custom><nested>yes</nested></custom><!--opaque--><lastplayed/></folder>';$x=Bound '' $whole;FolderCheck ($x.Document.SelectSingleNode('//folder').OuterXml-ceq(Xml ('<gameList>'+$whole+'</gameList>')).Document.SelectSingleNode('//folder').OuterXml) 'local-only folder whole-node preserve'
$x=Bound (Folder './MasterOnly') '';FolderCheck ($x.Document.SelectNodes('//folder').Count-eq1-and$x.Document.SelectSingleNode('//folder/path').InnerText-ceq'./MasterOnly') 'master-only unchanged'
$x=Merge-EsdeGamelist $null (Xml ('<gameList>'+ $whole+'</gameList>'));FolderCheck (@(Get-EsdeFolderEntries $x).Count-eq1-and@(Get-EsdeGameEntries $x).Count-eq0) 'folder-only Android survives missing master without synthetic game'
foreach($bad in @('<folder/>','<folder><path>../Escape</path></folder>','<folder><path>/root</path></folder>','<folder><path>./_TEST//</path></folder>','<folder><path>./_TEST</path><path>./Else</path></folder>','<folder><path><nested/></path></folder>',((Folder './_TEST')+(Folder '_TEST/')),((Folder './Case')+(Folder './case')))){$blocked=$false;try{[void](Bound '' $bad)}catch{$blocked=$true};FolderCheck $blocked 'invalid duplicate traversal case collision fails closed'}
$blocked=$false;try{[void](Bound ((Folder './X')+(Folder './X')) '')}catch{$blocked=$true};FolderCheck $blocked 'master duplicate blocked'
$blocked=$false;try{[void](Bound (Folder './Case') (Folder './case'))}catch{$blocked=$true};FolderCheck $blocked 'cross-input case collision blocked'
$blocked=$false;try{[void](Bound '<folder><path>./X</path><custom>A</custom></folder>' '<folder><path>./X</path><custom>B</custom></folder>')}catch{$blocked=$true};FolderCheck $blocked 'conflicting custom metadata blocked instead of dropping'
$blocked=$false;try{[void](Bound '<folder note="A"><path>./X</path></folder>' '<folder note="B"><path>./X</path></folder>')}catch{$blocked=$true};FolderCheck $blocked 'conflicting custom attributes blocked'
$blocked=$false;try{[void](Xml '<gameList><folder></gameList>')}catch{$blocked=$true};FolderCheck $blocked 'malformed XML blocked'
$a=Bound '' ((Folder './_TEST')+(Folder './_UNREGISTERED'));$b=Bound '' ((Folder './_UNREGISTERED')+(Folder './_TEST'));$canonA=@(Get-EsdeFolderEntries $a|Sort-Object Key|ForEach-Object {$_.Node.OuterXml});$canonB=@(Get-EsdeFolderEntries $b|Sort-Object Key|ForEach-Object {$_.Node.OuterXml});FolderCheck (($canonA-join'|')-ceq($canonB-join'|')) 'folder order-only semantic equality'
$master='<game><path>./Game.gb</path><name>Master</name></game>';$local='<game><path>./Game.gb</path><playcount>0</playcount></game><game><path>./_TEST/Test.gb</path><custom>local</custom></game>';$with=Bound $master ($local+(Folder './_TEST'));$without=Bound $master $local;$gamesA=@(Get-EsdeGameEntries $with|ForEach-Object {$_.Node.OuterXml});$gamesB=@(Get-EsdeGameEntries $without|ForEach-Object {$_.Node.OuterXml});FolderCheck (($gamesA-join'|')-ceq($gamesB-join'|')) 'game semantic result unchanged';FolderCheck ($gamesA.Count-eq2) 'no synthetic game'
# Real production call graph exercised with the existing PC-only ADB mock backend.
. (Join-Path $PSScriptRoot 'rename-production-static.ps1')
function AssertFolderPlan($p,$label,$value='20261011T000000'){$x=Read-EsdeGamelist $p.XmlPlan.Output;$f=@(Get-EsdeFolderEntries $x|Where-Object Key -CEQ './_UNREGISTERED');FolderCheck ($f.Count-eq1-and$f[0].Node.lastplayed-ceq$value) $label}
RenameSetup '_UNREGISTERED/OldName.gb' 'Elsewhere/New Name.gb';$p=Prepare;FolderCheck ($p.Promotions.Count-eq0-and$p.ReviewRequired) 'REVIEW without promotion';AssertFolderPlan $p 'REVIEW generic folder preserve'
RenameSetup '_UNREGISTERED/Same.gb' 'Same.gb';$p=Prepare;FolderCheck ($p.Promotions.Count-eq1-and$p.Promotions[0].Action-ceq'PROMOTE_TO_MANAGED') 'SAME_NAME proposal unchanged';AssertFolderPlan $p 'SAME_NAME generic folder preserve'
RenameSetup;$p=Prepare;FolderCheck ($p.Promotions.Count-eq1-and$p.Promotions[0].Action-ceq'PROMOTE_WITH_RENAME') 'RENAME proposal unchanged';AssertFolderPlan $p 'RENAME generic folder preserve'
RenameSetup '_UNREGISTERED/ExistingReview.gb' 'Elsewhere/New Name.gb';Put '/storage/emulated/0/ROMs/gb/Extra.gb' 'UNMANAGED';$xml=ConvertFrom-EsdeGamelistBytes $Remote[$XmlRemote];$xml.Document.SelectSingleNode('//folder/lastplayed').InnerText='20261011T093913';$script:Remote[$XmlRemote]=ConvertTo-EsdeGamelistBytes $xml;$script:XmlPlan.Local=ConvertFrom-EsdeGamelistBytes $Remote[$XmlRemote];[IO.File]::WriteAllBytes($XmlPlan.Pulled,$Remote[$XmlRemote]);$p=Prepare
FolderCheck ($p.Promotions.Count-eq0-and$p.Moves.Count-eq1-and@($p.Inventory|Where-Object Action -CEQ PRESERVE_AND_REVIEW).Count-eq1) 'blocked production scenario: rename 0 same-name 0 unmanaged 1 review 1'
AssertFolderPlan $p 'blocker reproduced and fixed: folder 1 to 1 timestamp preserved' '20261011T093913'
FolderCheck (@(Get-EsdeGameEntries (Read-EsdeGamelist $p.XmlPlan.Output)).Count-eq@(Get-EsdeGameEntries $p.XmlPlan.Local).Count) 'unmanaged/review no synthetic game'
'FOLDER PRESERVATION PASS: '+$script:FolderPassed