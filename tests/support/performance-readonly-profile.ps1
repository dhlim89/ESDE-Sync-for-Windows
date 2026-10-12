param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Adb,[Parameter(Mandatory=$true)][string]$Device,[Parameter(Mandatory=$true)][string]$Evidence,[Parameter(Mandatory=$true)][string]$TrialState)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'update-common.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$realAdb=(Get-Item Function:Invoke-Adb).ScriptBlock
function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
    # Read-only transport: neither normal sync nor cleanup entry point is invoked.
    if($Args-ccontains'push'-or$Args-ccontains'install'-or$Args-ccontains'kill-server'){throw 'PROFILE BLOCK: mutation transport'}
    $cmd=$Args -join ' '
    if($Args-ccontains'shell'-and$cmd-match'\b(rm|mv|cp|mkdir|am|touch|chmod|settings)\b|\bshell input\b|(?<!>)>(?!/dev/null)'){throw 'PROFILE BLOCK: write shell'}
    & $realAdb @Args
}
$AdbPath=$Adb;$Serial=$Device;$SourceRoot=$Source;$selectedSystems=@('gb','gbc');$ReservedFolders=@('_TEST','_UNREGISTERED')
$Buckets=@(@{Remote='/storage/emulated/0/ROMs'},@{Remote='/storage/emulated/0/ES-DE/gamelists'},@{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$AppVersion=Get-AppVersion (Join-Path $repo 'version.json');$Operation='Sync';$StateDir=$Evidence
[void][IO.Directory]::CreateDirectory($Evidence);$StatusFile=Join-Path $Evidence 'status.json';$LogFile=Join-Path $Evidence 'profile.log'
Assert-DuplicateRecoveryGate $TrialState
Initialize-Perf 'unchanged-readonly-normal-preflight'
$git=@(Get-ChildItem $env:TEMP -Directory -Filter 'esde-baseline-git-*'|ForEach-Object {Join-Path $_.FullName 'git/cmd/git.exe'}|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
$checkpoint=& $git -C $repo rev-parse HEAD
$implementation=(Get-FileHash -LiteralPath (Join-Path $repo 'sync-worker.ps1')).Hash.ToLowerInvariant()
$script:Perf.gitCheckpoint=$checkpoint;$script:Perf.implementationSha256=$implementation
$mediaContext=$null
try {
    foreach($i in 1..2){$e=Get-AndroidForegroundEvidence;$d=Evaluate-AndroidForegroundSafety $e;@{Evidence=$e;Decision=$d}|ConvertTo-Json -Depth 30|Set-Content (Join-Path $Evidence ('safe-'+$i+'.json')) -Encoding UTF8;if(-not$d.allowed){throw ('PROFILE BLOCK: '+$d.reason)}}
    $jobs=@();foreach($sys in $selectedSystems){foreach($bucket in @(@{Name='ROM';Local='roms';Remote='/storage/emulated/0/ROMs'},@{Name='gamelist';Local='gamelists';Remote='/storage/emulated/0/ES-DE/gamelists'},@{Name='media';Local='downloaded_media';Remote='/storage/emulated/0/ES-DE/downloaded_media'})){$jobs+=[pscustomobject]@{System=$sys;Bucket=$bucket;LocalPath=(Join-Path $Source ($bucket.Local+'/'+$sys));RemotePath=($bucket.Remote+'/'+$sys)}}}
    $mediaContext=New-MediaContext $Evidence $Source $Device
    $mediaJobs=@($jobs|Where-Object {$_.Bucket.Local-ceq'downloaded_media'})
    $mediaSources=@(Get-MediaSourceFiles $mediaJobs $mediaContext)
    $script:Perf.overall=20
    $plans=@();foreach($sys in $selectedSystems){$rom=@($jobs|Where-Object {$_.System-ceq$sys-and$_.Bucket.Local-ceq'roms'})[0];$xml=@($jobs|Where-Object {$_.System-ceq$sys-and$_.Bucket.Local-ceq'gamelists'})[0];$xml|Add-Member GamelistSource (Get-GamelistSource $xml.LocalPath);$plans+=@(Prepare-RomSystemSync $rom $xml $Evidence).ClassificationPlan}
    $script:Perf.overall=50
    $held=@($plans|Where-Object ProtectMedia|ForEach-Object System)
    $mediaPlan=Prepare-MediaPlan @($mediaJobs|Where-Object {$held-cnotcontains$_.System}) @($mediaSources|Where-Object {$held-cnotcontains$_.system}) $mediaContext
    $script:Perf.overall=70
    $summary=Get-PromotionSummaryProposal @($plans|ForEach-Object Inventory) 0
    Add-PerfCounter 'ManagedRomCount' $summary.ManagedCount
    Add-PerfCounter 'LocalOnlyRomCount' $summary.LocalOnlyCount
    Add-PerfCounter 'ReviewRomCount' $summary.ReviewCount
    @{Summary=$summary;HeldMediaSystems=$held;Moves=@($plans|ForEach-Object Moves).Count;Promotions=@($plans|ForEach-Object Promotions).Count;MediaKinds=@($mediaPlan.Operations|Group-Object kind|Select-Object Name,Count);ActualMutation=0;SyncExecuted=$false}|ConvertTo-Json -Depth 12|Set-Content (Join-Path $Evidence 'plan.json') -Encoding UTF8
    Write-Status 'done' '읽기 전용 baseline 완료' 1 1 $summary
} finally {Write-PerfSummary;if($mediaContext){Close-MediaSession $mediaContext}}
Copy-Item (Join-Path $Evidence 'performance-baseline.json') (Join-Path $Evidence 'normal-performance.json')
Initialize-Perf 'DuplicateScan-readonly'
$script:Perf.gitCheckpoint=$checkpoint;$script:Perf.implementationSha256=$implementation
$snapshot=Get-DuplicateProductionSnapshot $Evidence;$rows=@(New-DuplicateProductionRows $snapshot)
Add-PerfCounter 'DuplicateCandidateCount' $rows.Count
$rows|Select-Object Id,Grade|ConvertTo-Json|Set-Content (Join-Path $Evidence 'duplicate-rows.json') -Encoding UTF8
Write-Status 'done' '중복 baseline 완료' 1 1
Write-PerfSummary
Copy-Item (Join-Path $Evidence 'performance-baseline.json') (Join-Path $Evidence 'duplicate-performance.json')
