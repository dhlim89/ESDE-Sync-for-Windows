$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$root=Join-Path $env:TEMP ('insp31-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$work){$blocked=$false;try{& $work|Out-Null}catch{$blocked=$true};Check $blocked ($name+' 차단')}
function Present($sha){[pscustomobject]@{State='Present';Sha256=$sha}}
function Absent{[pscustomobject]@{State='Absent';Sha256=''}}
function Read-AdoptionRemoteResidue($path,$suffix){[pscustomobject]@{State='Known';Paths=@()}}
function Read-AdoptionObservation($path,$remote){
 if($script:Obs.ContainsKey($path)){return $script:Obs[$path]}
 return [pscustomobject]@{State='Unknown';Sha256='';Reason='missing fixture'}
}
function Setup{
 $case=Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0,8))
 $library=Join-Path $case 'library';$state=Join-Path $case 'State'
 foreach($dir in @($state,(Join-Path $library 'roms/gb'),(Join-Path $library 'gamelists/gb'))){[void][IO.Directory]::CreateDirectory($dir)}
 $script:Context=New-AdoptionExecutorContext $state $library 'MOCK' @('gb') -DeferJournalGate
 $script:Id=[guid]::NewGuid().ToString('N')
 $script:Disk=Join-Path $library 'roms/gb/new.gb'
 $script:Inbox='/storage/emulated/0/ROMs/gb/_UNREGISTERED/new.gb'
 $script:Android='/storage/emulated/0/ROMs/gb/new.gb'
 $script:PcXml=Join-Path $library 'gamelists/gb/gamelist.xml'
 $script:RemoteXml='/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml'
 $time=[DateTimeOffset]::UtcNow.ToString('o')
 $script:Journal=[pscustomobject]@{schemaVersion=1;identity=$Context.Identity;transactionId=$Id;createdAt=$time;updatedAt=$time;state='failed';completed=$false;originalError='copy denied';history=@([pscustomobject]@{state='staged';at=$time},[pscustomobject]@{state='source-verified';at=$time},[pscustomobject]@{state='failed';at=$time});entries=@([pscustomobject]@{System='gb';InboxPath=$Inbox;RelativePath='new.gb';Sha256=('a'*64);DropboxPath=$Disk;AndroidPath=$Android;DestinationHash='';AndroidDestinationHash=''});systemSnapshots=@([pscustomobject]@{System='gb';DropboxHash=('b'*64);AndroidHash=('c'*64)})}
 [void][IO.Directory]::CreateDirectory($Context.JournalRoot)
 $script:JournalPath=Join-Path $Context.JournalRoot ($Id+'.json')
 $script:Obs=@{};$script:Obs[$Inbox]=Present ('a'*64);$script:Obs[$Disk]=Absent;$script:Obs[$Android]=Absent;$script:Obs[$PcXml]=Present ('b'*64);$script:Obs[$RemoteXml]=Present ('c'*64)
 Save
}
function Save{[IO.File]::WriteAllText($JournalPath,($Journal|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))}
function Inspect{Get-AdoptionInspection $JournalPath $Context}
Setup
$i=Inspect
Check ($i.Result-ceq'NO_COMMIT_CONFIRMED') ('commit 전 실패 inspector: '+($i.Reasons-join','))
$hash=(Get-FileHash -LiteralPath $JournalPath).Hash
Reject '명시적 승인 없이 abandon' {New-AdoptionAbandonResolution $JournalPath $Context -Reason 'fixture'}
$r=New-AdoptionAbandonResolution $JournalPath $Context -Reason 'fixture manual approval' -Approved
Check ($r.resolution-ceq'abandoned') 'NO_COMMIT만 explicit resolution'
Check ((Get-FileHash -LiteralPath $JournalPath).Hash-ceq$hash) '원본 journal 무수정'
Check ($null-ne(New-AdoptionExecutorContext $Context.StateRoot $Context.SourceRoot 'MOCK' @('gb'))) '유효 abandoned resolution gate 해제'
$resolutionPath=Join-Path (Join-Path (Join-Path $Context.StateRoot 'adoption-resolutions') $Context.Identity) ($Id+'.json')
$oldResolutionHash=(Get-FileHash -LiteralPath $resolutionPath).Hash
Reject '기존 resolution overwrite' {New-AdoptionAbandonResolution $JournalPath $Context -Reason 'again' -Approved}
Check ((Get-FileHash -LiteralPath $resolutionPath).Hash-ceq$oldResolutionHash) 'resolution SHA 보존'
$r.transactionId='0'*32;[IO.File]::WriteAllText($resolutionPath,($r|ConvertTo-Json -Depth 20))
Reject 'resolution transaction mismatch' {New-AdoptionExecutorContext $Context.StateRoot $Context.SourceRoot 'MOCK' @('gb')}
[IO.File]::WriteAllText($resolutionPath,'{broken')
Reject 'corrupt resolution' {New-AdoptionExecutorContext $Context.StateRoot $Context.SourceRoot 'MOCK' @('gb')}
Setup
$script:Obs[$Disk]=Present ('a'*64)
Check ((Inspect).Result-ceq'PARTIAL_COMMIT') 'Dropbox canonical 생성 partial'
Reject 'partial commit abandon' {New-AdoptionAbandonResolution $JournalPath $Context -Reason 'fixture' -Approved}
Setup
$script:Obs[$Android]=Present ('a'*64)
Check ((Inspect).Result-ceq'PARTIAL_COMMIT') 'Android canonical만 생성 partial'
Setup
$script:Obs[$PcXml]=Present ('d'*64)
Check ((Inspect).Result-ceq'STATE_MISMATCH') 'Dropbox XML fingerprint 변경'
Setup
$script:Obs[$RemoteXml]=Present ('d'*64)
Check ((Inspect).Result-ceq'STATE_MISMATCH') 'Android XML fingerprint 변경'
Setup
$script:Obs[$Inbox]=Present ('f'*64)
Check ((Inspect).Result-ceq'STATE_MISMATCH') 'inbox SHA mismatch'
Setup
[IO.File]::WriteAllText(($Disk+'.esde-adoption-residue'),'residue')
Check ((Inspect).Result-ceq'UNKNOWN') 'staging residue Unknown'
Setup
[IO.File]::WriteAllText($JournalPath,'{broken')
Check ((Inspect).Result-ceq'UNKNOWN') 'corrupt journal Unknown'
Setup
$Journal.PSObject.Properties.Remove('systemSnapshots');Save
Check ((Inspect).Result-ceq'UNKNOWN') 'missing baseline evidence Unknown'
Setup
$script:Obs.Remove($Inbox)
Check ((Inspect).Result-ceq'UNKNOWN') 'unknown remote observation'
Setup
$Journal.history=@($Journal.history[0],[pscustomobject]@{state='dropbox-installed';at=$Journal.createdAt},$Journal.history[-1]);Save
Check ((Inspect).Result-ceq'STATE_MISMATCH') '기록된 commit과 absent 실제 상태 모순'
Setup
$r=New-AdoptionAbandonResolution $JournalPath $Context -Reason 'fixture' -Approved
$r.evidence.Observations[0].Inbox.Sha256='e'*64
[IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $Context.StateRoot 'adoption-resolutions') $Context.Identity) ($Id+'.json')),($r|ConvertTo-Json -Depth 20))
Reject 'resolution evidence 변조' {New-AdoptionExecutorContext $Context.StateRoot $Context.SourceRoot 'MOCK' @('gb')}
Setup
$Journal.entries[0].DropboxPath=Join-Path $root 'outside.gb';Save
Check ((Inspect).Result-ceq'UNKNOWN') 'journal scope 변조 Unknown'
Setup
$Journal.state='source-verified';$Journal.history=@($Journal.history[0],$Journal.history[1]);Save
Check ((Inspect).Result-ceq'UNKNOWN') 'nonterminal journal 직접 abandon 금지'
Setup
$Journal.entries[0].DestinationHash='a'*64;$Journal.entries[0].AndroidDestinationHash='a'*64
$script:Obs[$Disk]=Present ('a'*64);$script:Obs[$Android]=Present ('a'*64);Save
Check ((Inspect).Result-ceq'NO_COMMIT_CONFIRMED') '기존 동일 SHA canonical baseline 재사용은 새 commit 아님'
Setup
$originalResidue=(Get-Item Function:Read-AdoptionRemoteResidue).ScriptBlock
function Read-AdoptionRemoteResidue($path,$suffix){[pscustomobject]@{State='Known';Paths=@('fixture remote temp')}}
Check ((Inspect).Result-ceq'UNKNOWN') 'Android staging residue Unknown'
Set-Item Function:Read-AdoptionRemoteResidue -Value $originalResidue
Write-Output ('journal inspector 검증 완료: '+$script:Passed+' / fixture '+$root)