# 실제 설치본/사용자 GUI/Android는 사용하지 않는다. 별도 테스트 Forms 프로세스만 실행한다. 파일 이동은 임시 루트에서 실제 수행한다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'update-common.ps1')
. (Join-Path $repo 'update-transaction.ps1')
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('esde-transaction-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$script:Passed=0; $script:Fault=''; $script:FakeId=100000; $script:FakeProcesses=@{}; $script:Launches=0
$nativeWindows=${function:Get-GuiWindows}; $nativeMove=${function:Move-UpdateDirectory}; $nativeProcess=${function:Get-UpdateProcess}
function Check($value,[string]$name) { if(-not $value){throw "검증 실패: $name"}; $script:Passed++; Write-Output "PASS: $name" }
function Reject([string]$name,[scriptblock]$Work) { $blocked=$false; try { & $Work | Out-Null } catch {$blocked=$true}; Check $blocked $name }
function Assert-NoAppProcesses { param($AppRoot,[switch]$IncludeGui) if($script:Fault -eq 'sync-running'){throw '모의 sync worker 실행 중'} }
function Wait-AppDirectoryReleased { param($AppRoot,$SessionPath) Assert-NoAppProcesses $AppRoot -IncludeGui }
function Get-AdbServerProcesses { return @() } # 실제 설치본의 ADB는 테스트에서 조회/종료하지 않는다.
function Get-UpdateProcess([int]$ProcessId) {
    if($script:FakeProcesses.ContainsKey($ProcessId)){return $script:FakeProcesses[$ProcessId]}
    return (& $nativeProcess $ProcessId)
}
function Get-GuiWindows([int]$ProcessId) {
    if (-not $script:FakeProcesses.ContainsKey($ProcessId)) { return (& $nativeWindows $ProcessId) }
    if ($script:Fault -eq 'no-window') { return }
    $owner=$ProcessId; $visible=$true; $title='ES-DE Sync v1.4.9'
    if ($script:Fault -eq 'wrong-window-pid') { $owner++ }
    if ($script:Fault -eq 'hidden-window') { $visible=$false }
    if ($script:Fault -eq 'wrong-title') { $title='unexpected' }
    # 롤백 창은 이전 버전 제목을 사용한다.
    if ($script:FakeProcesses[$ProcessId].PSObject.Properties['version']) { $title='ES-DE Sync v'+$script:FakeProcesses[$ProcessId].version }
    return [pscustomobject]@{Pid=$owner;Handle=123;Visible=$visible;Title=$title}
}
function Stop-UpdateGui($State) { if($State.newGuiPid -gt 0){$script:FakeProcesses.Remove([int]$State.newGuiPid)} }
function Start-UpdateGui { param($AppRoot,$SessionPath,$Version,[switch]$Rollback)
    $script:Launches++
    if(-not $Rollback -and $script:Fault -eq 'launch'){throw '모의 새 GUI 실행 실패'}
    if($Rollback -and $script:Fault -eq 'rollback-launch'){throw '모의 이전 GUI 실행 실패'}
    $script:FakeId++
    $process=[pscustomobject]@{pid=$script:FakeId;startTime=(Get-Date).ToUniversalTime().ToString('o');confirmation=(Test-GuiConfirmationSupport (Join-Path $AppRoot 'App\ESDE-Sync.ps1'))}
    if ($Rollback) { $script:Fault=''; $process | Add-Member version $Version }
    $script:FakeProcesses[$process.pid]=$process
    if(-not $Rollback -and $script:Fault -eq 'exit'){ $script:FakeProcesses.Remove($process.pid); return $process }
    if($process.confirmation -and ($Rollback -or $script:Fault -ne 'no-confirmation')) {
        $sessionId=Split-Path $SessionPath -Leaf
        $confirmedVersion=$Version
        if(-not $Rollback -and $script:Fault -eq 'wrong-session'){$sessionId='wrong'}
        if(-not $Rollback -and $script:Fault -eq 'wrong-version'){$confirmedVersion='9.9.9'}
        $confirmedPid=$process.pid; $confirmedStart=$process.startTime
        if(-not $Rollback -and $script:Fault -eq 'wrong-pid'){$confirmedPid++}
        if(-not $Rollback -and $script:Fault -eq 'wrong-start'){$confirmedStart='wrong'}
        $file=if($Rollback){'rollback-confirmation.json'}else{'startup-confirmation.json'}
        Write-UpdateJson (Join-Path $SessionPath $file) @{sessionId=$sessionId;version=$confirmedVersion;pid=$confirmedPid;processStartTime=$confirmedStart;confirmedAt=(Get-Date).ToUniversalTime().ToString('o')}
    }
    return $process
}
function Move-UpdateDirectory([string]$Source,[string]$Destination,[string]$AppRoot) {
    if($script:Fault -eq 'backup' -and $Destination.EndsWith('backup\App')){throw '모의 백업 이동 실패'}
    if($script:Fault -in @('staged','rollback','rollback-launch') -and $Source.EndsWith('staged\App')){throw '모의 staged 이동 실패'}
    if($script:Fault -eq 'rollback' -and $Source -match '\\restore-[a-f0-9]+\\App$'){throw '모의 복원 이동 실패'}
    & $nativeMove $Source $Destination $AppRoot
    if($script:Fault -eq 'post-missing' -and $Source.EndsWith('staged\App')){Remove-Item -LiteralPath (Join-Path $Destination 'update-worker.ps1')}
}
$target=Get-AppVersion (Join-Path $repo 'version.json'); $target.version='1.4.9'; $target.releaseTag='v1.4.9'
$payload=Join-Path $sandbox 'payload'
New-Item -ItemType Directory -Path $payload | Out-Null
foreach($path in Get-PackageFiles | Where-Object {$_.StartsWith('App/')}){Copy-Item -LiteralPath (Join-Path $repo $path.Substring(4)) -Destination $payload}
Write-UpdateJson (Join-Path $payload 'version.json') $target
$stub='param($InstallRoot,$UpdateSession,$UpdateSessionId,$ConfirmationFile) # GUI를 실행하지 않는 fixture'
[IO.File]::WriteAllText((Join-Path $payload 'ESDE-Sync.ps1'),$stub,(New-Object Text.UTF8Encoding($true)))
function New-Fixture([string]$Name,[switch]$Legacy,[switch]$Fresh) {
    $root=Join-Path $sandbox ($Name+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root,(Join-Path $root 'State'),(Join-Path $root 'platform-tools') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'State\keep.txt'),'state-marker')
    [IO.File]::WriteAllText((Join-Path $root 'config.json'),'config-marker')
    [IO.File]::WriteAllText((Join-Path $root 'platform-tools\adb.exe'),'adb-marker')
    if(-not $Fresh) {
        New-Item -ItemType Directory -Path (Join-Path $root 'App') | Out-Null
        if($Legacy){[IO.File]::WriteAllText((Join-Path $root 'App\ESDE-Sync.ps1'),'$form.Text = "ES-DE Sync v1.4.7"')}
        else {
            [IO.File]::WriteAllText((Join-Path $root 'App\ESDE-Sync.ps1'),$stub)
            $old=Get-AppVersion (Join-Path $repo 'version.json')
            Write-UpdateJson (Join-Path $root 'App\version.json') $old
        }
        [IO.File]::WriteAllText((Join-Path $root 'App\old-data.txt'),'old-app-marker')
    }
    $oldSnapshot=if($Fresh){@()}else{@(Get-AppSnapshot (Join-Path $root 'App') $root)}
    $session=New-LocalUpdateSession $root $payload $target
    return [pscustomobject]@{Root=$root;Session=$session;Original=$oldSnapshot;Legacy=[bool]$Legacy}
}
function Check-Preserved($Fixture) {
    Check ([IO.File]::ReadAllText((Join-Path $Fixture.Root 'State\keep.txt')) -ceq 'state-marker') 'State 보존'
    Check ([IO.File]::ReadAllText((Join-Path $Fixture.Root 'config.json')) -ceq 'config-marker') 'config.json 보존'
    Check ([IO.File]::ReadAllText((Join-Path $Fixture.Root 'platform-tools\adb.exe')) -ceq 'adb-marker') 'platform-tools 보존'
}
$f=New-Fixture 'success'
$script:Fault=''; $result=Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0
Check ($result.state -eq 'completed') '정상 App 디렉터리 교체'
Check ((Get-AppVersion (Join-Path $f.Root 'App\version.json')).version -eq '1.4.9') '대상 버전 설치'
Assert-AppSnapshot (Join-Path $f.Session 'backup\App') $f.Original $f.Root
Check (Test-Path (Join-Path $f.Session 'backup\App')) '성공 후 원본 백업 유지'
Check-Preserved $f
$launchCount=$script:Launches; $result=Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0
Check ($result.state -eq 'completed' -and $script:Launches -eq $launchCount) 'completed 재실행은 중복 적용하지 않음'
foreach($fault in @('missing','locked','backup','staged','launch','no-confirmation','wrong-session','wrong-version','wrong-pid','wrong-start','exit','post-missing','sync-running','target-mismatch','gui-exit','no-window','hidden-window','wrong-window-pid','wrong-title')) {
    $f=New-Fixture $fault; $script:Fault=$fault; $lock=$null
    if($fault -eq 'missing'){Remove-Item -LiteralPath (Join-Path $f.Session 'staged\App\update-worker.ps1')}
    # 읽기는 허용하지만 삭제 공유를 거부하여 실제 Directory.Move 실패를 재현한다.
    if($fault -eq 'locked'){$lock=[IO.File]::Open((Join-Path $f.Root 'App\old-data.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)}
    if($fault -in @('target-mismatch','gui-exit')) {
        $s=Read-UpdateJson (Join-Path $f.Session 'state.json')
        if($fault -eq 'target-mismatch'){$s.targetVersion='1.4.10'}
        else {$s.guiPid=$PID; $s.guiStartTime=(& $nativeProcess $PID).startTime}
        Write-UpdateJson (Join-Path $f.Session 'state.json') $s
    }
    try {$result=Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0} finally {if($lock){$lock.Dispose()}}
    Check ($result.state -eq 'failed' -and $result.originalError) ($fault+' 실패 기록/원본 복구')
    if ($fault -in @('no-window','hidden-window','wrong-window-pid','wrong-title')) {
        Check ($result.originalError -match '가시적인 메인 창' -and $result.rollbackGuiPid -gt 0 -and -not $result.rollbackError) ($fault+' 시작 실패 후 이전 GUI 재실행/롤백 성공')
    }
    Assert-AppSnapshot (Join-Path $f.Root 'App') $f.Original $f.Root
    Check-Preserved $f
}
foreach($fault in @('rollback','rollback-launch')) {
    $f=New-Fixture $fault; $script:Fault=$fault
    $result=Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0
    Check ($result.state -eq 'rollback_failed' -and $result.originalError -and $result.rollbackError) ($fault+' 실패 분리 기록')
    Assert-AppSnapshot (Join-Path $f.Session 'backup\App') $f.Original $f.Root
    Check (Test-Path (Join-Path $f.Session 'backup\App')) 'rollback_failed에도 원본 백업 유지'
    Check ([bool](Get-PendingUpdate $f.Root)) '복구 실패 상태에서 다음 작업 차단'
    $script:Fault=''
    $result=Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0
    Check ($result.state -eq 'failed') 'rollback_failed 세션 재실행 복구'
    Assert-AppSnapshot (Join-Path $f.Root 'App') $f.Original $f.Root
}
foreach($phase in @('backing_up','replacing','launching')) {
    $f=New-Fixture ('interrupted-'+$phase); $script:Fault=''
    $s=Read-UpdateJson (Join-Path $f.Session 'state.json'); $s.sourceFiles=$f.Original
    if($phase -ne 'backing_up') { & $nativeMove (Join-Path $f.Root 'App') (Join-Path $f.Session 'backup\App') $f.Root }
    if($phase -eq 'launching') { & $nativeMove (Join-Path $f.Session 'staged\App') (Join-Path $f.Root 'App') $f.Root }
    Set-UpdateState $f.Session $s $phase
    $result=Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0
    Check ($result.state -eq 'failed') ($phase+' 중단 세션의 보수적 롤백')
    Assert-AppSnapshot (Join-Path $f.Root 'App') $f.Original $f.Root
}
$f=New-Fixture 'legacy' -Legacy; $script:Fault='launch'
$result=Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0
Check ($result.state -eq 'failed' -and $result.sourceVersion -eq '1.4.7') 'v1.4.7 최초 업그레이드 실패 복원/이전 GUI 호환'
Assert-AppSnapshot (Join-Path $f.Root 'App') $f.Original $f.Root
$f=New-Fixture 'fresh' -Fresh; $script:Fault=''
Check ((Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0).state -eq 'completed') '새 설치 루트의 정상 적용'

# 진짜 별도 프로세스로 mutex의 재진입/스레드 특성과 관계없이 충돌을 검증한다.
$probe=Join-Path $sandbox 'mutex-probe.ps1'
$probeText=@'
param($Root,$Kind,$Common,$Transaction,$Ready,$Release)
$ErrorActionPreference='Stop'
. $Common
. $Transaction
$lock=$null
try {
    $lock=Enter-AppMutex $Root $Kind
    if($Ready){[IO.File]::WriteAllText($Ready,'ready');while(-not(Test-Path $Release)){Start-Sleep -Milliseconds 50}}
    exit 0
}
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
finally { Exit-AppMutex $lock }
'@
[IO.File]::WriteAllText($probe,$probeText,(New-Object Text.UTF8Encoding($true)))
function Run-Child([string]$ScriptPath,[string[]]$Arguments) {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$ScriptPath+'" '+(@($Arguments|ForEach-Object{'"'+$_+'"'}) -join ' ')
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.Encoding]::Default; $psi.StandardErrorEncoding=[Text.Encoding]::Default
    $p=[Diagnostics.Process]::Start($psi);$stdout=$p.StandardOutput.ReadToEnd();$stderr=$p.StandardError.ReadToEnd();$p.WaitForExit()
    return [pscustomobject]@{Code=$p.ExitCode;Output=($stdout+$stderr)}
}
$common=Join-Path $repo 'update-common.ps1'; $transaction=Join-Path $repo 'update-transaction.ps1'
$f=New-Fixture 'mutex'; $script:Fault=''
Check ((Get-AppMutexName $f.Root 'gui').StartsWith('Global\')) '로그온 세션 공통 mutex 이름'
Check ((Get-AppMutexName $f.Root 'operation') -ceq (Get-AppMutexName $f.Root.ToUpperInvariant() 'operation')) '설치 루트 대소문자와 관계없는 mutex 이름'
foreach($kind in @('gui','operation',('session-'+(Split-Path $f.Session -Leaf)))) {
    $held=Enter-AppMutex $f.Root $kind
    try {$child=Run-Child $probe @($f.Root,$kind,$common,$transaction)} finally {Exit-AppMutex $held}
    Check ($child.Code -eq 2) ($kind+' 중복 실행 차단(별도 프로세스)')
}
$ready=Join-Path $sandbox 'operation-ready.txt';$release=Join-Path $sandbox 'operation-release.txt'
$arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$probe+'" '+(@($f.Root,'operation',$common,$transaction,$ready,$release)|ForEach-Object{ '"'+$_+'"' }) -join ' '
$holder=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
try {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not(Test-Path $ready)) {if($holder.HasExited -or $watch.Elapsed.TotalSeconds -gt 5){throw 'mutex holder 시작 실패'};Start-Sleep -Milliseconds 50}
    Reject 'sync 실행 중 update 차단' {Invoke-UpdateTransaction $f.Root $f.Session -TimeoutSeconds 0}
    $sync=Run-Child (Join-Path $repo 'sync-worker.ps1') @('-SourceRoot',(Join-Path $sandbox 'unused-source'),'-Serial','MOCK','-AdbPath',(Join-Path $sandbox 'no-adb.exe'),'-StateDir',(Join-Path $f.Root 'State'),'-AppRoot',$f.Root)
    Check ($sync.Code -ne 0 -and $sync.Output -match 'operation') 'update 중 실제 sync 진입점 차단(ADB 없음)'
    Check (-not(Test-Path (Join-Path $f.Root 'State\sync.log'))) 'mutex 차단 시 sync 상태/로그에 쓰지 않음'
} finally {[IO.File]::WriteAllText($release,'release');if(-not $holder.WaitForExit(5000)){Stop-Process -Id $holder.Id}}
$held=Enter-AppMutex $f.Root ('session-'+(Split-Path $f.Session -Leaf))
try {
    $child=Run-Child (Join-Path $f.Session 'update-worker.ps1') @('-AppRoot',$f.Root,'-SessionPath',$f.Session)
} finally {Exit-AppMutex $held}
Check ($child.Code -ne 0) '실제 update-worker 중복 실행 차단'
Check ((Read-UpdateJson (Join-Path $f.Session 'state.json')).state -eq 'verified') '중복 worker가 기존 세션 상태를 바꾸지 않음'

# 임시 설치본과 테스트 Forms를 사용하는 실행기/시작 확인 통합 검증. 실제 ADB는 없다.
$nativePayload=Join-Path $sandbox 'native-payload'
Copy-Item -LiteralPath $payload -Destination $nativePayload -Recurse
# 이 통합 fixture의 adb.exe는 기존 데이터 보존용 텍스트이다. ADB 종료는 별도 잠금 테스트로 검증한다.
[IO.File]::AppendAllText((Join-Path $nativePayload 'update-common.ps1'), "`nfunction Stop-AppAdbServer { param(`$AdbPath,`$AppRoot,`$TimeoutMilliseconds,`$Log) }`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::AppendAllText((Join-Path $nativePayload 'update-common.ps1'), "`nfunction Get-AdbServerProcesses { return @() }`n", (New-Object Text.UTF8Encoding($false)))
$dummyGui=@'
param($InstallRoot,$UpdateSession,$UpdateSessionId,$ConfirmationFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'update-common.ps1')
. (Join-Path $PSScriptRoot 'update-transaction.ps1')
$gui=Enter-AppMutex $InstallRoot 'gui'
try {
    Add-Type -AssemblyName System.Windows.Forms
    $form=New-Object Windows.Forms.Form
    $form.Text='ES-DE Sync v'+(Get-AppVersion (Join-Path $PSScriptRoot 'version.json')).version
    $form.Add_Shown({ Write-GuiConfirmation $UpdateSession $InstallRoot $UpdateSessionId (Get-AppVersion (Join-Path $PSScriptRoot 'version.json')).version $ConfirmationFile })
    [void]$form.ShowDialog()
}
finally { Exit-AppMutex $gui }
'@
[IO.File]::WriteAllText((Join-Path $nativePayload 'ESDE-Sync.ps1'),$dummyGui,(New-Object Text.UTF8Encoding($true)))
$f=New-Fixture 'native-worker'
# 초기 준비 세션은 아직 App에 적용하지 않았으므로 안전하게 취소 상태를 기록한다.
$cancel=Read-UpdateJson (Join-Path $f.Session 'state.json'); Set-UpdateState $f.Session $cancel 'failed'
$nativeSession=New-LocalUpdateSession $f.Root $nativePayload $target
[IO.File]::AppendAllText((Join-Path $nativeSession 'update-common.ps1'), "`nfunction Stop-AppAdbServer { param(`$AdbPath,`$AppRoot,`$TimeoutMilliseconds,`$Log) }`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::AppendAllText((Join-Path $nativeSession 'update-common.ps1'), "`nfunction Get-AdbServerProcesses { return @() }`n", (New-Object Text.UTF8Encoding($false)))
$child=Run-Child (Join-Path $nativeSession 'update-worker.ps1') @('-AppRoot',$f.Root,'-SessionPath',$nativeSession)
$nativeState=Read-UpdateJson (Join-Path $nativeSession 'state.json')
try {
    Check ($child.Code -eq 0 -and $nativeState.state -eq 'completed') ('실제 update-worker와 더미 GUI 시작 확인: '+$child.Output)
    $confirmed=Read-UpdateJson (Join-Path $nativeSession 'startup-confirmation.json')
    Check ($confirmed.pid -eq $nativeState.newGuiPid -and $confirmed.version -eq '1.4.9') '실제 PID/버전 시작 확인'
    $duplicateGui=Run-Child $probe @($f.Root,'gui',$common,$transaction)
    Check ($duplicateGui.Code -eq 2) '더미 GUI 실행 중 GUI mutex 확인'
    Check-Preserved $f
}
finally {if($nativeState.newGuiPid -gt 0 -and (& $nativeProcess $nativeState.newGuiPid).startTime -ceq $nativeState.newGuiStartTime){Stop-Process -Id $nativeState.newGuiPid}}
$syncFailure=Run-Child (Join-Path $repo 'sync-worker.ps1') @('-SourceRoot',(Join-Path $sandbox 'unused-source'),'-Serial','MOCK','-AdbPath',(Join-Path $sandbox 'no-adb.exe'),'-StateDir',(Join-Path $f.Root 'State'),'-AppRoot',$f.Root)
$releasedOperation=Run-Child $probe @($f.Root,'operation',$common,$transaction)
Check ($syncFailure.Code -ne 0 -and $releasedOperation.Code -eq 0) '실제 sync 오류 종료 후 operation mutex 해제(ADB 없음)'

$manualRoot=Join-Path $sandbox 'manual-install'
New-Item -ItemType Directory -Path (Join-Path $manualRoot 'App'),(Join-Path $manualRoot 'State'),(Join-Path $manualRoot 'platform-tools') | Out-Null
[IO.File]::WriteAllText((Join-Path $manualRoot 'App\ESDE-Sync.ps1'),'$form.Text = "ES-DE Sync v1.4.7"')
[IO.File]::WriteAllText((Join-Path $manualRoot 'config.json'),'config-marker')
[IO.File]::WriteAllText((Join-Path $manualRoot 'State\keep.txt'),'state-marker')
[IO.File]::WriteAllText((Join-Path $manualRoot 'platform-tools\adb.exe'),'adb-marker')
$manualSource=Join-Path $sandbox 'manual-package'; New-Item -ItemType Directory -Path $manualSource | Out-Null
Copy-Item -LiteralPath $nativePayload -Destination (Join-Path $manualSource 'App') -Recurse
Write-UpdateJson (Join-Path $manualSource 'App\version.json') (Get-AppVersion (Join-Path $repo 'version.json'))
Copy-Item -LiteralPath (Join-Path $repo 'install.ps1') -Destination $manualSource
$child=Run-Child (Join-Path $manualSource 'install.ps1') @('-InstallRoot',$manualRoot,'-SkipShortcuts','-SkipPlatformTools')
$manualStatePath=@(Get-ChildItem (Join-Path $manualRoot '.Updates') -Recurse -Filter state.json)[0].FullName
$manualState=Read-UpdateJson $manualStatePath
try {
    Check ($child.Code -eq 0 -and $manualState.state -eq 'completed' -and $manualState.sourceVersion -eq '1.4.7') ('실제 install.ps1 최초 업그레이드(더미 GUI): '+$child.Output)
    Check-Preserved ([pscustomobject]@{Root=$manualRoot})
    Check (Test-Path (Join-Path (Split-Path $manualStatePath -Parent) 'backup\App')) '수동 설치의 v1.4.7 백업 유지'
}
finally {if($manualState.newGuiPid -gt 0 -and (& $nativeProcess $manualState.newGuiPid).startTime -ceq $manualState.newGuiStartTime){Stop-Process -Id $manualState.newGuiPid}}

# 검증 ZIP -> 세션 staged App -> 트랜잭션까지 연결한다.
$f=New-Fixture 'package-session'; $script:Fault=''
$cancel=Read-UpdateJson (Join-Path $f.Session 'state.json'); Set-UpdateState $f.Session $cancel 'failed'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath=Join-Path $f.Root '.Updates\verified.zip'
$zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
$records=@()
try {
    foreach($path in Get-PackageFiles) {
        if($path.StartsWith('App/')){$bytes=[IO.File]::ReadAllBytes((Join-Path $payload $path.Substring(4)))}
        else {$bytes=[IO.File]::ReadAllBytes((Join-Path $repo $path))}
        if($path -eq 'README.txt'){$bytes=[Text.Encoding]::UTF8.GetBytes('ES-DE Sync for Android v1.4.9 Development')}
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$digest=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
        $records+=[pscustomobject]@{path=$path;size=$bytes.Length;sha256=$digest}
        $entry=$zip.CreateEntry($path);$stream=$entry.Open()
        try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes((@{schemaVersion=1;version='1.4.9';files=$records}|ConvertTo-Json -Depth 5))
    $stream=$zip.CreateEntry('package-manifest.json').Open()
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
}finally{$zip.Dispose()}
$verified=[pscustomobject]@{Verified=$true;Version='1.4.9';ZipPath=$zipPath;Sha256=(Get-FileHash $zipPath).Hash}
$current=Get-AppVersion (Join-Path $repo 'version.json')
$session=New-PackageUpdateSession $f.Root $verified $current 0 ''
Check ((Read-UpdateJson (Join-Path $session 'state.json')).state -eq 'verified') '검증 ZIP의 staged 세션 준비'
Check ((Get-FileHash (Join-Path $session 'package.zip')).Hash -eq $verified.Sha256) '세션 ZIP/checksum 보존'
Check ((Invoke-UpdateTransaction $f.Root $session -TimeoutSeconds 0).state -eq 'completed') 'ZIP 검증부터 App 적용 연결'
$verified.Sha256='0'*64
Reject '설치 직전 변경된 ZIP 해시 차단' {New-PackageUpdateSession $f.Root $verified $current 0 ''}

# 기존 미정의 AdbExe 참조 대신 실제 GUI의 선택된 ADB 경로를 사용하는지 확인한다.
# 실제 adb.exe는 사용하지 않고 인수만 기록하는 로컬 실행 파일을 만든다.
$fakeAdb=Join-Path $sandbox 'fake-adb.exe';$recordPath=Join-Path $sandbox 'fake-adb-args.txt'
Add-Type -OutputAssembly $fakeAdb -OutputType ConsoleApplication -TypeDefinition 'public class EsdeAdbProbe { public static void Main(string[] args) { System.IO.File.WriteAllText(System.Environment.GetEnvironmentVariable("ESDE_TEST_ADB_ARGUMENTS"), string.Join(" ",args)); } }'
$oldEnv=$env:ESDE_TEST_ADB_ARGUMENTS; $env:ESDE_TEST_ADB_ARGUMENTS=$recordPath
$tokens=$null;$errors=$null;$guiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$tokens,[ref]$errors)
$stopFn=$guiAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-AdbServer'},$false)
. ([scriptblock]::Create($stopFn.Extent.Text))
$oldAdb=$script:Adb; $script:Adb=$fakeAdb
$AppRoot=$f.Root; $StateDir=Join-Path $f.Root 'State'
try {Stop-AdbServer;Check ([IO.File]::ReadAllText($recordPath) -ceq 'kill-server') 'GUI 종료 ADB 경로/kill-server 인수(가짜 실행 파일)'}
finally {$script:Adb=$oldAdb;$env:ESDE_TEST_ADB_ARGUMENTS=$oldEnv}
# 실제 Windows API로 별도 테스트 Forms 프로세스의 창 상태를 확인한다.
$windowProbe=Join-Path $sandbox 'window-probe.ps1'
$probeSource=@'
param($Mode,$Ready,$Transaction)
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text=if($Mode -eq 'wrong-title'){'wrong title'}else{'ES-DE Sync v1.4.8'}
if($Mode -eq 'no-window') {
    [IO.File]::WriteAllText($Ready,'ready')
    while($true){Start-Sleep -Milliseconds 100}
}
if($Mode -eq 'hidden') {
    [void]$form.Handle
    [IO.File]::WriteAllText($Ready,'ready')
    [Windows.Forms.Application]::Run()
} else {
    $form.Add_Shown({
        if($Mode -eq 'launch-hidden-fixed'){
            . $Transaction
            Initialize-GuiWindowApi
            $console=[EsdeSync.WindowApi]::GetConsoleWindow()
            if($console -ne [IntPtr]::Zero){[void][EsdeSync.WindowApi]::ShowWindow($console,0)}
            [void][EsdeSync.WindowApi]::ShowWindow($form.Handle,5)
        }
        [IO.File]::WriteAllText($Ready,'ready')
    })
    [void]$form.ShowDialog()
}
'@
[IO.File]::WriteAllText($windowProbe,$probeSource,(New-Object Text.UTF8Encoding($true)))
foreach($mode in @('visible','hidden','no-window','wrong-title','launch-hidden','launch-hidden-fixed')) {
    $readyFile=Join-Path $sandbox ('window-'+$mode+'.ready')
    $arguments='-NoProfile -File "'+$windowProbe+'" -Mode '+$mode+' -Ready "'+$readyFile+'" -Transaction "'+$transaction+'"'
    $style=if($mode -in @('launch-hidden','launch-hidden-fixed')){'Hidden'}else{'Normal'}
    $probeProcess=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle $style -PassThru
    try {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while(-not(Test-Path $readyFile)){if($probeProcess.HasExited -or $watch.Elapsed.TotalSeconds -gt 10){throw '창 probe 시작 실패'};Start-Sleep -Milliseconds 100}
        $windows=@(& $nativeWindows $probeProcess.Id)
        $visible=Test-VisibleGuiWindow $probeProcess.Id '1.4.8'
        Check ($visible -eq ($mode -in @('visible','launch-hidden-fixed'))) ('실제 EnumWindows/IsWindowVisible: '+$mode)
        if($mode -in @('hidden','launch-hidden')){Check (@($windows|Where-Object {$_.Title -ceq 'ES-DE Sync v1.4.8' -and -not $_.Visible}).Count -eq 1) '실제 숨김 메인 창 존재 확인'}
    }
    finally {if(-not $probeProcess.HasExited){Stop-Process -Id $probeProcess.Id}}
}
Write-Output ("트랜잭션 검증 완료: $script:Passed 항목 / PowerShell "+$PSVersionTable.PSVersion)
Write-Output "임시 설치 루트: $sandbox"
