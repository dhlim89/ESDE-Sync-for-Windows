$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$ReservedFolders=@('_TEST','_UNREGISTERED');$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$work){$blocked=$false;try{& $work|Out-Null}catch{$blocked=$true};Check $blocked ($name+' 차단')}
function Row($p,$sha=('a'*64)){[pscustomobject]@{RelativePath=$p;Sha256=$sha}}
$fixture=Get-Content (Join-Path $PSScriptRoot 'rom-classification/cases.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($case in $fixture){
 $p=@(New-UnregisteredClassificationPlan gb @($case.Source) @($case.Android) @() @('gb'))
 Check ($p[0].Classification-ceq$case.Expected) ($case.Name+' classification')
 Check ($null-ne$p[0].Reason -and $null-ne$p[0].AndroidRelativePath -and $null-ne$p[0].AndroidSha256) ($case.Name+' 진단 fields')
}
$p=@(New-UnregisteredClassificationPlan gb @(Row 'a.gb') @(Row 'a.gb' ('b'*64)) @() @('gb'))
Check ($p[0].Action-ceq'PRESERVE_AND_WARN' -and $p[0].Reason-like'*version/revision/patch*') 'conflict warning/move job 없음'
$p=@(New-UnregisteredClassificationPlan gb @() @(Row 'Hacks/foo.gb') @() @('gb'))
Check ($p[0].DestinationRelativePath-ceq'_UNREGISTERED/Hacks/foo.gb') 'nested 구조 유지'
foreach($path in @('../escape.gb','/storage/a.gb','C:\a.gb','CON.gb','a?.gb','a./foo.gb','a//foo.gb','foo.exe')){
 $p=@(New-UnregisteredClassificationPlan gb @() @(Row $path) @() @('gb'))
 Check ($p[0].Classification-ceq'INVALID' -and $p[0].Action-ceq'BLOCK') ($path+' INVALID')
}
foreach($sha in @(('a'*64),('b'*64))){
 $p=@(New-UnregisteredClassificationPlan gb @() @(Row 'foo.gb') @(Row '_UNREGISTERED/foo.gb' $sha) @('gb'))
 Check ($p[0].Action-ceq'BLOCK' -and $p[0].Classification-ceq'UNMANAGED') 'destination collision source cleanup 없음'
}
$p=@(New-UnregisteredClassificationPlan gb @() @((Row 'foo.gb'),(Row 'FOO.gb')) @() @('gb'))
Check ($p[1].Classification-ceq'INVALID') 'Android case collision'
Reject 'system scope' {New-UnregisteredClassificationPlan gbc @() @(Row 'foo.gbc') @() @('gb')}
$p=@(New-UnregisteredClassificationPlan gb @() @(Row 'foo.gb' 'unknown') @() @('gb'))
Check ($p[0].Classification-ceq'INVALID') 'unknown hash INVALID'
Reject 'unknown extension system policy' {New-UnregisteredClassificationPlan neogeo @() @(Row 'foo.zip') @() @('neogeo')}
$idx=New-ManagedRomShaIndex gb @((Row 'a.gb'),(Row 'copy.gb')) @('gb')
Check (@($idx.Hashes['a'*64]).Count-eq2) 'SHA index multiple candidates'
$p=@(New-UnregisteredClassificationPlan gb @(Row 'a.gb') @(Row 'bar.gb') @() @('gb'))[0]
$r=New-ManagedCanonicalizationPlan $p $null @() @()
Check ($r.Status-ceq'REVIEW' -and @($r.Operations).Count-eq0) 'mapping unknown no mutation proposal'
$mapping=[pscustomobject]@{schemaVersion=1;Verified=$true;CompleteInventory=$true;System='gb';Evidence='MOCK ONLY: verified explicit asset fixture';SaveRoot='/storage/emulated/0/fixture/save';StateRoot='/storage/emulated/0/fixture/state';MediaRoot='/storage/emulated/0/fixture/media';VerifiedAbsentKinds=@()}
$bindings=@(
 [pscustomobject]@{Kind='ROM';SourcePath='/storage/emulated/0/ROMs/gb/bar.gb';DestinationPath='/storage/emulated/0/ROMs/gb/a.gb';Sha256=('a'*64)}
 [pscustomobject]@{Kind='Save';SourcePath='/storage/emulated/0/fixture/save/bar.srm';DestinationPath='/storage/emulated/0/fixture/save/a.srm';Sha256=('b'*64)}
 [pscustomobject]@{Kind='State';SourcePath='/storage/emulated/0/fixture/state/bar.state3';DestinationPath='/storage/emulated/0/fixture/state/a.state3';Sha256=('c'*64)}
 [pscustomobject]@{Kind='Media';SourcePath='/storage/emulated/0/fixture/media/bar.png';DestinationPath='/storage/emulated/0/fixture/media/a.png';Sha256=('d'*64)}
)
$r=New-ManagedCanonicalizationPlan $p $mapping $bindings @()
Check ($r.Status-ceq'CANONICALIZATION_CANDIDATE' -and @($r.Operations).Count-eq5) 'known mapping ROM/save/state/media/XML complete proposal'
foreach($kind in @('ROM','Save','State','Media','Gamelist')){Check (@($r.Operations|Where-Object Kind -CEQ $kind).Count-eq1) ($kind+' coordinated operation')}
Reject 'canonical target collision' {New-ManagedCanonicalizationPlan $p $mapping $bindings @('/storage/emulated/0/fixture/state/a.state3')}
Reject 'canonical gamelist collision' {New-ManagedCanonicalizationPlan $p $mapping $bindings @() @('./a.gb')}
$slots=@($bindings)+@(
 [pscustomobject]@{Kind='State';SourcePath='/storage/emulated/0/fixture/state/bar.state';DestinationPath='/storage/emulated/0/fixture/state/a.state';Sha256=('e'*64)}
 [pscustomobject]@{Kind='State';SourcePath='/storage/emulated/0/fixture/state/bar.state.auto';DestinationPath='/storage/emulated/0/fixture/state/a.state.auto';Sha256=('f'*64)}
 [pscustomobject]@{Kind='Save';SourcePath='/storage/emulated/0/fixture/save/bar.rtc';DestinationPath='/storage/emulated/0/fixture/save/a.rtc';Sha256=('e'*64)}
)
$r=New-ManagedCanonicalizationPlan $p $mapping $slots @()
Check (@($r.Operations|Where-Object Kind -CEQ State).Count-eq3 -and @($r.Operations|Where-Object Kind -CEQ Save).Count-eq2) 'explicit slot/auto/RTC fixture coordinated proposal'
Check (@($r.Operations|Where-Object {$_.DestinationPath-ceq'/storage/emulated/0/fixture/state/a.state.auto'}).Count-eq1) 'auto state binding preserved without naming inference'
$r=New-ManagedCanonicalizationPlan $p $mapping @($bindings[0]) @()
Check ($r.Status-ceq'REVIEW' -and @($r.Operations).Count-eq0) 'ROM-only proposal forbidden'
$source=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'))
Check ($source-notmatch'Install-AdoptionDiskFile|function .*Adoption|adoption-transactions|adoption-resolutions|managed-rom-paths') '폐기 runtime 코드/list/journal 없음'
Check ($source.Contains('$LocalOnlyFolders = @(''_TEST'', ''_UNREGISTERED'')')) 'local-only 공통 목록'
$mirrorCall=$source.LastIndexOf('Sync-RomSystem $job')
$applyCall=$source.LastIndexOf('Invoke-ClassificationMoves $classificationPlans')
$refreshCall=$source.LastIndexOf('Confirm-ClassificationInventory $plan')
Check ($applyCall-ge0 -and $mirrorCall-ge0 -and $applyCall-lt$mirrorCall) 'classification before mirror'
Check ($refreshCall-ge0 -and $mirrorCall-ge0 -and $refreshCall-lt$mirrorCall) 'refresh before mirror/delete'
Write-Output ('classification 검증 완료: '+$script:Passed)
