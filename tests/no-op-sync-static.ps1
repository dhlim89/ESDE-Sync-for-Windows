$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$root=Join-Path $env:TEMP ('esde-noop-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$passed=0;function Check($ok,$name){if(-not$ok){throw $name};$script:passed++;Write-Host ('PASS: '+$name)}
function XmlFile($name,$xml){$p=Join-Path $root $name;[IO.File]::WriteAllText($p,$xml,(New-Object Text.UTF8Encoding($true)));return $p}
$base=XmlFile 'base.xml' '<gameList><game><path>./한글 (a).gb</path><name>name</name><playcount>0</playcount><playtime /></game><folder><path>./_UNREGISTERED</path><lastplayed>20261012T135604</lastplayed></folder></gameList>'
$equal=XmlFile 'equal.xml' "<gameList>`n<folder><path>./_UNREGISTERED</path><lastplayed>20261012T135604</lastplayed></folder><game><name>name</name><playtime></playtime><playcount>0</playcount><path>./한글 (a).gb</path></game></gameList>"
Check (Test-GamelistSemanticEqual $base $equal) 'order formatting empty zero Unicode equal'
foreach($pair in @(@('0','1'),@('name</name>','changed</name>'),@('<playtime />',''),@('20261012T135604','20261012T135605'),@('<game>','<game custom="x">'),@('<game>','<!--meaningful--><game>'),@('<playtime />','<custom><nested>1</nested></custom>'))){$changed=XmlFile 'change.xml' ([IO.File]::ReadAllText($base).Replace($pair[0],$pair[1]));Check (-not(Test-GamelistSemanticEqual $base $changed)) ('semantic change retained '+$pair[0])}
function Assert-RemotePath($p){}
function Write-Log($m){}
function Assert-GamelistSnapshot($p){$script:snapshots++;if($script:stale){throw 'stale snapshot'}}
function Invoke-Adb {throw 'unexpected Android mutation'}
function Ensure-RemoteDir($p){throw 'unexpected mkdir'}
$script:snapshots=0;$script:stale=$false
$plan=[pscustomobject]@{System='gb';RemotePath='/storage/emulated/0/ES-DE/gamelists/gb';RemoteFile='/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml';Validated=$true;Present=$true;Pulled=$base;Output=$equal}
Sync-GamelistSystem $plan;Check ($script:snapshots-eq1) 'semantic no-op performs snapshot revalidation and zero transfer'
$script:stale=$true;$blocked=$false;try{Sync-GamelistSystem $plan}catch{$blocked=$_.Exception.Message-ceq'stale snapshot'};Check $blocked 'no-op stale snapshot blocks'
$script:stale=$false
$script:readModes=@();$script:pushes=0
function Get-PerfFileHash {return @{Hash='a'*64}}
function Read-ClassificationRom([string]$Path,[string]$Session,[switch]$PlanningOnly){$script:readModes+=([bool]$PlanningOnly);return @{Sha256='a'*64}}
$r=Send-ClassifiedManagedFile @{FullName='source';Sha256='a'*64} '/storage/emulated/0/ROMs/gb/Game.gb' $root {throw 'unexpected push'}
Check ($r.Code-eq0-and$script:readModes.Count-eq1-and$script:readModes[0]) 'unchanged ROM fresh native SHA without binary pull'
$script:readModes=@()
function Ensure-RemoteDir($p){}
function Read-ClassificationRom([string]$Path,[string]$Session,[switch]$PlanningOnly){$script:readModes+=([bool]$PlanningOnly);if($script:readModes.Count-eq1){return $null};return @{Sha256='a'*64}}
$r=Send-ClassifiedManagedFile @{FullName='source';Sha256='a'*64} '/storage/emulated/0/ROMs/gb/Game.gb' $root {return @{Code=0}}
Check ($script:readModes.Count-eq2-and$script:readModes[0]-and-not$script:readModes[1]) 'post-push binary verification preserved'
function Read-ClassificationRom([string]$Path,[string]$Session,[switch]$PlanningOnly){return @{Sha256='b'*64}}
$blocked=$false;try{Send-ClassifiedManagedFile @{FullName='source';Sha256='a'*64} '/storage/emulated/0/ROMs/gb/Game.gb' $root {throw 'unexpected overwrite'}}catch{$blocked=$_.Exception.Message-match'MANAGED_CONFLICT'}
Check $blocked 'late canonical SHA conflict blocks overwrite'
$gui=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Start-GuiOperationProfile','Complete-GuiOperationProfile')){$f=$gui.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$false);. ([scriptblock]::Create($f.Extent.Text))}
$StateDir=$root;Start-GuiOperationProfile 'Sync';Complete-GuiOperationProfile
$record=Get-Content (Join-Path $root 'gui-performance-Sync.json') -Raw -Encoding UTF8|ConvertFrom-Json
Check ($record.operation-ceq'Sync'-and$record.elapsedMs-ge0-and$record.clickedAtUtc-and$record.completedAtUtc) 'GUI click to completion wall clock contract'
$f=$gui.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Read-FinalSyncStatus'},$false);. ([scriptblock]::Create($f.Extent.Text))
$statusPath=Join-Path $root '완료 상태.json'
@{state='done';percent=100;current=6;total=6;summary=@{ManagedCount=99;UnmanagedMoveCount=0;PromotedCount=0;LocalOnlyCount=5;ReviewCount=1}}|ConvertTo-Json -Depth 8|Set-Content $statusPath -Encoding UTF8
$cached=@{state='restarting';percent=100;summary=$null}
$final=Read-FinalSyncStatus $statusPath
Check ($cached.summary-eq$null-and$final.summary.ManagedCount-eq99) 'stale restarting timer frame replaced by authoritative final summary'
$raw=[IO.File]::ReadAllText((Join-Path $repo 'ESDE-Sync.ps1'))
$exitIndex=$raw.IndexOf('if ($script:WorkerProcess.HasExited)')
Check ($raw.IndexOf('$st=Read-FinalSyncStatus $StatusFile',$exitIndex)-gt$exitIndex) 'actual GUI callback rereads status after worker exit'
@{state='restarting';percent=100;current=1;total=1}|ConvertTo-Json|Set-Content $statusPath -Encoding UTF8
$blocked=$false;try{Read-FinalSyncStatus $statusPath}catch{$blocked=$true};Check $blocked 'nonterminal final status fails closed'
Set-Content $statusPath '{ malformed' -Encoding UTF8
$blocked=$false;try{Read-FinalSyncStatus $statusPath}catch{$blocked=$true};Check $blocked 'malformed final status fails closed'
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()
$f=$gui.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Reset-DuplicateProgress'},$false);. ([scriptblock]::Create($f.Extent.Text))
$bar=New-Object Windows.Forms.ProgressBar
try{
    $bar.Value=100;Reset-DuplicateProgress $bar;$bar.CreateControl()
    Check ($bar.Visible-and$bar.Value-eq0-and$bar.Style-eq[Windows.Forms.ProgressBarStyle]::Marquee-and$bar.MarqueeAnimationSpeed-gt0) 'duplicate scan resets completed bar to visible marquee'
    Check ([Windows.Forms.Application]::RenderWithVisualStyles) 'marquee visual styles enabled in actual Forms fixture'
}finally{$bar.Dispose()}
Check ($raw.IndexOf('Application]::EnableVisualStyles()')-lt$raw.IndexOf('$form = New-Object System.Windows.Forms.Form')) 'actual GUI enables visual styles before first form'
Write-Host ('no-op fixture '+$passed+' PASS')