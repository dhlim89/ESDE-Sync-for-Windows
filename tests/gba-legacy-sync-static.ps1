# GBA mock filesystem에 production dispatch와 실제 v1.4.9 mirror를 각각 실행한다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$git=(Get-Command git -ErrorAction SilentlyContinue).Source
if(-not$git){$git=@(Get-ChildItem $env:TEMP -Directory -Filter 'esde-baseline-git-*'|ForEach-Object {Join-Path $_.FullName 'git/cmd/git.exe'}|Where-Object {Test-Path $_}|Select-Object -First 1)[0]}
if(-not$git){throw 'baseline Git required'}
$baseline=(& $git -C $repo show v1.4.9:sync-worker.ps1)|Out-String
if($LASTEXITCODE-ne0){throw 'v1.4.9 baseline unavailable'}
$old=[Management.Automation.Language.Parser]::ParseInput($baseline,[ref]$null,[ref]$null)
function Definition($tree,$name){$tree.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq$name},$false)[0].Extent.Text}
$oldMirror=Definition $old 'Mirror-SystemFolder'
. ([scriptblock]::Create($oldMirror.Replace('function Mirror-SystemFolder(','function Mirror-V149Baseline(')))
$n=0
function Check($ok,$name){if(-not$ok){throw $name};$script:n++;'PASS: '+$name}
Check ((Definition $ast 'Mirror-SystemFolder').Replace([string][char]13,'')-ceq$oldMirror.Replace([string][char]13,'')) 'v1.4.9 mirror body identical'
foreach($name in @('Get-RemoteFiles','Get-RemoteDirs','Remove-RemoteFile','Remove-RemoteTree','Assert-RemotePath','Prepare-MediaPlan','Invoke-MediaTransaction')){
    Check ((Definition $ast $name).Replace([string][char]13,'')-ceq(Definition $old $name).Replace([string][char]13,'')) ($name+' baseline unchanged')
}
$root=Join-Path $env:TEMP ('gba-legacy-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'roms/gba'))
$SourceRoot=$root;$Serial='MOCK';$selectedSystems=@('gba');$ReservedFolders=@('_TEST','_UNREGISTERED')
$Buckets=@(@{Remote='/storage/emulated/0/ROMs'},@{Remote='/storage/emulated/0/ES-DE/gamelists'},@{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$romRoot='/storage/emulated/0/ROMs/gba'
$localRoot=Join-Path $root 'roms/gba'
[IO.File]::WriteAllText((Join-Path $localRoot 'A.gba'),'A')
[IO.File]::WriteAllText((Join-Path $localRoot 'B.gba'),'B')
function Reset{
    $script:Remote=@{
        ($romRoot+'/A.gba')='A';($romRoot+'/Old.gba')='OLD'
        ($romRoot+'/_TEST/Test.gba')='TEST';($romRoot+'/_UNREGISTERED/Local.gba')='LOCAL'
    }
    $script:Calls=@();$script:Logs=@()
}
function Write-Log($m){$script:Logs+=$m}
function Ensure-RemoteDir($p){Assert-RemotePath ($p+'/guard');$script:Calls+=('mkdir:'+ $p)}
function Try-RemoveEmptyRemoteDir($p){$script:Calls+=('rmdir:'+ $p)}
function Remove-RemoteFile($p){Assert-RemotePath $p -Deleting;$script:Calls+=('delete:'+ $p);$script:Remote.Remove($p)}
function Invoke-Adb{
    $reply=[pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}
    $cmd=[string]$args[3]
    if($args[2]-ceq'shell' -and $cmd.Contains('-print0')){
        $rows=if($cmd.Contains('-type f')){@($script:Remote.Keys|Where-Object {-not(Is-LocalOnlyRelativePath $_.Substring($romRoot.Length+1))}|Sort-Object)}else{@()}
        $reply.StdOut=if($rows.Count){($rows-join[char]0)+[char]0}else{''}
        return $reply
    }
    if($args[2]-ceq'push' -and $args[3]-ceq'--sync'){
        $script:Calls+=('push:'+ $args[4]+':'+$args[5])
        if(Test-Path $args[4] -PathType Container){
            foreach($file in @(Get-ManagedLocalItems $localRoot|Where-Object {-not$_.PSIsContainer})){
                $script:Remote[$romRoot+'/'+$file.Name]=[IO.File]::ReadAllText($file.FullName)
            }
        }else{$script:Remote[$args[5]]=[IO.File]::ReadAllText($args[4])}
        return $reply
    }
    throw ('unexpected legacy mock: '+($args-join' '))
}
Reset
Mirror-V149Baseline $localRoot $romRoot 'baseline'
$before=($script:Remote.GetEnumerator()|Sort-Object Name|ForEach-Object {$_.Name+'='+$_.Value})-join'|'
$beforeCalls=$script:Calls-join'|'
Reset
$job=[pscustomobject]@{System='gba';LocalPath=$localRoot;RemotePath=$romRoot}
Sync-RomSystem $job $null 'current'
$after=($script:Remote.GetEnumerator()|Sort-Object Name|ForEach-Object {$_.Name+'='+$_.Value})-join'|'
Check ($before-ceq$after -and $beforeCalls-ceq($script:Calls-join'|')) 'GBA actual job effects equal v1.4.9'
Check ($script:Remote[$romRoot+'/A.gba']-ceq'A') 'A compared/transferred normally'
Check ($script:Remote[$romRoot+'/B.gba']-ceq'B') 'B managed push succeeds'
Check (-not$script:Remote.ContainsKey($romRoot+'/Old.gba')) 'Old legacy delete retained'
Check ($script:Remote[$romRoot+'/_TEST/Test.gba']-ceq'TEST') '_TEST untouched'
Check ($script:Remote[$romRoot+'/_UNREGISTERED/Local.gba']-ceq'LOCAL') '_UNREGISTERED untouched'
Check (-not@($Calls|Where-Object {$_-match'move:|rename:|_UNREGISTERED/Old'}).Count) 'classification move/rename zero'
Check ((Get-Content (Join-Path $localRoot 'A.gba') -Raw)-ceq'A' -and (Get-Content (Join-Path $localRoot 'B.gba') -Raw)-ceq'B') 'source read-only'
# XML은 실제 Merge 함수와 legacy prepare를 통과한다. 알 수 없는 standalone도 새 변환을 강요하지 않는다.
$master=ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<gameList><game><path>./A.gba</path><name>Master</name><playcount>2</playcount><altemulator>Unverified (Standalone)</altemulator></game></gameList>'))
$androidText='<alternativeEmulator label="Android"><!--keep--><child/></alternativeEmulator><gameList><game><path>./A.gba</path><name>Android</name><playcount>0</playcount></game><game custom="keep"><path>./_TEST/Test.gba</path><unknown>yes</unknown></game><game><path>./_UNREGISTERED/Local.gba</path><favorite>true</favorite></game><game><path>./Old.gba</path><name>Stale</name></game></gameList>'
function Get-RemoteGamelistState($p){$true}
function Invoke-Adb{[IO.File]::WriteAllText($args[4],$androidText);[pscustomobject]@{Code=0;StdErr='';StdOut='';Output=@()}}
$xml=[pscustomobject]@{System='gba';RemotePath='/storage/emulated/0/ES-DE/gamelists/gba';GamelistSource=$master}
$prepared=Prepare-RomSystemSync $job $xml $root
Check ($null-eq$prepared.ClassificationPlan) 'GBA no classification plan'
$result=Read-EsdeGamelist $prepared.XmlPlan.Output
$entries=@(Get-EsdeGameEntries $result)
$a=@($entries|Where-Object Key -CEQ './A.gba')[0].Node
Check ($a.name-ceq'Master' -and $a.playcount-ceq'0') 'managed metadata/runtime remain correct'
Check ($a.altemulator-ceq'Unverified (Standalone)') 'legacy altemulator not blocked/transformed'
Check (@($entries|Where-Object Key -CEQ './_TEST/Test.gba')[0].Node.GetAttribute('custom')-ceq'keep') 'legacy _TEST whole-node preserved'
Check (@($entries|Where-Object Key -CEQ './_UNREGISTERED/Local.gba')[0].Node.favorite-ceq'true') 'legacy _UNREGISTERED whole-node preserved'
Check (@($entries|Where-Object Key -CEQ './Old.gba').Count-eq0) 'legacy stale ordinary XML removal retained'
'GBA legacy 검증 완료: '+$n+' / fixture '+$root