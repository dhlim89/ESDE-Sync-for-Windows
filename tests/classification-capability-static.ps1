# 실제 worker 본문/ADB를 실행하지 않고 capability와 dispatch 계약만 검증한다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$n=0
function Check($ok,$name){if(-not$ok){throw $name};$script:n++;'PASS: '+$name}
function Reject($name,[scriptblock]$work){$bad=$false;try{& $work|Out-Null}catch{$bad=$true};Check $bad $name}
foreach($system in @('gb','gbc')){
    Check ((Get-RomClassificationCapability $system).Status-ceq'Supported') ($system+' Supported')
    Check (@(Get-ClassificationExtensions $system).Count-eq11) ($system+' verified extensions')
}
foreach($system in @('gba','nes','snes','arcade','neogeo')){
    Check ((Get-RomClassificationCapability $system).Status-ceq'Unsupported') ($system+' Unsupported')
    Check (@(Get-ClassificationExtensions $system).Count-eq0) ($system+' no extension throw')
}
foreach($system in @('','../gb','/gba','gb/gba','_TEST','_unregistered','CON')){
    Check ((Get-RomClassificationCapability $system).Status-ceq'Unknown') 'invalid system Unknown'
    Reject 'invalid extension request blocked' {Get-ClassificationExtensions $system}
}
$selectedSystems=@('gb','gbc','gba')
$script:Logs=@();$script:Calls=@()
function Write-Log($m){$script:Logs+=$m}
function Prepare-GamelistSystem($Job,$Session,[switch]$LegacyManagedSync,[switch]$PreserveNonMasterNodes,[switch]$SnapshotOnly){
    $script:Calls+=('xml:'+ $Job.System+':legacy='+[bool]$LegacyManagedSync+':snapshot='+[bool]$SnapshotOnly)
    [pscustomobject]@{System=$Job.System;Validated=$true}
}
function Prepare-ClassificationSystem($RomJob,$XmlJob,$XmlPlan,$Session){
    $script:Calls+=('classification:'+ $RomJob.System)
    [pscustomobject]@{System=$RomJob.System;XmlPlan=$XmlPlan;Moves=@()}
}
function Mirror-SystemFolder($LocalSystemPath,$RemoteSystemPath,$Label){$script:Calls+='legacy-mirror'}
function Sync-ClassifiedManagedRom($Job,$Plan,$Label){$script:Calls+='classified-mirror'}
$rom=[pscustomobject]@{System='gba';LocalPath='MOCK';RemotePath='/storage/emulated/0/ROMs/gba'}
$xml=[pscustomobject]@{System='gba'}
$p=Prepare-RomSystemSync $rom $xml 'MOCK'
Check ($null-eq$p.ClassificationPlan -and $p.Capability.Status-ceq'Unsupported') 'unsupported classification skipped'
Check (($Calls-join'|')-ceq'xml:gba:legacy=True:snapshot=False') 'legacy XML requested; no classifier/read/hash/move'
Sync-RomSystem $rom $p.ClassificationPlan 'MOCK'
Check ($Calls[-1]-ceq'legacy-mirror') 'unsupported direct legacy mirror'
Check (($Logs-join'|').Contains('unsupported action=legacy-managed-sync')) 'skip diagnostic logged without warning'
foreach($system in @('gb','gbc')){
    $rom.System=$system;$xml.System=$system;$script:Calls=@()
    $p=Prepare-RomSystemSync $rom $xml 'MOCK'
    Sync-RomSystem $rom $p.ClassificationPlan 'MOCK'
    Check (($Calls-join'|')-ceq('xml:'+$system+':legacy=False:snapshot=True|classification:'+$system+'|classified-mirror')) ($system+' existing pipeline retained')
}
$rom.System='gba'
Reject 'unsupported stale classification plan blocked' {Sync-RomSystem $rom $p.ClassificationPlan 'MOCK'}
$rom.System='bad/gb'
Reject 'invalid worker dispatch blocked' {Sync-RomSystem $rom $null 'MOCK'}
$worker=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'))
Check ($worker.Contains('if($classificationSystems.Count){$classificationContext=New-ClassificationContext')) 'unsupported-only skips classification state gate'
Check ($worker.Contains('if($prepared.ClassificationPlan){$classificationPlans+=$prepared.ClassificationPlan}')) 'unsupported plans excluded from move/refresh/media hold'
Check ($worker.Contains('Sync-RomSystem $job')) 'actual job loop uses dispatch'
'capability 검증 완료: '+$n