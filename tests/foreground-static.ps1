# 함수 정의만 로드한다. 실제 ADB/worker 본문/설치본은 실행하지 않는다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($node.Extent.Text))}
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function New-Evidence([hashtable]$Overrides=@{},[string]$Package='org.es_de.frontend'){
 $data=@{
 power='mWakefulness=Awake'
 activities="isSleeping=false`ntopResumedActivity=ActivityRecord{123 $Package/.Main u0}"
 activityTop="ACTIVITY $Package/.Main`n  mResumed=true"
 windows="mCurrentFocus=Window{123 $Package/.Main}`nmFocusedApp=ActivityRecord{123 $Package/.Main}"
 displays=''
 policy="screenState=SCREEN_STATE_ON`nshowing=false`nmIsShowing=false"
 input="DispatchEnabled: true`nDispatchFrozen: false`nFocusedApplications:`n  displayId=0, name='ActivityRecord{123 $Package/.Main}'`nFocusedWindows:`n  displayId=0, name='123 $Package/.Main'"
 home="$Package/.Main"
 }
 foreach($key in $Overrides.Keys){$data[$key]=$Overrides[$key]}
 $commands=@(foreach($key in @('power','activities','activityTop','windows','displays','policy','input','home')){[pscustomobject]@{source=$key;code=0;text=$data[$key];error='';command=$key}})
 ConvertTo-AndroidForegroundEvidence $commands
}
function Expect($evidence,$status,$name){$result=Evaluate-AndroidForegroundSafety $evidence;Check ($result.status-ceq$status -and $result.allowed-eq($status-eq'safe')) $name}
Expect (New-Evidence) 'safe' 'ES-DE activity/window/input 합의'
Expect (New-Evidence @{windows='mCurrentFocus=Window{123 com.retroarch/.Main}'}) 'unsafe' 'stale ES-DE activity + 게임 window'
Expect (New-Evidence @{input="focusedApplication=org.es_de.frontend/.Main`nfocusedWindow=com.retroarch/.Main"}) 'unsafe' '게임 input focus'
Expect (New-Evidence @{activities="isSleeping=false`nmResumedActivity: ActivityRecord{123 com.retroarch/.Main}"}) 'unsafe' '게임 activity + ES-DE window'
Expect (New-Evidence @{} 'com.vendor.launcher') 'safe' 'HOME 다중 신호 합의'
Expect (New-Evidence @{home='com.vendor.launcher/.Home'} 'com.vendor.launcher') 'unknown' 'HOME 같은 패키지라도 다른 activity는 차단'
Check ((Get-AndroidComponent 'ActivityRecord{1 com.vendor.launcher/.Home}')-ceq'com.vendor.launcher/com.vendor.launcher.Home') 'HOME component 정규화'
Expect (New-Evidence @{windows='mCurrentFocus=com.game_2/.Activity'}) 'unsafe' 'ES-DE HOME 설정으로 게임 window를 허용하지 않음'
Expect (New-Evidence @{windows='';input=''}) 'unknown' 'activity만 있을 때 차단'
Expect (New-Evidence @{activities='isSleeping=false';activityTop=''}) 'unknown' 'window만 있을 때 차단'
Expect (New-Evidence @{windows='mCurrentFocus=com.vendor.launcher/.Main';home='com.vendor.launcher/.Main'}) 'unknown' 'launcher 사이 불일치도 차단'
$failed=New-Evidence;$failed.failures=@([pscustomobject]@{source='input';code=1;error='denied'})
Expect $failed 'unknown' 'dumpsys 실패'
Expect (New-Evidence @{activities="isSleeping=true`ntopResumedActivity=org.es_de.frontend/.Main"}) 'unsafe' 'sleeping 차단'
Expect (New-Evidence @{power='mWakefulness=Dozing'}) 'unsafe' 'Dozing 차단'
Expect (New-Evidence @{windows='mCurrentFocus=Window{123 com.android.systemui/NotificationShade}'}) 'unknown' 'NotificationShade 보수적 차단'
foreach($value in @('org.es_de.frontend/.Main','org.es_de.frontend/full.Main','Window{12 u0 org.es_de.frontend/org.es_de.frontend.Main}','mResumedActivity: ActivityRecord{12 org.es_de.frontend/.Main}')){Check ((Get-PackageFromComponent $value)-ceq'org.es_de.frontend') ('component 파싱: '+$value)}
Check ((Get-PackageFromComponent 'com.vendor_2.game3/.Main_4')-ceq'com.vendor_2.game3') '숫자/underscore 패키지'
Check (-not(Get-PackageFromComponent 'com.one/.A com.two/.B')) '모호한 component 거부'
Check (-not(Get-PackageFromComponent '/storage/emulated/0')) '파일 경로 오인 방지'
$base=New-Evidence;$input=$base.commands|Where-Object source -eq input
Expect (New-Evidence @{input=($input.text+"`nInput Dispatcher State at time of last ANR:`nFocusedWindows:`n  name='com.retroarch/.Main'")}) 'safe' '과거 ANR focus 제외'
Expect (New-Evidence @{input=($input.text+"`nFocusRequests:`n  window=com.retroarch/.Main")}) 'safe' '과거 focus request 제외'
Expect (New-Evidence @{activityTop="ACTIVITY com.retroarch/.Main`n  mResumed=false`n    mResumed=true`nACTIVITY org.es_de.frontend/.Main`n  mResumed=true"}) 'safe' 'background activity/fragment 제외'
Expect (New-Evidence @{activityTop="ACTIVITY com.retroarch/.Main`n mResumed=true"}) 'unsafe' 'active activity top 게임 차단'
$overlay=$input.text+"`nWindows:`n  0: name='com.retroarch/.Overlay', inputConfig=0x0, alpha=1,`n  1: name='org.es_de.frontend/.Main', inputConfig=0x0, alpha=1,"
Expect (New-Evidence @{input=$overlay}) 'unsafe' 'touchable 게임 overlay 차단'
$nonTouch=$input.text+"`nWindows:`n  0: name='com.vendor.assistant/.Overlay', inputConfig=NOT_TOUCHABLE, alpha=1,`n  1: name='org.es_de.frontend/.Main', inputConfig=0x0, alpha=1,"
Expect (New-Evidence @{input=$nonTouch}) 'safe' '비입력 vendor overlay 무시'
Expect (New-Evidence @{input=$input.text.Replace('DispatchFrozen: false','DispatchFrozen: true')}) 'unknown' 'dispatch frozen'
Expect (New-Evidence @{policy="screenState=SCREEN_STATE_ON`nshowing=true"}) 'unsafe' 'keyguard 차단'
Expect (New-Evidence @{power=''}) 'unknown' '전원 불명 차단'
Expect (New-Evidence @{windows='mCurrentFocus=null'}) 'unknown' 'focus 파싱 실패 차단'
Expect (New-Evidence @{displays='mCurrentFocus=com.game/.Main'}) 'unsafe' 'window displays 추가 증거'
$script:AdbCalls=@()
function Invoke-Adb {
    $script:AdbCalls+=($args-join' ')
    return [pscustomobject]@{Code=1;StdOut='';StdErr='mock denied';Output=@()}
}
$collected=Get-AndroidForegroundEvidence
Check ($collected.failures.Count-eq8 -and $script:AdbCalls.Count-eq8) '모든 수집 명령의 실패 기록'
Expect $collected 'unknown' 'collector 실패를 빈 안전 정보로 취급하지 않음'
$script:Messages=@();function Write-Log($Message){$script:Messages+=$Message};function Write-Status{}
$script:Samples=@((New-Evidence),(New-Evidence));$script:Index=0
function Get-AndroidForegroundEvidence{return $script:Samples[$script:Index++]}
Preflight-CheckForeground
Check ($script:Index-eq2 -and ($script:Messages-join' ')-match'PREFLIGHT OK') '두 안전 표본만 통과'
$script:Samples=@((New-Evidence),(New-Evidence @{} 'com.vendor.launcher'));$script:Index=0;$blocked=$false
try{Preflight-CheckForeground}catch{$blocked=$true}
Check $blocked '표본 사이 launcher 변경 차단'
$script:Samples=@((New-Evidence @{input=''}));$script:Index=0;$blocked=$false
try{Preflight-CheckForeground}catch{$blocked=$true}
Check ($blocked -and $script:Index-eq1) '첫 unknown 즉시 차단'
Check (($script:Messages-join' ')-match'POWER:.*HOME:.*DECISION:') '진단 로그와 이유'
Write-Output ('TOTAL PASS: '+$script:Passed)
