$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Descriptor($rules){
 $raw=New-Object Security.AccessControl.RawSecurityDescriptor('O:'+$sid+'G:'+$sid+'D:'+$rules)
 $b=New-Object byte[] $raw.BinaryLength;$raw.GetBinaryForm($b,0);return ,$b
}
$deny=Descriptor ('(D;;0x10056;;;WD)(A;OICI;FA;;;'+$sid+')')
$full=Descriptor ('(A;OICI;FA;;;'+$sid+')')
$inheritDeny=Descriptor ('(D;ID;0x10056;;;WD)(A;ID;FA;;;'+$sid+')')
$unrelated=Descriptor ('(D;;0x10000;;;WD)(A;OICI;FA;;;'+$sid+')')
Check ((Test-AdoptionSecurityAccess $deny 2).Result-ceq'Denied') 'Everyone Deny + User FullControl create 차단'
Check ((Test-AdoptionSecurityAccess $full 2).Result-ceq'Allowed') 'plain FullControl create 허용'
Check ((Test-AdoptionSecurityAccess $inheritDeny 2).Result-ceq'Denied') 'inherited Deny 차단'
Check ((Test-AdoptionSecurityAccess $unrelated 2).Result-ceq'Allowed') '관련 없는 delete Deny는 create에 영향 없음'
Check ((Test-AdoptionSecurityAccess ([byte[]]@(0,1,2)) 2).Result-ceq'Unknown') '손상 descriptor Unknown'
$noncanonical=Descriptor ('(A;;FA;;;'+$sid+')(D;;0x10056;;;WD)')
Check ((Test-AdoptionSecurityAccess $noncanonical 2).Result-ceq'Unknown') 'noncanonical descriptor Unknown'
$originalDescriptor=(Get-Item Function:Get-AdoptionDiskDescriptor).ScriptBlock
function Get-AdoptionDiskDescriptor($path,$directory){return ,$deny}
$root=Join-Path $env:TEMP ('cap31-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$file=Join-Path $root 'rom.gb'
[IO.File]::WriteAllText($file,'ROM')
$newPlan=[pscustomobject]@{Entries=@([pscustomobject]@{DropboxPath=$file;DestinationHash=''});Systems=@()}
$p=Test-AdoptionPlanCapability $newPlan
Check ($p.Result-ceq'Denied') '신규 ROM CreateFile capability'
Check ($p.MissingCapabilities-contains'CanCreateFile') 'missing capability 진단'
Check (@($p.Destinations[0].BlockingAce).Count-gt0) 'blocking ACE 진단'
$reuse=[pscustomobject]@{Entries=@([pscustomobject]@{DropboxPath=$file;DestinationHash=('a'*64)});Systems=@([pscustomobject]@{DropboxGamelist=(Join-Path $root 'gamelist.xml');SharedOutput=$null;DropboxHash='a'*64})}
Check ((Test-AdoptionPlanCapability $reuse).Allowed) '동일 SHA reuse + XML unchanged 쓰기 불필요'
$reuse.Systems[0].SharedOutput='prepared.xml'
Check (-not(Test-AdoptionPlanCapability $reuse).Allowed) '동일 SHA reuse + XML change 차단'
function Get-AdoptionDiskDescriptor($path,$directory){throw 'injected unknown ACL'}
Check ((Test-AdoptionPlanCapability $newPlan).Result-ceq'Unknown') 'ACL unknown 차단'
Set-Item Function:Get-AdoptionDiskDescriptor -Value $originalDescriptor
$minimal=Descriptor ('(A;;0x20043;;;'+$sid+')(A;OIIO;FA;;;'+$sid+')')
function Get-AdoptionDiskDescriptor($path,$directory){if($directory){return ,$minimal}else{return ,$full}}
$minimalResult=Test-AdoptionDestinationCapability (Join-Path $root 'new.gb') 'CreateRom'
Check ($minimalResult.Result-ceq'Allowed') 'parent FullControl 없이 필요한 최소권한 허용'
Check (-not$minimalResult.CanCreateDirectory) '불필요한 mkdir 권한 요구 없음'
Set-Item Function:Get-AdoptionDiskDescriptor -Value $originalDescriptor
# 실제 TEMP plan이 capability 실패하면 journal 폴더조차 생성되지 않음.
$capabilityPassed=$script:Passed
. (Join-Path $PSScriptRoot 'unregistered-adoption-executor-static.ps1')
$script:Passed=$capabilityPassed
Setup
$p=Prepare
$originalCapability=(Get-Item Function:Test-AdoptionPlanCapability).ScriptBlock
function Test-AdoptionPlanCapability($plan){[pscustomobject]@{Allowed=$false;Result='Denied';MissingCapabilities=@('CanCreateFile')}}
$blocked=$false;try{Invoke-UnregisteredAdoptionTransaction $p $Context|Out-Null}catch{$blocked=$true}
Check ($blocked -and -not(Test-Path -LiteralPath $Context.JournalRoot)) 'capability 실패 journal 생성 전 차단'
Check ($script:Remote.ContainsKey($Inbox)) 'capability 실패 inbox 유지'
$outcome=Invoke-AdoptionWithCapabilityGate $p $Context
Check (-not$outcome.Applied -and -not(Test-Path -LiteralPath $Context.JournalRoot)) 'worker gate adoption만 skip / journal 없음'
# 실제 gamelist 전송 함수가 같은 read-only source와 inbox에서 정상 완료함을 모의 ADB로 검증.
Sync-GamelistSystem $XmlPlan
Check ($script:Remote.ContainsKey($Inbox) -and $script:Remote.ContainsKey('/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml')) 'adoption 차단 후 normal gamelist verified transfer 성공'
[void][IO.Directory]::CreateDirectory($Context.JournalRoot)
[IO.File]::WriteAllText((Join-Path $Context.JournalRoot ('0'*32+'.json')),'{}')
$blocked=$false;try{Invoke-AdoptionWithCapabilityGate $p $Context|Out-Null}catch{$blocked=$true}
Check $blocked '권한 차단이 기존 손상 journal gate를 우회하지 않음'
Set-Item Function:Test-AdoptionPlanCapability -Value $originalCapability
$source=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'))
Check ($source.Contains('inbox preserved; normal sync continues')) '읽기 전용 Dropbox의 normal sync 계속 경로'
Check ($outcome.Status-ceq'Blocked' -and $outcome.Capability.Result-ceq'Denied') 'adoption mutation capability gate'
Write-Output ('capability 검증 완료: '+$script:Passed+' (executor suite 별도 통과)')