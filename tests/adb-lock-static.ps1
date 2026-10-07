# 실제 설치본/실제 ADB를 사용하지 않는 수명 주기와 디렉터리 잠금 검증.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo update-common.ps1)
. (Join-Path $repo update-transaction.ps1)
$testRoot=Join-Path $env:TEMP ('esde-adb-lock-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $testRoot App),(Join-Path $testRoot platform-tools),(Join-Path $testRoot State)|Out-Null
$script:Passed=0
function Check($Value,$Name){if(-not$Value){throw "검증 실패: $Name"};$script:Passed++;Write-Output "PASS: $Name"}
function Reject($Name,[scriptblock]$Work){$failed=$false;try{&$Work|Out-Null}catch{$failed=$true};Check $failed $Name}
$adb=Join-Path $testRoot 'platform-tools\adb.exe'
$record=Join-Path $testRoot record.txt
Add-Type -OutputAssembly $adb -OutputType ConsoleApplication -TypeDefinition @"
using System;using System.IO;using System.Threading;
public class AdbFixture { public static int Main(string[] args) {
 File.WriteAllText(Environment.GetEnvironmentVariable("ESDE_ADB_FIXTURE_RECORD"),Environment.CurrentDirectory+"|"+string.Join(" ",args));
 int wait=0;int.TryParse(Environment.GetEnvironmentVariable("ESDE_ADB_FIXTURE_DELAY"),out wait);Thread.Sleep(wait);
 return Environment.GetEnvironmentVariable("ESDE_ADB_FIXTURE_FAIL")=="1"?7:0;
}}
"@
$oldRecord=$env:ESDE_ADB_FIXTURE_RECORD;$oldFail=$env:ESDE_ADB_FIXTURE_FAIL;$oldDelay=$env:ESDE_ADB_FIXTURE_DELAY
$env:ESDE_ADB_FIXTURE_RECORD=$record;$env:ESDE_ADB_FIXTURE_FAIL='';$env:ESDE_ADB_FIXTURE_DELAY=''
$script:Mode='empty';$script:Polls=0
function Get-AdbServerProcesses {
 $script:Polls++
 if($script:Mode -eq 'stuck' -or ($script:Mode -eq 'delayed' -and $script:Polls-lt4)) {return [pscustomobject]@{ProcessId=999999;CommandLine='adb fork-server server'}}
 return @()
}
function Assert-NoAppProcesses {param($AppRoot,[switch]$IncludeGui)if($script:Mode-eq'sync'){throw 'sync worker 잔류'}}
$nativeDirectoryCheck=${function:Assert-AppDirectoryReleased}
try {
 $r=Invoke-AppAdb $adb $testRoot @('devices') 1000
 Check ($r.Code-eq0 -and ([IO.File]::ReadAllText($record)-split'\|')[0] -ieq (Join-Path $testRoot platform-tools)) 'ADB WorkingDirectory 실제 App 밖 확인'
 Reject 'App 안 ADB 실행 위치 거부' {Get-AdbWorkingDirectory (Join-Path $testRoot 'App\adb.exe') $testRoot}
 $psi=New-Object Diagnostics.ProcessStartInfo
 $psi.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
 $psi.Arguments='-NoProfile -File "'+(Join-Path $repo 'sync-worker.ps1')+'" -SourceRoot "'+$testRoot+'" -Serial MOCK -AdbPath "'+$adb+'" -StateDir "'+(Join-Path $testRoot State)+'" -AppRoot "'+$testRoot+'"'
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $worker=[Diagnostics.Process]::Start($psi)
 try {
     $out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync()
     if(-not $worker.WaitForExit(10000)){throw '테스트 sync worker 종료 시간 초과'}
     Check ($worker.ExitCode-ne0 -and ([IO.File]::ReadAllText($record)-split'\|')[0] -ieq (Join-Path $testRoot platform-tools)) '기존 Invoke-Adb 그대로 실제 worker의 App 밖 기본 WorkingDirectory 확인'
 } finally {$worker.Dispose()}
 Stop-AppAdbServer $adb $testRoot 1000
 Check ([IO.File]::ReadAllText($record).EndsWith('|kill-server')) 'kill-server 실제 테스트 실행 파일 호출/성공'
 $env:ESDE_ADB_FIXTURE_FAIL='1'
 Reject 'kill-server exit code 실패 차단' {Stop-AppAdbServer $adb $testRoot 1000}
 $env:ESDE_ADB_FIXTURE_FAIL='';$script:Mode='delayed';$script:Polls=0
 Stop-AppAdbServer $adb $testRoot 2000
 Check ($script:Polls-ge4) 'ADB 서버 종료 지연 후 제한 시간 내 성공'
 $script:Mode='stuck'
 Reject 'ADB 서버 종료 시간 초과' {Stop-AppAdbServer $adb $testRoot 200}
 $session=Join-Path $testRoot session;New-Item -ItemType Directory -Path $session|Out-Null
 [IO.File]::WriteAllText((Join-Path $testRoot 'App\keep.txt'),'original')
 Reject 'ADB 잔류 시 이동 이전 차단' {Wait-AppDirectoryReleased $testRoot $session 200;Move-UpdateDirectory (Join-Path $testRoot App) (Join-Path $testRoot moved) $testRoot}
 Check ((Test-Path (Join-Path $testRoot 'App\keep.txt')) -and -not(Test-Path (Join-Path $testRoot moved))) 'ADB 실패 시 원래 App 보존'
 $script:Mode='sync'
 Reject 'sync worker 잔류 시 ADB 종료/교체 차단' {Wait-AppDirectoryReleased $testRoot $session 200}
 $script:Mode='empty'
 $probe=Join-Path $testRoot child.ps1;$ready=Join-Path $testRoot ready;$release=Join-Path $testRoot release
 [IO.File]::WriteAllText($probe,'param($Ready,$Release);[IO.File]::WriteAllText($Ready,"ready");while(-not(Test-Path $Release)){Start-Sleep -Milliseconds 50}',(New-Object Text.UTF8Encoding($true)))
 $args='-NoProfile -File "'+$probe+'" -Ready "'+$ready+'" -Release "'+$release+'"'
 $child=Start-Process powershell.exe -WorkingDirectory (Join-Path $testRoot App) -ArgumentList $args -WindowStyle Hidden -PassThru
 try {
  $watch=[Diagnostics.Stopwatch]::StartNew();while(-not(Test-Path $ready)){if($child.HasExited -or $watch.Elapsed.TotalSeconds-gt5){throw '더미 프로세스 시작 실패'};Start-Sleep -Milliseconds 100}
  Check ((Get-AppProcessDirectory $child.Id).TrimEnd('\') -ieq (Join-Path $testRoot App)) '더미 프로세스의 실제 App CurrentDirectory 확인'
  Reject 'App CurrentDirectory 더미 프로세스가 있으면 교체 차단' {Wait-AppDirectoryReleased $testRoot $session 200;Move-UpdateDirectory (Join-Path $testRoot App) (Join-Path $testRoot moved) $testRoot}
 }finally{[IO.File]::WriteAllText($release,'release');if(-not$child.WaitForExit(5000)){throw '더미 프로세스 정상 종료 실패'}}
 Wait-AppDirectoryReleased $testRoot $session 1000
 Move-UpdateDirectory (Join-Path $testRoot App) (Join-Path $testRoot moved) $testRoot
 Check (Test-Path (Join-Path $testRoot 'moved\keep.txt')) '잠금 프로세스 정상 종료 후 실제 디렉터리 교체 성공'
 # 종료 지연 GUI 역할의 테스트 프로세스: 강제 종료 없이 기다린다.
 $delayScript=Join-Path $testRoot delay.ps1;$delayReady=Join-Path $testRoot delay-ready.txt
 [IO.File]::WriteAllText($delayScript,'param($Ready);[IO.File]::WriteAllText($Ready,"ready");Start-Sleep -Milliseconds 700')
 $delay=Start-Process powershell.exe -ArgumentList ('-NoProfile -File "'+$delayScript+'" -Ready "'+$delayReady+'"') -WindowStyle Hidden -PassThru
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while(-not(Test-Path $delayReady)){if($delay.HasExited -or $watch.Elapsed.TotalSeconds-gt5){throw '지연 프로세스 준비 실패'};Start-Sleep -Milliseconds 50}
 $identity=Get-UpdateProcess $delay.Id
 Wait-UpdateGuiExit ([pscustomobject]@{guiPid=$delay.Id;guiStartTime=$identity.startTime}) 5
 Check ($delay.WaitForExit(1000) -and -not(Get-UpdateProcess $delay.Id)) 'GUI 프로세스 종료 지연 후 실제 Exit 대기'
}finally{$env:ESDE_ADB_FIXTURE_RECORD=$oldRecord;$env:ESDE_ADB_FIXTURE_FAIL=$oldFail;$env:ESDE_ADB_FIXTURE_DELAY=$oldDelay}
Write-Output "ADB 잠금 검증 완료: $script:Passed 항목 / PowerShell $($PSVersionTable.PSVersion)"
Write-Output "임시 환경: $testRoot"
