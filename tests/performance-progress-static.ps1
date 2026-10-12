$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$root=Join-Path $env:TEMP ('esde-perf-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$StatusFile=Join-Path $root 'status.json';$StateDir=$root;$Operation='Sync';$AppVersion=@{version='1.7.0'};$Serial='fake';function Write-Log($m){}
$passed=0;function Check($ok,$name){if(-not$ok){throw $name};$script:passed++;Write-Host ('PASS: '+$name)}
Initialize-Perf 'fixture'
$token=Start-PerfPhase 'inventory' '파일 목록 확인 중'
$p=Get-PerfProgress;Check ($p.indeterminate-and$null-eq$p.phasePercent) 'unknown total indeterminate'
Set-PerfWork 1 2 '한글 (공백)/Game.gb'
$p=Get-PerfProgress;Check ($p.phasePercent-eq50-and$p.phaseCurrent-eq1-and$p.phaseTotal-eq2) 'determinate workload'
Check ($p.currentItem-ceq'한글 (공백)/Game.gb') 'Unicode current item'
Set-PerfWork 0 2 'same';Check ((Get-PerfProgress).phasePercent-eq50) 'phase monotonic'
Write-Status 'running' '기존 메시지' 1 6 @{ManagedCount=97}
$a=Get-Content $StatusFile -Raw -Encoding UTF8|ConvertFrom-Json
Check ($a.percent-eq16-and$a.current-eq1-and$a.total-eq6-and$a.summary.ManagedCount-eq97) 'legacy fields unchanged'
Write-Status 'running' 'next' 0 6;$b=Get-Content $StatusFile -Raw -Encoding UTF8|ConvertFrom-Json
Check ($b.overallPercent-ge$a.overallPercent) 'overall monotonic'
$writes=$script:Perf.writes;1..100|ForEach-Object {Write-PerfProgress};Check ($script:Perf.writes-eq$writes) '500ms throttle'
$file=Join-Path $root 'hash 한글.bin';[IO.File]::WriteAllBytes($file,[byte[]](1,2,3));$expected=Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $file
$actual=Get-PerfFileHash -LiteralPath $file;Check ($actual.Hash-ceq$expected.Hash) 'hash bytes unchanged'
Check ($script:Perf.counters.TotalHashCount-eq1) 'file hash exact counter'
[void](Get-MediaTextHash 'text');Check ($script:Perf.counters.TotalHashCount-eq2-and$script:Perf.counters.TextHashCount-eq1) 'text SHA counter'
Stop-PerfPhase $token;Check ($script:Perf.phases.Count-eq1-and$script:Perf.phases[0].hashCount-eq2) 'phase hash delta'
Write-Status 'done' '완료' 6 6;$b=Get-Content $StatusFile -Raw -Encoding UTF8|ConvertFrom-Json;Check ($b.overallPercent-eq100-and$b.state-ceq'done') 'done 100'
Write-PerfSummary;$report=Get-Content (Join-Path $root 'performance-baseline.json') -Raw -Encoding UTF8|ConvertFrom-Json
Check ($report.progressWriteCount-gt0-and$report.progressWriteElapsedMs-ge0) 'progress write overhead'
Check ($report.maxProgressSilenceMs-ge0-and$report.elapsedMs-ge0) 'silence and total time'
$script:Perf=$null;Write-Status 'running' 'old' 2 6;$legacy=Get-Content $StatusFile -Raw -Encoding UTF8|ConvertFrom-Json
Check ($legacy.percent-eq33-and$null-eq$legacy.overallPercent) 'instrumentation inactive legacy status'
$gui=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$null,[ref]$null)
$fn=$gui.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-WorkerProgressPresentation'},$false);. ([scriptblock]::Create($fn.Extent.Text))
$view=Get-WorkerProgressPresentation @{phaseLabel='미디어 확인';phaseCurrent=374;phaseTotal=911;currentItem='한글/Game.png';elapsedMs=18234;overallPercent=63;state='running'}
Check ($view.Percent-eq63-and$view.Text-match'374 / 911'-and$view.Text-match'00:00:18'-and$view.Text-match'한글/Game.png') 'GUI phase workload item elapsed'
Check ((Get-WorkerProgressPresentation @{percent=33;message='old'}).Text-ceq'old') 'GUI old status backward compatible'
$AdbPath=(Get-Command powershell.exe).Source
$fake=Join-Path $root 'fake-transport.ps1';[IO.File]::WriteAllText($fake,"param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$rest)`nWrite-Output ('a'*64+'  /storage/emulated/0/ROMs/gb/Game.gb')",(New-Object Text.UTF8Encoding($true)))
Initialize-Perf 'fake-adb'
$reply=Invoke-Adb -NoProfile -File $fake shell sha256sum /storage/emulated/0/ROMs/gb/Game.gb
Check ($reply.Code-eq0-and$script:Perf.counters.TotalAdbCalls-eq1-and$script:Perf.counters.AdbShellCalls-eq1) 'real wrapper fake transport ADB count'
Check ($script:Perf.counters.AdbHashCalls-eq1-and$script:Perf.counters.AndroidRomHashCount-eq1-and$script:Perf.counters.TotalHashCount-eq1) 'native hash output count'
$slow=Join-Path $root 'slow-transport.ps1';[IO.File]::WriteAllText($slow,'Start-Sleep -Milliseconds 1200; Write-Output done',(New-Object Text.UTF8Encoding($true)))
$beforeWrites=$script:Perf.writes;$reply=Invoke-Adb -NoProfile -File $slow
Check ($reply.Code-eq0-and$reply.StdOut.Trim()-ceq'done'-and$script:Perf.writes-ge$beforeWrites+2) 'long process heartbeat and output contract'
function Invoke-VerifiedPerfFixture {Get-PerfFileHash -LiteralPath $file}
[void](Invoke-VerifiedPerfFixture);Check ($script:Perf.counters.MutationRevalidationHashCount-eq1) 'mutation revalidation subset'
Check ((Get-WorkerProgressPresentation @{state='done';percent=100;indeterminate=$true}).Indeterminate-eq$false) 'done GUI determinate'
Add-Type -AssemblyName System.Windows.Forms
$bar=New-Object Windows.Forms.ProgressBar;$label=New-Object Windows.Forms.Label
try{
    $bar.Value=$view.Percent;$label.Text=$view.Text
    Check ($bar.Value-eq63-and$label.Text-match'미디어 확인') 'actual Forms controls receive progress model'
    $bar.Style=[Windows.Forms.ProgressBarStyle]::Marquee;Check ($bar.Style-eq[Windows.Forms.ProgressBarStyle]::Marquee) 'actual indeterminate progress bar'
}finally{$bar.Dispose();$label.Dispose()}
# Controlled tiny workload: identical classification code, one source byte change, no transport/mutation.
$SourceRoot=Join-Path $root 'source';$romRoot=Join-Path $SourceRoot 'roms/gb';[void][IO.Directory]::CreateDirectory($romRoot)
$one=Join-Path $romRoot 'Game.gb';[IO.File]::WriteAllBytes($one,[byte[]](1,2,3));$job=[pscustomobject]@{System='gb';LocalPath=$romRoot}
Initialize-Perf 'mock-unchanged';$source=@(Get-ClassificationSourceRows $job);$remote=@([pscustomobject]@{RelativePath='Game.gb';Sha256=$source[0].Sha256});$first=@(New-UnregisteredClassificationPlan gb $source $remote @() @('gb'));Write-PerfSummary
Copy-Item (Join-Path $StateDir 'performance-baseline.json') (Join-Path $StateDir 'mock-unchanged.json')
[IO.File]::WriteAllBytes($one,[byte[]](1,2,4));Initialize-Perf 'mock-one-ROM-change';$changed=@(Get-ClassificationSourceRows $job);$second=@(New-UnregisteredClassificationPlan gb $changed $remote @() @('gb'));Write-PerfSummary
Copy-Item (Join-Path $StateDir 'performance-baseline.json') (Join-Path $StateDir 'mock-small-change.json')
Check ($source[0].Sha256-cne$changed[0].Sha256-and$script:Perf.counters.SourceRomHashCount-eq1) 'one ROM change workload measured'
Check ($first[0].Classification-ceq'MANAGED'-and$second[0].Classification-ceq'MANAGED_CONFLICT') 'small change preserves conflict policy'
Write-Host ('performance progress fixtures PASS: '+$passed)
