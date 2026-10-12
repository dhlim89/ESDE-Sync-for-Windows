$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
$script:Passed=0;function Check($ok,$name){if(-not$ok){throw $name};$script:Passed++;'PASS: '+$name}
$script:Calls=0
$rows=@();foreach($grade in @('SAFE_DELETE','SAFE_MERGE_DELETE','REVIEW_ONLY')){$rows+=[pscustomobject]@{Id=$grade;System='gb';SourceRelativePath=('_UNREGISTERED/'+$grade+'.gb');CanonicalRelativePath=($grade+'.gb');Grade=$grade;CheckboxEnabled=($grade-cne'REVIEW_ONLY');Reason='metadata evidence';Sha256=('a'*64);AssetMoves=@([pscustomobject]@{SourceRelativePath='SameBoy/Old.srm';DestinationRelativePath='SameBoy/New.srm'});MetadataMerge=($grade-ceq'SAFE_MERGE_DELETE')}}
$rows+=[pscustomobject]@{Id='TEST';System='gb';SourceRelativePath='_UNREGISTERED/_TEST/Test.gb';CanonicalRelativePath='Test.gb';Grade='SAFE_DELETE';CheckboxEnabled=$true}
$scan=[pscustomobject]@{rows=$rows}
$ui=New-DuplicateManagerDialog $scan {param($ids)$script:Calls++;$script:Ids=$ids} {param($text)$false}
try{
 Check ($ui.Grid.Columns.Count-eq7) 'seven columns'
 Check ($ui.Grid.Rows.Count-eq3) 'TEST excluded row entirely'
 Check (@($ui.Grid.Rows|Where-Object {[bool]$_.Cells[0].Value}).Count-eq0) 'default all unchecked'
 Check (-not$ui.Grid.Rows[0].Cells[0].ReadOnly) 'SAFE_DELETE checkbox enabled'
 Check (-not$ui.Grid.Rows[1].Cells[0].ReadOnly) 'SAFE_MERGE_DELETE checkbox enabled'
 Check ($ui.Grid.Rows[2].Cells[0].ReadOnly) 'REVIEW checkbox disabled'
 Check (-not$ui.Execute.Enabled) 'zero selected execute disabled'
 Set-DuplicateUiSelection $ui $true
 Check (@($ui.Grid.Rows|Where-Object {[bool]$_.Cells[0].Value}).Count-eq2) 'select all safe rows only'
 Check (-not[bool]$ui.Grid.Rows[2].Cells[0].Value) 'review never checked by select all'
 Check ($ui.Count.Text-ceq'선택: 2개'-and$ui.Execute.Enabled) 'selected count enable execute'
 Invoke-DuplicateUiSelection $ui
 Check ($script:Calls-eq0-and-not$ui.Busy) 'cancel confirmation no mutation'
 Check ((Get-DuplicateConfirmation 2).Contains('2개')-and(Get-DuplicateConfirmation 2).Contains('_TEST는 변경되지 않습니다.')) 'confirmation contract'
 Set-DuplicateUiSelection $ui $false
 Check (@($ui.Grid.Rows|Where-Object {[bool]$_.Cells[0].Value}).Count-eq0-and-not$ui.Execute.Enabled) 'clear all'
 $ui.Grid.Rows[1].Cells[0].Value=$true;Update-DuplicateUiSelection $ui;$ui.Confirm={param($text)$true};Invoke-DuplicateUiSelection $ui
 Check ($Calls-eq1-and$Ids.Count-eq1-and$Ids[0]-ceq'SAFE_MERGE_DELETE') 'explicit checked subset only'
 Check ($ui.Busy-and-not$ui.Execute.Enabled-and-not$ui.Grid.Enabled) 'busy prevents repeated execute'
 Invoke-DuplicateUiSelection $ui;Check ($Calls-eq1) 'double click does not start twice'
 $ui.Busy=$false;$ui.Grid.Enabled=$true
 $ui.Grid.ClearSelection();$ui.Grid.Rows[1].Selected=$true
 Check ($ui.Detail.Text.Contains('SHA-256:')-and$ui.Detail.Text.Contains('Old.srm')) 'friendly detail SHA migrations'
 $ui.Grid.ClearSelection();$ui.Grid.Rows[2].Selected=$true
 Check ($ui.Detail.Text.Contains('처리하지 않음 / 검토 필요')) 'REVIEW detail never promises safe cleanup'
 $ui.Dialog.Close();Check ($Calls-eq1) 'close no extra operation'
}finally{$ui.Dialog.Dispose()}
$r=[pscustomobject]@{SafeDelete=2;SafeMergeDelete=1;Review=1;Failed=0;Unprocessed=3};$dialog=New-DuplicateResultDialog $r
try{
 Check ($dialog.Tag.Text.Text.Contains('정리 완료: 2')-and$dialog.Tag.Text.Text.Contains('미처리: 3')) 'result partial count summary'
 Check ($dialog.Tag.Copy.Text-ceq'결과 복사') 'result copy button'
 Check ($dialog.Tag.Text.Text-ceq(Format-DuplicateResult $r)) 'copy payload exact displayed summary'
}finally{$dialog.Dispose()}
$source=[IO.File]::ReadAllText((Join-Path $repo 'ESDE-Sync.ps1'))
Check ($source.Contains('[Windows.Forms.Clipboard]::SetText($text.Text)')) 'copy handler binds displayed text'
Check ($source.Contains('-Operation')-and$source.Contains('DuplicateScan')-and$source.Contains('DuplicateCleanup')) 'GUI separate worker operation entry'
Check ($source.Contains('DuplicateUnregisteredCount')-and$source.Contains('관리 ROM과 중복된 미등록 ROM')) 'sync informational notice independent summary'
Check (-not$source.Contains('RenameCount')) 'no change official sync counts'
'PASS TOTAL: '+$script:Passed