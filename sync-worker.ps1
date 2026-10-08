param(
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [Parameter(Mandatory=$true)][string]$Serial,
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$StateDir,
    [Parameter(Mandatory=$true)][string]$AppRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'update-common.ps1')
$AppVersion = Get-AppVersion (Join-Path $PSScriptRoot 'version.json')
. (Join-Path $PSScriptRoot 'update-transaction.ps1')

$OperationMutex = $null
$PreviousProcessDirectory=[Environment]::CurrentDirectory
try {
    $OperationMutex = Enter-AppMutex $AppRoot 'operation'
    if (Get-PendingUpdate $AppRoot) { throw '미완료 업데이트를 먼저 복구해야 합니다.' }
    # 기존 Invoke-Adb 함수는 그대로 두고 기본 실행 디렉터리를 App 밖에 고정한다.
    $AdbWorkingDirectory=Get-AdbWorkingDirectory $AdbPath $AppRoot
    [Environment]::CurrentDirectory=$AdbWorkingDirectory

$StatusFile = Join-Path $StateDir "status.json"
$LogFile = Join-Path $StateDir "sync.log"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$Buckets = @(
    @{ Name="ROM"; Local="roms"; Remote="/storage/emulated/0/ROMs" },
    @{ Name="gamelist"; Local="gamelists"; Remote="/storage/emulated/0/ES-DE/gamelists" },
    @{ Name="media"; Local="downloaded_media"; Remote="/storage/emulated/0/ES-DE/downloaded_media" }
)

function Write-Log([string]$Message) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $fs = $null
        $sw = $null
        try {
            $fs = New-Object System.IO.FileStream(
                $LogFile,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $sw = New-Object System.IO.StreamWriter($fs, $utf8)
            $sw.WriteLine($line)
            $sw.Flush()
            return
        }
        catch {
            if ($attempt -eq 20) { throw }
            Start-Sleep -Milliseconds 25
        }
        finally {
            if ($sw) { $sw.Dispose() }
            elseif ($fs) { $fs.Dispose() }
        }
    }
}

function Write-Status([string]$State,[string]$Message,[int]$Current,[int]$Total) {
    $percent = 0
    if ($Total -gt 0) { $percent = [math]::Floor(($Current / $Total) * 100) }
    @{state=$State;message=$Message;current=$Current;total=$Total;percent=$percent} |
        ConvertTo-Json | Set-Content -LiteralPath $StatusFile -Encoding UTF8
}

function Join-CommandLineArgument([string]$arg) {
    if ($null -eq $arg) { return '""' }
    if ($arg -notmatch '[\s"]') { return $arg }
    return '"' + ($arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.Arguments = (($Args | ForEach-Object { Join-CommandLineArgument ([string]$_) }) -join " ")

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    if (-not $p.Start()) { throw "adb.exe 실행에 실패했습니다." }

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    $lines = @()
    if ($stdout) { $lines += @($stdout -split "`r?`n" | Where-Object { $_ -ne "" }) }
    if ($stderr) { $lines += @($stderr -split "`r?`n" | Where-Object { $_ -ne "" }) }

    return [pscustomobject]@{
        Output = $lines
        StdOut = $stdout
        StdErr = $stderr
        Code = $p.ExitCode
    }
}

function Quote-Sh([string]$s) {
    return "'" + ($s -replace "'", "'\''") + "'"
}

function Test-AndroidPackageName([string]$Name) {
    return [bool]($Name -cmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*$')
}

function Get-PackageFromComponent([string]$Component) {
    if (-not $Component) { return '' }
    $packages=@()
    foreach($token in ($Component -split '[\s{}(),''"=:\[\]]+')) {
        $pieces=$token.Split('/')
        if ($pieces.Count -eq 2 -and (Test-AndroidPackageName $pieces[0]) -and $pieces[1] -cmatch '^\.?[A-Za-z0-9_$][A-Za-z0-9_.$]*$') { $packages+=$pieces[0] }
    }
    $packages=@($packages|Sort-Object -Unique)
    if ($packages.Count -eq 1) { return $packages[0] }
    return ''
}

function Get-AndroidComponent([string]$Value) {
    $components=@()
    foreach($token in ($Value -split '[\s{}(),''"=:\[\]]+')) {
        $parts=$token.Split('/')
        if($parts.Count-eq2 -and (Test-AndroidPackageName $parts[0]) -and $parts[1]-cmatch '^\.?[A-Za-z0-9_$][A-Za-z0-9_.$]*$') {
            $activity=$parts[1]
            if($activity.StartsWith('.')){$activity=$parts[0]+$activity}
            $components+=($parts[0]+'/'+$activity)
        }
    }
    $components=@($components|Sort-Object -Unique)
    if($components.Count-eq1){return $components[0]};return ''
}

function Get-AndroidNamedValues([string]$Text,[string[]]$Names) {
    $pattern='^\s*(?<Field>'+((@($Names|ForEach-Object {[regex]::Escape($_)})) -join '|')+')\s*[:=]\s*(?<Value>.*)$'
    foreach($line in ($Text -split "`r?`n")) {
        if($line -match $pattern){[pscustomobject]@{field=$matches.Field;value=$matches.Value.Trim();raw=$line.Trim()}}
    }
}

function Get-AndroidFocusPackage([string]$Value) {
    $component=Get-PackageFromComponent $Value
    if($component){return $component}
    if($Value -match '(?:package|packageName|ownerPackage)\s*[:=]\s*([A-Za-z_][A-Za-z0-9_.]*)') {
        if(Test-AndroidPackageName $matches[1]){return $matches[1]}
    }
    if($Value -match '\bname\s*[:=]\s*[''"]([^''"]+)[''"]'){$Value=$matches[1]}
    $value=$Value.Trim().Trim("'",'"')
    # 임의의 창 제목에서 패키지처럼 보이는 일부 문자열을 추측하지 않는다.
    if($value.Contains('.') -and (Test-AndroidPackageName $value)){return $value}
    return ''
}

function Get-AndroidInputFocusValues([string]$Text) {
    # 과거 ANR/FocusRequests/RecentQueue는 현재 입력 대상이 아니다.
    $historical=[regex]::Match($Text,'(?im)^\s*Input Dispatcher State at time of last ANR:')
    if($historical.Success){$Text=$Text.Substring(0,$historical.Index)}
    $section='';$indent=-1
    foreach($line in ($Text -split "`r?`n")) {
        if($line -match '^(\s*)(FocusedApplications|FocusedWindows)\s*:\s*(.*)$') {
            $indent=$matches[1].Length;$section=$matches[2];$value=$matches[3].Trim()
            if($value){[pscustomobject]@{field=$section;value=$value;raw=$line.Trim()}}
            continue
        }
        if($section){
            if($line.Trim() -and ($line.Length-$line.TrimStart().Length) -le $indent){$section=''}
            elseif($line.Trim()){[pscustomobject]@{field=$section;value=$line.Trim();raw=$line.Trim()};continue}
        }
        if($line -match '^\s*(focusedApplication|mFocusedApplication|focusedWindow|mFocusedWindow|inputDispatchTarget|mInputDispatchTarget|dispatchTarget)\s*[:=]\s*(.+)$') {
            [pscustomobject]@{field=$matches[1];value=$matches[2].Trim();raw=$line.Trim()}
        }
    }
}

function Get-AndroidActiveTopPackages([string]$Text) {
    $package='';$stateSeen=$false
    foreach($line in ($Text -split "`r?`n")) {
        if($line -match '^\s*ACTIVITY\s+(\S+)'){$package=Get-PackageFromComponent $matches[1];$stateSeen=$false;continue}
        if($package -and -not $stateSeen -and $line -match '^\s*mResumed\s*[:=]\s*(true|false)\b') {
            $stateSeen=$true
            if($matches[1] -eq 'true') { Write-Output $package }
        }
    }
}

function ConvertTo-AndroidForegroundEvidence($Commands) {
    $issues=New-Object 'Collections.Generic.List[string]'
    $signals=New-Object 'Collections.Generic.List[object]'
    $failed=@($Commands|Where-Object {$_.code -ne 0})
    $text=@{};foreach($command in $Commands){$text[$command.source]=[string]$command.text}
    foreach($key in @('power','activities','activityTop','windows','displays','policy','input','home')){if(-not$text.ContainsKey($key)){$text[$key]='';$issues.Add('명령 자료 누락: '+$key)}}
    $wake=@(Get-AndroidNamedValues $text.power @('mWakefulness')|ForEach-Object value|Sort-Object -Unique)
    $sleep=@(Get-AndroidNamedValues $text.activities @('isSleeping')|ForEach-Object value|Sort-Object -Unique)
    $keyguard=@(Get-AndroidNamedValues $text.policy @('showing','mIsShowing','mKeyguardShowing')|ForEach-Object value|Sort-Object -Unique)
    $screen=@(Get-AndroidNamedValues $text.policy @('screenState')|ForEach-Object value|Sort-Object -Unique)
    foreach($line in ($text.power -split "`r?`n")){if($line-match 'Display Power:.*\bstate=(ON|OFF|DOZE|DOZE_SUSPEND)'){$screen+=$matches[1]}}
    $screen=@($screen|ForEach-Object {$_ -replace '^SCREEN_STATE_',''}|Sort-Object -Unique)
    $resolvedHome=@($text.home -split "`r?`n"|ForEach-Object {Get-PackageFromComponent $_}|Where-Object {$_}|Sort-Object -Unique)
    $owners=@{};$token=''
    foreach($line in ($text.windows -split "`r?`n")){
        if($line-match '^\s*Window #\d+ Window\{([A-Za-z0-9]+)'){$token=$matches[1]}
        if($token -and $line-match '\bmOwnerUid=.*\bpackage=([A-Za-z_][A-Za-z0-9_.]*)'){$owners[$token]=$matches[1]}
    }
    foreach($source in @('activities','windows','displays')){
        $names=if($source-eq'activities'){@('topResumedActivity','mResumedActivity','ResumedActivity')}else{@('mCurrentFocus','mFocusedApp')}
        foreach($value in @(Get-AndroidNamedValues $text[$source] $names)){
            $package=Get-AndroidFocusPackage $value.value
            $signals.Add([pscustomobject]@{source=$source;field=$value.field;package=$package;raw=$value.raw})
            if($source-ne'activities' -and $value.field-eq'mCurrentFocus' -and $value.value-match 'Window\{([A-Za-z0-9]+)' -and $owners.ContainsKey($matches[1])){
                $owner=$owners[$matches[1]];$signals.Add([pscustomobject]@{source=$source;field='focusOwner';package=$owner;raw=$value.raw})
                if(-not$package){$package=$owner;$signals[$signals.Count-2].package=$package}
            }
            if(-not$package){$issues.Add('패키지 해석 실패: '+$source+'/'+$value.field+' '+$value.value)}
        }
    }
    foreach($package in @(Get-AndroidActiveTopPackages $text.activityTop)){$signals.Add([pscustomobject]@{source='activityTop';field='activeActivity';package=$package;raw=$package})}
    $inputText=$text.input
    $history=[regex]::Match($inputText,'(?im)^\s*Input Dispatcher State at time of last ANR:')
    if($history.Success){$inputText=$inputText.Substring(0,$history.Index)}
    foreach($value in @(Get-AndroidInputFocusValues $inputText)){
        $package=Get-AndroidFocusPackage $value.value
        $signals.Add([pscustomobject]@{source='input';field=$value.field;package=$package;raw=$value.raw})
        if(-not$package){$issues.Add('입력 패키지 해석 실패: '+$value.field+' '+$value.value)}
    }
    $inputWindow=@($signals|Where-Object {$_.source-eq'input' -and $_.field-match'^(FocusedWindows|focusedWindow|mFocusedWindow)$' -and $_.package}|ForEach-Object package|Sort-Object -Unique)
    $rows=@($inputText-split"`r?`n"|Where-Object {$_-match'^\s*\d+:\s+name='})
    $focusRowSeen=$false
    foreach($row in $rows){
        if($row-match '\binputConfig=([^,]+)'){$flags=$matches[1]}else{$issues.Add('입력 창 플래그 없음: '+$row.Trim());continue}
        if($flags-match 'NOT_VISIBLE|NOT_TOUCHABLE|NO_INPUT_CHANNEL|\bSPY\b' -or $row-match '\balpha=0(?:\.0+)?\s*,' -or $row-match 'touchableRegion=<empty>'){continue}
        $package=Get-AndroidFocusPackage $row
        if($package -and $inputWindow -contains $package){$focusRowSeen=$true;break}
        if($flags-match'0x' -and $flags.Trim()-ne'0x0'){$issues.Add('숫자 입력 플래그 판정 불가: '+$flags);continue}
        if($package){$signals.Add([pscustomobject]@{source='input';field='interactiveOverlay';package=$package;raw=$row.Trim()})}
        else{$issues.Add('전면 입력 창 소유자 해석 실패: '+$row.Trim())}
    }
    if($rows.Count -and $inputWindow.Count -and -not$focusRowSeen){$issues.Add('입력 focus와 현재 창 목록의 대응 불명확')}
    $dispatch=@(Get-AndroidNamedValues $inputText @('DispatchEnabled','DispatchFrozen','mDispatchEnabled','mDispatchFrozen'))
    return [pscustomobject]@{capturedAt=(Get-Date).ToUniversalTime().ToString('o');commands=@($Commands);failures=$failed;parseIssues=@($issues.ToArray());power=[pscustomobject]@{wakefulness=$wake;sleeping=$sleep;display=$screen;keyguard=$keyguard};signals=@($signals.ToArray());dispatch=$dispatch;homePackages=$resolvedHome;esdePackage='org.es_de.frontend'}
}

function Get-AndroidForegroundEvidence {
    $definitions=@(
        @{source='power';command='dumpsys power'},@{source='activities';command='dumpsys activity activities'},
        @{source='activityTop';command='dumpsys activity top'},@{source='windows';command='dumpsys window windows'},
        @{source='displays';command='dumpsys window displays'},@{source='policy';command='dumpsys window policy'},
        @{source='input';command='dumpsys input'},@{source='home';command='cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'})
    $commands=@()
    foreach($definition in $definitions){
        try{$result=Invoke-Adb -s $Serial shell $definition.command;$commands+=[pscustomobject]@{source=$definition.source;command=$definition.command;code=$result.Code;text=$result.StdOut;error=$result.StdErr}}
        catch{$commands+=[pscustomobject]@{source=$definition.source;command=$definition.command;code=-1;text='';error=$_.Exception.Message}}
    }
    return ConvertTo-AndroidForegroundEvidence $commands
}

function Evaluate-AndroidForegroundSafety($Evidence) {
    $power=$Evidence.power
    $status='unknown';$reason='';$package=''
    $homeCandidates=@($Evidence.homePackages|Where-Object {$_ -notin @('android','com.android.systemui')})
    $allowed=@($Evidence.esdePackage)+$homeCandidates
    $third=@($Evidence.signals|Where-Object {$_.package -and $_.package -notin ($allowed+@('android','com.android.systemui'))})
    if($power.wakefulness -contains 'Asleep' -or $power.wakefulness -contains 'Dozing' -or $power.wakefulness -contains 'Dreaming' -or $power.sleeping -contains 'true' -or $power.display -contains 'OFF' -or $power.display -contains 'DOZE' -or $power.display -contains 'DOZE_SUSPEND'){$status='unsafe';$reason='화면 꺼짐/수면/Dozing 상태'}
    elseif($power.keyguard -contains 'true'){$status='unsafe';$reason='잠금 화면이 표시됨'}
    elseif($third.Count){$status='unsafe';$reason='제3 앱 foreground 증거: '+(($third|ForEach-Object {$_.source+'/'+$_.field+'='+$_.package})-join'; ')}
    elseif($Evidence.failures.Count){$reason='dumpsys/resolve 명령 실패: '+(($Evidence.failures|ForEach-Object {$_.source+' exit='+$_.code})-join'; ')}
    elseif($Evidence.parseIssues.Count){$reason='해석 불완전: '+($Evidence.parseIssues-join'; ')}
    elseif($power.wakefulness.Count-ne1 -or $power.wakefulness[0]-ne'Awake' -or $power.sleeping.Count-ne1 -or $power.sleeping[0]-ne'false' -or $power.display.Count-ne1 -or $power.display[0]-ne'ON' -or $power.keyguard.Count-ne1 -or $power.keyguard[0]-ne'false'){$reason='전원/화면/잠금 신호가 불명확하거나 서로 불일치'}
    elseif($Evidence.homePackages.Count-ne1){$reason='HOME launcher 해석 불명확'}
    elseif(@($Evidence.dispatch|Where-Object {($_.field-match'Enabled$' -and $_.value-ne'true') -or ($_.field-match'Frozen$' -and $_.value-ne'false')}).Count){$reason='입력 dispatch 비활성/정지 또는 불명확'}
    elseif(@($Evidence.signals|Where-Object {$_.package -in @('android','com.android.systemui')}).Count){$reason='SystemUI/시스템 대화상자: 보수적으로 차단'}
    else{
        $activity=@($Evidence.signals|Where-Object {$_.source-eq'activities' -and $_.package}|ForEach-Object package|Sort-Object -Unique)
        $window=@($Evidence.signals|Where-Object {$_.field-eq'mCurrentFocus' -and $_.package}|ForEach-Object package|Sort-Object -Unique)
        $inputApp=@($Evidence.signals|Where-Object {$_.source-eq'input' -and $_.field-match'^(FocusedApplications|focusedApplication|mFocusedApplication)$' -and $_.package}|ForEach-Object package|Sort-Object -Unique)
        $inputWindow=@($Evidence.signals|Where-Object {$_.source-eq'input' -and $_.field-match'^(FocusedWindows|focusedWindow|mFocusedWindow)$' -and $_.package}|ForEach-Object package|Sort-Object -Unique)
        $all=@($Evidence.signals|Where-Object {$_.package}|ForEach-Object package|Sort-Object -Unique)
        if($activity.Count-ne1 -or $window.Count-ne1 -or $inputApp.Count-ne1 -or $inputWindow.Count-ne1){$reason='필수 activity/current-window/input-application/input-window 증거 누락/중복'}
        elseif($all.Count-ne1){$reason='activity/window/input 신호가 서로 불일치'}
        elseif($all[0]-notin$allowed){$reason='확인된 패키지를 안전한 launcher로 검증할 수 없음'}
        else{
            $homeActivity=Get-AndroidComponent (($Evidence.commands|Where-Object source -eq 'home'|ForEach-Object text)-join' ')
            $homeSignals=@($Evidence.signals|Where-Object {($_.source-eq'activities') -or ($_.field-eq'mCurrentFocus') -or ($_.source-eq'input' -and $_.field-match'^(FocusedApplications|focusedApplication|mFocusedApplication|FocusedWindows|focusedWindow|mFocusedWindow)$')})
            $wrongHome=@($homeSignals|Where-Object {(Get-AndroidComponent $_.raw)-cne$homeActivity})
            # HOME과 같은 패키지의 별도 게임 activity를 홈 화면으로 간주하지 않는다.
            if($all[0]-cne$Evidence.esdePackage -and (-not$homeActivity -or $wrongHome.Count)){$reason='HOME 패키지는 일치하지만 실제 HOME component 합의가 없음'}
            else{$status='safe';$package=$all[0];$reason='Awake/잠금 해제 및 activity+window+input이 '+$package+'에 합의'}
        }
    }
    return [pscustomobject]@{status=$status;allowed=($status-eq'safe');package=$package;reason=$reason}
}

function Write-AndroidForegroundEvidence($Evidence,$Decision) {
    Write-Log ('POWER: wakefulness='+($Evidence.power.wakefulness-join',')+' sleeping='+($Evidence.power.sleeping-join',')+' display='+($Evidence.power.display-join',')+' keyguard='+($Evidence.power.keyguard-join','))
    foreach($signal in $Evidence.signals){Write-Log ($signal.source.ToUpperInvariant()+': '+$signal.field+'='+$signal.package+' raw='+$signal.raw)}
    foreach($failure in $Evidence.failures){Write-Log ('COMMAND ERROR: '+$failure.source+' exit='+$failure.code+' '+$failure.error)}
    foreach($issue in $Evidence.parseIssues){Write-Log ('PARSE ISSUE: '+$issue)}
    Write-Log ('HOME: '+($Evidence.homePackages-join','))
    Write-Log ('DECISION: '+$Decision.status.ToUpperInvariant()+' reason='+$Decision.reason)
}

function Get-ForegroundPackage {
    # 이전 호출자를 위한 호환 함수. 안전 합의가 없으면 패키지를 반환하지 않는다.
    $evidence=Get-AndroidForegroundEvidence;$decision=Evaluate-AndroidForegroundSafety $evidence
    Write-AndroidForegroundEvidence $evidence $decision
    if($decision.allowed){return $decision.package};return ''
}

function Get-HomePackage {
    $r = Invoke-Adb -s $Serial shell "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    if ($r.Code -ne 0) { return "" }

    foreach ($line in $r.Output) {
        $pkg = Get-PackageFromComponent ([string]$line)
        if ($pkg) { return $pkg }
    }
    return ""
}

function Preflight-CheckForeground {
    Write-Status 'preflight' '화면·잠금·실행 중인 앱을 확인하는 중...' 0 1
    $previous=''
    # 순차 dumpsys 수집 사이의 전환을 보수적으로 처리하기 위해 안전 합의를 재확인한다.
    foreach($pass in 1..2){
        $evidence=Get-AndroidForegroundEvidence;$decision=Evaluate-AndroidForegroundSafety $evidence
        Write-AndroidForegroundEvidence $evidence $decision
        if(-not$decision.allowed){Write-Log ('PREFLIGHT BLOCK: '+$decision.status+' '+$decision.reason);throw ('안전한 foreground를 확인할 수 없어 동기화를 차단합니다: '+$decision.reason)}
        if($previous -and $previous-cne$decision.package){Write-Log 'PREFLIGHT BLOCK: launcher changed between samples';throw '검사 중 foreground가 변경되어 동기화를 차단합니다.'}
        $previous=$decision.package
    }
    Write-Log ('PREFLIGHT OK: stable activity/window/input consensus on '+$previous)
}
function Stop-Esde {
    Write-Status "stopping" "ES-DE를 종료하는 중..." 0 1
    Write-Log "STOP APP [ES-DE] org.es_de.frontend"

    $r = Invoke-Adb -s $Serial shell "am force-stop org.es_de.frontend"
    if ($r.Code -ne 0) {
        throw "ES-DE 종료 실패.`r`n$($r.StdErr)"
    }
}

function Start-Esde {
    Write-Status "restarting" "ES-DE를 다시 실행하는 중..." 1 1
    Write-Log "START APP [ES-DE] org.es_de.frontend/.MainActivityHomeApp"

    $r = Invoke-Adb -s $Serial shell "am start -n org.es_de.frontend/.MainActivityHomeApp"
    if ($r.Code -ne 0) {
        throw "ES-DE 재실행에 실패했습니다.`r`n$($r.StdErr)"
    }
}

$ReservedFolders = @('_TEST', '_UNREGISTERED')

function Assert-RemotePath([string]$RemotePath, [switch]$Deleting, [switch]$Tree) {
    if ([string]::IsNullOrWhiteSpace($RemotePath) -or
        $RemotePath -match '[\\\x00-\x1f\x7f]|//|/$|(^|/)\.\.?(/|$)') {
        throw "안전하지 않은 원격 경로: $RemotePath"
    }
    $root = $null
    foreach ($bucket in $Buckets) {
        if ($RemotePath.StartsWith($bucket.Remote + '/', [StringComparison]::Ordinal)) {
            $root = $bucket.Remote
            break
        }
    }
    if (-not $root) { throw "허용 루트 밖의 원격 경로: $RemotePath" }
    $parts = $RemotePath.Substring($root.Length + 1) -split '/'
    if (-not ($selectedSystems -ccontains $parts[0])) {
        throw "선택 시스템 밖의 원격 경로: $RemotePath"
    }
    if ($Deleting) {
        if ($parts.Count -gt 1 -and (Is-ExcludedRelativePath ($parts[1..($parts.Count - 1)] -join '/'))) {
            throw "예약 폴더 삭제 금지: $RemotePath"
        }
        if ($parts.Count -eq 1 -and (-not $Tree -or $root -ceq '/storage/emulated/0/ROMs')) {
            throw "시스템 루트 삭제 금지: $RemotePath"
        }
    }
}

function Ensure-RemoteDir([string]$RemoteDir) {
    Assert-RemotePath $RemoteDir
    $r = Invoke-Adb -s $Serial shell ("mkdir -p " + (Quote-Sh $RemoteDir))
    if ($r.Code -ne 0) { throw "원격 폴더 생성 실패: $RemoteDir`r`n$($r.StdErr)" }
}

function Remove-RemoteFile([string]$RemotePath) {
    Assert-RemotePath $RemotePath -Deleting
    $r = Invoke-Adb -s $Serial shell ("rm -f " + (Quote-Sh $RemotePath))
    if ($r.Code -ne 0) { throw "원격 파일 삭제 실패: $RemotePath`r`n$($r.StdErr)" }
}

function Remove-RemoteTree([string]$RemotePath) {
    Assert-RemotePath $RemotePath -Deleting -Tree
    $r = Invoke-Adb -s $Serial shell ("rm -rf " + (Quote-Sh $RemotePath))
    if ($r.Code -ne 0) { throw "원격 폴더 삭제 실패: $RemotePath`r`n$($r.StdErr)" }
}

function Try-RemoveEmptyRemoteDir([string]$RemotePath) {
    Assert-RemotePath $RemotePath -Deleting
    [void](Invoke-Adb -s $Serial shell ("rmdir " + (Quote-Sh $RemotePath) + " 2>/dev/null || true"))
}

function Is-ExcludedRelativePath([string]$RelativePath) {
    if (-not $RelativePath) { return $false }

    $norm = ($RelativePath -replace '\\','/').TrimStart('/')
    foreach ($part in ($norm -split '/')) {
        if ($ReservedFolders -contains $part) { return $true }
    }

    return $false
}

function Get-RemoteEntries([string]$RemoteDir, [ValidateSet('f','d')][string]$Type) {
    Assert-RemotePath $RemoteDir
    $q = Quote-Sh $RemoteDir
    $excluded = @($ReservedFolders | ForEach-Object { '-iname ' + (Quote-Sh $_) }) -join ' -o '
    $parent = Quote-Sh ($RemoteDir.Substring(0, $RemoteDir.LastIndexOf('/')))
    # depth 조건을 OR 식에 섞지 않는다. 시작점은 파서에서 정확히 일치할 때만 제외한다.
    # print0는 공백/괄호/따옴표와 줄바꿈이 있는 이름도 한 항목으로 구분한다.
    $r = Invoke-Adb -s $Serial shell ("if [ -d $q ]; then find $q \( $excluded \) -prune -o -type $Type -print0; elif [ -e $q ]; then exit 1; else ls -d $parent >/dev/null || exit 1; fi")
    if ($r.Code -ne 0 -or -not [string]::IsNullOrWhiteSpace($r.StdErr)) {
        throw "원격 목록 조회 실패: $RemoteDir (type=$Type) $($r.StdErr)"
    }

    $prefix = $RemoteDir.TrimEnd("/") + "/"
    $items = @()
    if ($r.StdOut -and -not $r.StdOut.EndsWith([string][char]0)) {
        throw "원격 목록 형식 오류: NUL 종료 누락 ($RemoteDir)"
    }
    foreach ($line in @($r.StdOut -split '\x00')) {
        $s = [string]$line
        if ($s -eq '') { continue }
        if ($Type -eq 'd' -and $s -ceq $RemoteDir) { continue }
        if ($s.StartsWith($prefix, [StringComparison]::Ordinal)) {
            Assert-RemotePath $s
            $relative = $s.Substring($prefix.Length)
            if (Is-ExcludedRelativePath $relative) {
                throw "원격 목록에 예약 경로가 포함되었습니다: $s"
            }
            $items += $relative
        }
        else { throw "원격 목록 범위 오류: $s" }
    }
    return $items
}

function Get-RemoteFiles([string]$RemoteDir) { Get-RemoteEntries $RemoteDir 'f' }
function Get-RemoteDirs([string]$RemoteDir) { Get-RemoteEntries $RemoteDir 'd' }

function Initialize-LocalPathApi {
    if ('EsdeLocalPath' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class EsdeLocalPath {
    [StructLayout(LayoutKind.Sequential)] public struct Info { public uint Attributes; public uint Tag; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string p, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int kind, out Info info, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle h, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(SafeFileHandle h, byte[] buffer, uint size, out uint read, IntPtr overlapped);
    static SafeFileHandle Open(string path, uint access, uint flags) {
        SafeFileHandle h = CreateFile(path, access, 1, IntPtr.Zero, 3, flags, IntPtr.Zero);
        if (h.IsInvalid) { int error = Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(error); }
        return h;
    }
    public static Info Inspect(string path) {
        // OPEN_REPARSE_POINT + OPEN_NO_RECALL + BACKUP_SEMANTICS: metadata only.
        using (SafeFileHandle h = Open(path, 0, 0x02300000)) {
            Info info;
            if (!GetFileInformationByHandleEx(h, 9, out info, 8)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info;
        }
    }
    public static string ReadLocal(string path, bool directory) {
        // Reject recall flags before opening data; never request hydration.
        Info info = Inspect(path);
        if ((info.Attributes & 0x00441000) != 0) throw new IOException("Offline/Recall placeholder");
        using (SafeFileHandle h = Open(path, directory ? 0U : 0x80000000U, 0x02100000)) {
            StringBuilder final = new StringBuilder(32768);
            uint count = GetFinalPathNameByHandle(h, final, (uint)final.Capacity, 0);
            if (count == 0 || count >= final.Capacity) throw new IOException("Final path unavailable");
            string resolved = final.ToString();
            if (resolved.StartsWith(@"\\?\UNC\")) resolved = @"\\" + resolved.Substring(8);
            else if (resolved.StartsWith(@"\\?\")) resolved = resolved.Substring(4);
            if (!String.Equals(Path.GetFullPath(path).TrimEnd('\\'), resolved.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Final path differs from source path");
            if (!directory) {
                byte[] buffer = new byte[65536]; uint read;
                do {
                    if (!ReadFile(h, buffer, (uint)buffer.Length, out read, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                } while (read != 0);
            }
            return resolved;
        }
    }
}
'@
}

function Get-LocalPathInfo([string]$Path) {
    Initialize-LocalPathApi
    return [EsdeLocalPath]::Inspect($Path)
}

function Test-LocalFileReadable([string]$Path, [bool]$Directory) {
    Initialize-LocalPathApi
    return [EsdeLocalPath]::ReadLocal($Path, $Directory)
}

function Assert-LocalSourcePath([string]$Path, [string]$Root, [long]$EnumerationAttributes = 0) {
    try {
        # RECALL_ON_OPEN은 디렉터리 열거에서만 보고될 수 있다.
        if (($EnumerationAttributes -band 0x00441000) -ne 0) { throw '열거 정보의 Offline/Recall placeholder' }
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $boundary = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($full -ine $boundary -and -not $full.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '원본 루트 밖의 경로'
        }
        # 루트 자체와 상위 폴더의 junction도 검사한다.
        $cursor = [IO.Path]::GetPathRoot($full)
        $info = $null
        foreach ($part in ($full.Substring($cursor.Length) -split '\\')) {
            if (-not $part) { continue }
            $cursor = Join-Path $cursor $part
            $info = Get-LocalPathInfo $cursor
            if (($info.Tag -band 0x20000000) -ne 0) { throw ('이름 대체 링크/reparse tag: 0x{0:X8}' -f $info.Tag) }
            if (($info.Attributes -band 0x00441000) -ne 0) { throw '로컬 미완료 Offline/Recall placeholder' }
            if (($info.Attributes -band 0x400) -ne 0 -and $info.Tag -eq 0) { throw 'reparse tag 판정 실패' }
        }
        if (-not $info) { throw '원본 루트 정보 판정 실패' }
        $final = Test-LocalFileReadable $full (($info.Attributes -band 0x10) -ne 0)
        if ($final.TrimEnd('\') -ine $full) { throw '최종 경로가 원본 경로와 다름' }
        if (($info.Attributes -band 0x400) -ne 0) {
            Write-Log ('SOURCE ALLOW: local non-surrogate reparse tag=0x{0:X8} {1}' -f $info.Tag, $full)
        }
        else { Write-Log "SOURCE ALLOW: local ordinary path $full" }
    }
    catch {
        try { Write-Log "SOURCE BLOCK: $Path : $($_.Exception.Message)" } catch {}
        throw
    }
}

function Get-ManagedLocalItems([string]$LocalPath, [string]$Root = $LocalPath) {
    Assert-LocalSourcePath $LocalPath $Root
    foreach ($item in @(Get-ChildItem -LiteralPath $LocalPath -Force)) {
        if (Is-ExcludedRelativePath $item.Name) { continue }
        Assert-LocalSourcePath $item.FullName $Root -EnumerationAttributes ([long]$item.Attributes)
        $item
        if ($item.PSIsContainer) { Get-ManagedLocalItems $item.FullName $Root }
    }
}

function Remove-ManagedRemoteContents([string]$RemotePath) {
    $files = @(Get-RemoteFiles $RemotePath)
    $dirs = @(Get-RemoteDirs $RemotePath | Sort-Object { ($_ -split '/').Count } -Descending)
    foreach ($rel in @($files + $dirs)) {
        Assert-RemotePath ($RemotePath + '/' + $rel) -Deleting
    }
    foreach ($rel in $files) { Remove-RemoteFile ($RemotePath + '/' + $rel) }
    foreach ($rel in $dirs) { Try-RemoveEmptyRemoteDir ($RemotePath + '/' + $rel) }
}

function Mirror-SystemFolder([string]$LocalSystemPath, [string]$RemoteSystemPath, [string]$Label) {
    $managedItems = @(Get-ManagedLocalItems $LocalSystemPath | Sort-Object FullName)
    # 두 목록 조회를 모두 완료해야 삭제 판단을 시작할 수 있다.
    $remoteFiles = @(Get-RemoteFiles $RemoteSystemPath)
    $remoteDirs = @(Get-RemoteDirs $RemoteSystemPath | Sort-Object { ($_ -split '/').Count } -Descending)
    foreach ($rel in @($remoteFiles + $remoteDirs)) {
        Assert-RemotePath ($RemoteSystemPath + '/' + $rel) -Deleting
    }
    Ensure-RemoteDir $RemoteSystemPath

    # Build local file set, excluding the reserved subtrees.
    $localFiles = @{}
    foreach ($f in @($managedItems | Where-Object { -not $_.PSIsContainer })) {
        $rel = $f.FullName.Substring($LocalSystemPath.Length).TrimStart([char]'\',[char]'/') -replace '\\','/'
        if (Is-ExcludedRelativePath $rel) {
            Write-Log "  EXCLUDE LOCAL $rel"
            continue
        }
        $localFiles[$rel] = $true
    }

    # Delete Android-only files, but never touch reserved folders or their descendants.
    foreach ($rel in $remoteFiles) {
        if (Is-ExcludedRelativePath ([string]$rel)) {
            Write-Log "  PRESERVE RESERVED $rel"
            continue
        }

        if (-not $localFiles.ContainsKey([string]$rel)) {
            Write-Log "  DELETE EXTRA FILE $rel"
            Remove-RemoteFile ($RemoteSystemPath.TrimEnd("/") + "/" + [string]$rel)
        }
    }

    # Remove Android-only empty directories, except reserved folders and descendants.
    $localDirs = @{}
    foreach ($d in @($managedItems | Where-Object { $_.PSIsContainer })) {
        $rel = $d.FullName.Substring($LocalSystemPath.Length).TrimStart([char]'\',[char]'/') -replace '\\','/'
        if (-not $rel) { continue }
        if (Is-ExcludedRelativePath $rel) {
            Write-Log "  EXCLUDE LOCAL DIR $rel"
            continue
        }
        $localDirs[$rel] = $true
    }

    foreach ($rel in $remoteDirs) {
        if (Is-ExcludedRelativePath ([string]$rel)) {
            continue
        }

        if (-not $localDirs.ContainsKey([string]$rel)) {
            Write-Log "  REMOVE EXTRA DIR IF EMPTY $rel"
            Try-RemoveEmptyRemoteDir ($RemoteSystemPath.TrimEnd("/") + "/" + [string]$rel)
        }
    }

    # Fast path: Dropbox-side reserved folders do not exist (recommended layout).
    # Push the whole selected system in one adb transaction.
    $localReservedItems = @()
    foreach ($dir in @($LocalSystemPath) + @($managedItems | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName })) {
        $localReservedItems += @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { Is-ExcludedRelativePath $_.Name })
    }

    if ($localReservedItems.Count -eq 0) {
        $localDot = Join-Path $LocalSystemPath "."
        $push = Invoke-Adb -s $Serial push --sync $localDot ($RemoteSystemPath.TrimEnd("/") + "/")

        foreach ($line in $push.Output) {
            if ([string]$line) { Write-Log ("  " + [string]$line) }
        }

        if ($push.Code -ne 0) {
            throw "ADB 전송 실패: $Label`r`n$($push.StdErr)"
        }
    }
    else {
        # Safety fallback: if Dropbox contains reserved folders,
        # push managed files individually; never transfer reserved subtrees.
        Write-Log "  LOCAL RESERVED FOLDER FOUND -> excluded from transfer"

        foreach ($item in $managedItems) {
            $rel = $item.FullName.Substring($LocalSystemPath.Length).TrimStart([char]'\',[char]'/') -replace '\\','/'
            $remoteTarget = $RemoteSystemPath + '/' + $rel

            if ($item.PSIsContainer) {
                Ensure-RemoteDir $remoteTarget
                continue
            }
            else {
                Ensure-RemoteDir ($remoteTarget.Substring(0, $remoteTarget.LastIndexOf('/')))
                $push = Invoke-Adb -s $Serial push --sync $item.FullName $remoteTarget
            }

            foreach ($line in $push.Output) {
                if ([string]$line) { Write-Log ("  " + [string]$line) }
            }

            if ($push.Code -ne 0) {
                throw "ADB 전송 실패: $Label / $($item.Name)`r`n$($push.StdErr)"
            }
        }
    }
}

# 독립 metadata 병합 기반. ADB/ROM 탐색/원본 덮어쓰기 없이 사용한다.
function Get-EsdeGamePathInfo([string]$Path) {
    $invalid=[pscustomobject]@{Class='Invalid';Key=''}
    if([string]::IsNullOrEmpty($Path) -or $Path -match '[\x00-\x1f\x7f]'){return $invalid}
    $relative=$Path.Replace('\','/')
    if($relative.StartsWith('/') -or $relative.Contains(':')){return $invalid}
    if($relative.StartsWith('./')){$relative=$relative.Substring(2)}
    $parts=$relative.Split('/')
    if(@($parts|Where-Object {$_ -in @('','.', '..')}).Count){return $invalid}
    $class='Managed'
    foreach($part in $parts){
        # worker Is-ExcludedRelativePath와 동일하게 모든 구성요소를 대소문자 무시 비교한다.
        if($part -ieq '_TEST'){$class='LocalTest';break}
        if($part -ieq '_UNREGISTERED'){$class='LocalUnregistered';break}
    }
    return [pscustomobject]@{Class=$class;Key=('./'+($parts-join'/'))}
}

function Get-EsdeGamePathClass([string]$Path) { return (Get-EsdeGamePathInfo $Path).Class }

function ConvertFrom-EsdeGamelistBytes([byte[]]$Bytes,[string]$Source='memory') {
    if($Bytes.Length -gt 33554432){throw 'gamelist 크기 제한 초과'}
    $offset=0;$bom=$false
    $encoding=New-Object Text.UTF8Encoding($false,$true)
    if($Bytes.Length-ge3 -and $Bytes[0]-eq239 -and $Bytes[1]-eq187 -and $Bytes[2]-eq191){$offset=3;$bom=$true}
    elseif($Bytes.Length-ge2 -and $Bytes[0]-eq255 -and $Bytes[1]-eq254){$encoding=New-Object Text.UnicodeEncoding($false,$false,$true);$offset=2;$bom=$true}
    elseif($Bytes.Length-ge2 -and $Bytes[0]-eq254 -and $Bytes[1]-eq255){$encoding=New-Object Text.UnicodeEncoding($true,$false,$true);$offset=2;$bom=$true}
    $text=$encoding.GetString($Bytes,$offset,$Bytes.Length-$offset)
    $declaration=''
    # XML declaration만 분리한다. game 블록은 문자열/정규식으로 편집하지 않는다.
    $match=[regex]::Match($text,'\A<\?xml\s+[^?]*\?>')
    if($match.Success){$declaration=$match.Value;$text=$text.Substring($match.Length)}
    $settings=New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $settings.MaxCharactersInDocument=33554464
    $document=New-Object Xml.XmlDocument
    $document.PreserveWhitespace=$true;$document.XmlResolver=$null
    $stringReader=New-Object IO.StringReader ('<esdeWrapper>'+$text+'</esdeWrapper>')
    $reader=$null
    try{
        # declaration 자체도 XML parser로 검증한다.
        if($declaration){
            $probe=New-Object Xml.XmlDocument;$probe.XmlResolver=$null
            $probe.LoadXml($declaration+'<declarationCheck/>')
            $declEncoding=$probe.FirstChild.Encoding
            if($declEncoding -and $declEncoding -notmatch '^(utf-8|utf-16|utf-16le|utf-16be)$'){throw '지원하지 않는 XML encoding'}
            if($declEncoding -match '^utf-8$' -and $encoding.CodePage-ne65001){throw 'XML encoding/BOM 불일치'}
            if($declEncoding -match '^utf-16' -and $encoding.CodePage-notin@(1200,1201)){throw 'XML encoding/BOM 불일치'}
        }
        $reader=[Xml.XmlReader]::Create($stringReader,$settings);$document.Load($reader)
    }catch{throw ('gamelist XML 읽기 실패 ['+$Source+']: '+$_.Exception.Message)}
    finally{if($reader){$reader.Dispose()};$stringReader.Dispose()}
    $lists=@($document.DocumentElement.SelectNodes('gameList'))
    if($lists.Count-gt1){throw ('여러 gameList 요소: '+$Source)}
    $newline=if($text.Contains("`r`n")){"`r`n"}else{"`n"}
    return [pscustomobject]@{Document=$document;Bytes=$Bytes;Declaration=$declaration;Encoding=$encoding;Bom=$bom;Newline=$newline;Source=$Source}
}

function Read-EsdeGamelist([string]$Path) {
    if([string]::IsNullOrEmpty($Path)){return $null}
    if(-not[IO.File]::Exists($Path)){throw ('명시한 gamelist 파일이 없거나 읽을 수 없음: '+$Path)}
    if((New-Object IO.FileInfo $Path).Length-gt33554432){throw 'gamelist 크기 제한 초과'}
    return ConvertFrom-EsdeGamelistBytes ([IO.File]::ReadAllBytes($Path)) ([IO.Path]::GetFullPath($Path))
}

function Get-EsdeGameEntries($Gamelist,[scriptblock]$Warning) {
    if($null-eq$Gamelist){return}
    foreach($node in $Gamelist.Document.DocumentElement.SelectNodes('gameList/game')){
        $paths=@($node.SelectNodes('path'))
        if($paths.Count-ne1 -or @($paths[0].SelectNodes('*')).Count){
            if($Warning){& $Warning ('Invalid game path 구조: '+$Gamelist.Source)|Out-Null}
            throw 'game에 단일 텍스트 path가 필요합니다.'
        }
        $info=Get-EsdeGamePathInfo $paths[0].InnerText
        if($info.Class-eq'Invalid'){
            if($Warning){& $Warning ('Invalid game path: '+$paths[0].InnerText)|Out-Null}
            throw ('안전하지 않은 game path: '+$paths[0].InnerText)
        }
        [pscustomobject]@{Node=$node;Key=$info.Key;Class=$info.Class}
    }
}

function Get-LocalOnlyGameEntries($Gamelist,[scriptblock]$Warning) {
    Get-EsdeGameEntries $Gamelist $Warning|Where-Object {$_.Class -in @('LocalTest','LocalUnregistered')}
}

function ConvertTo-EsdeGamelistBytes($Gamelist) {
    $text=$Gamelist.Declaration+$Gamelist.Document.DocumentElement.InnerXml
    $text=$text.Replace("`r`n","`n").Replace("`n",$Gamelist.Newline)
    $bytes=$Gamelist.Encoding.GetBytes($text)
    if($Gamelist.Bom){
        $prefix=if($Gamelist.Encoding.CodePage-eq65001){[byte[]]@(239,187,191)}elseif($Gamelist.Encoding.CodePage-eq1200){[byte[]]@(255,254)}else{[byte[]]@(254,255)}
        $bytes=[byte[]]($prefix+$bytes)
    }
    # 출력 경로에 쓰기 전에 실제 저장할 바이트를 다시 파싱한다.
    [void](ConvertFrom-EsdeGamelistBytes $bytes 'validated output')
    return ,$bytes
}

function Merge-EsdeRuntimeGameTags([System.Xml.XmlElement]$Destination,[System.Xml.XmlElement]$Android) {
    $changed=$false
    foreach($tag in @('playcount','lastplayed','playtime')){
        $local=@($Android.SelectNodes($tag));$base=@($Destination.SelectNodes($tag))
        if($local.Count-gt1 -or $base.Count-gt1){throw ('runtime tag 중복: '+$tag)}
        if($local.Count-eq0){continue}
        $import=$Destination.OwnerDocument.ImportNode($local[0],$true)
        if($base.Count-eq1){
            if($base[0].OuterXml-ceq$import.OuterXml){continue}
            [void]$Destination.ReplaceChild($import,$base[0])
        }else{[void]$Destination.AppendChild($import)}
        $changed=$true
    }
    return $changed
}

function Get-AndroidAltemulatorMappings {
    # 사용자 확정 전환 + 설치 APK Android/공식 Linux label로 확인된 항목만.
    return @(
        [pscustomobject]@{System='gb';Linux='SameBoy (Standalone)';Android='My OldBoy! (Standalone)'},
        [pscustomobject]@{System='gbc';Linux='Sameboy (Standalone)';Android='My OldBoy! (Standalone)'}
    )
}

function Convert-EsdeAndroidAltemulators($Gamelist,[string]$System,[Parameter(Mandatory=$true)][bool]$IsArcade,[object[]]$Mappings=(Get-AndroidAltemulatorMappings),[scriptblock]$Warning,[string[]]$PreservedUnmanagedPaths=@()) {
    if($null-eq$Gamelist){return $null}
    $result=ConvertFrom-EsdeGamelistBytes $Gamelist.Bytes 'Android emulator staging'
    $changed=$false
    foreach($entry in @(Get-EsdeGameEntries $result)){
        # 기존 local-only 노드는 whole-node 보호를 유지한다.
        if($entry.Class-ne'Managed' -or $PreservedUnmanagedPaths-ccontains$entry.Key){continue}
        $nodes=@($entry.Node.SelectNodes('altemulator'))
        if($nodes.Count-gt1){throw 'altemulator 중복'}
        if(-not$nodes.Count -or $IsArcade){continue}
        $value=$nodes[0].InnerText
        if($value-notmatch'\(Standalone\)'){
            [void]$entry.Node.RemoveChild($nodes[0]);$changed=$true;continue
        }
        $confirmed=@($Mappings|Where-Object {$_.System-ieq$System})
        if(@($confirmed|Where-Object {$_.Android-ceq$value}).Count){continue}
        $matches=@($confirmed|Where-Object {$_.Linux-ceq$value})
        if($matches.Count-ne1){
            if($Warning){& $Warning ('미확정 altemulator mapping: '+$System+' / '+$value)|Out-Null}
            throw ('미확정 standalone mapping: '+$System+' / '+$value)
        }
        $nodes[0].InnerText=$matches[0].Android;$changed=$true
    }
    $result.Bytes=if($changed){ConvertTo-EsdeGamelistBytes $result}else{$Gamelist.Bytes}
    return $result
}

function Get-UnregisteredAdoptionPath([string]$System,[string]$RelativePath,[string[]]$SelectedSystems) {
    if($System-notmatch'^[a-zA-Z0-9_-]+$' -or $SelectedSystems-cnotcontains$System){throw 'adoption 선택 시스템 밖'}
    if($System-match'^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or $System-in@('_TEST','_UNREGISTERED')){throw 'adoption 시스템 이름 안전 오류'}
    if(-not$RelativePath -or $RelativePath-match'^[\\/]|:|[\x00-\x1f\x7f]'){throw 'adoption 상대 경로 오류'}
    $relative=$RelativePath.Replace('\','/')
    if($relative.StartsWith('./')){$relative=$relative.Substring(2)}
    $parts=@($relative-split'/')
    if($parts.Count-lt2 -or $parts[0]-ine'_UNREGISTERED'){throw '_UNREGISTERED inbox만 채택 가능'}
    foreach($part in $parts){
        if($part-in@('','.','..') -or $part-match'[<>:"|?*]|[ .]$' -or $part-match'^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)'){throw 'adoption Windows/path 안전 규칙 위반'}
    }
    $destination=$parts[1..($parts.Count-1)]-join'/'
    if(@($parts[1..($parts.Count-1)]|Where-Object {$_-ieq'_TEST' -or $_-ieq'_UNREGISTERED'}).Count){throw '중첩 예약 경로 채택 금지'}
    return [pscustomobject]@{System=$System;InboxPath='./'+$relative;ManagedPath='./'+$destination;DestinationRelativePath=$destination}
}

function New-UnregisteredAdoptionPlan([object[]]$Candidates,[object[]]$Destinations,[string[]]$SelectedSystems,[hashtable]$RomExtensions=@{gb=@('.gb','.gbc','.dmg','.gbx','.bs','.cgb','.sgb','.sfc','.smc','.zip','.7z');gbc=@('.gb','.gbc','.dmg','.gbx','.bs','.cgb','.sgb','.sfc','.smc','.zip','.7z')}) {
    # 전달된 hash snapshot만 검증한다. ROM 읽기/쓰기/pull/delete는 수행하지 않는다.
    $destinationMap=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($destination in $Destinations){
        $info=Get-UnregisteredAdoptionPath $destination.System ('_UNREGISTERED/'+$destination.RelativePath) $SelectedSystems
        $key=$info.System+'/'+$info.DestinationRelativePath
        if($destination.Sha256-notmatch'^[a-fA-F0-9]{64}$' -or $destinationMap.ContainsKey($key)){throw 'Dropbox snapshot hash/중복 오류'}
        $destinationMap.Add($key,$destination)
    }
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $plan=New-Object 'Collections.Generic.List[object]'
    foreach($candidate in $Candidates){
        $info=Get-UnregisteredAdoptionPath $candidate.System $candidate.RelativePath $SelectedSystems
        if(-not$RomExtensions.ContainsKey($candidate.System) -or $RomExtensions[$candidate.System]-notcontains[IO.Path]::GetExtension($info.DestinationRelativePath)){throw '확인된 ES-DE ROM extension 밖'}
        $key=$info.System+'/'+$info.DestinationRelativePath
        if(-not$seen.Add($key)){throw 'adoption 목적지 대소문자 충돌'}
        if($candidate.AndroidSha256-notmatch'^[a-fA-F0-9]{64}$' -or $candidate.StagedSha256-notmatch'^[a-fA-F0-9]{64}$' -or $candidate.AndroidSha256-ine$candidate.StagedSha256){throw 'adoption pull/hash 검증 실패'}
        $action='InstallNew';$canonical=$info.DestinationRelativePath
        if($destinationMap.ContainsKey($key)){
            if($destinationMap[$key].Sha256-ine$candidate.StagedSha256){throw ('adoption 목적지 SHA 충돌: '+$key)}
            $action='ReuseIdentical'
            # Windows 동일 경로의 기존 실제 표기를 사용해 Android case-sensitive ROM/path를 맞춘다.
            $canonical=$destinationMap[$key].RelativePath.Replace('\','/')
        }
        $plan.Add([pscustomobject]@{System=$info.System;InboxPath=$info.InboxPath;ManagedPath='./'+$canonical;DestinationRelativePath=$canonical;Sha256=$candidate.StagedSha256.ToLowerInvariant();Action=$action;RemoveAndroidSource=$false})
    }
    return @($plan.ToArray())
}

function New-AdoptionGamePromotion([System.Xml.XmlElement]$AndroidInbox,[string]$ManagedPath,[System.Xml.XmlElement]$DropboxManaged,[System.Xml.XmlElement]$AndroidManaged) {
    # 순수 node proposal. ROM 성공/journal 검증 및 파일 교체는 이 함수 밖의 Stage 2 책임.
    $target=Get-EsdeGamePathInfo $ManagedPath
    if($target.Class-ne'Managed'){throw 'adoption 승격 target은 managed path여야 함'}
    if($AndroidInbox){
        $old=Get-EsdeGamePathInfo $AndroidInbox.SelectSingleNode('path').InnerText
        if($old.Class-ne'LocalUnregistered'){throw 'adoption metadata는 _UNREGISTERED만'}
        $prefix='./_UNREGISTERED/'
        if(-not$old.Key.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not[string]::Equals($target.Key,('./'+$old.Key.Substring($prefix.Length)),[StringComparison]::OrdinalIgnoreCase)){throw 'inbox/정식 path 승격 관계 불일치'}
    }
    if($AndroidManaged -and $AndroidInbox){
        foreach($tag in @('playcount','lastplayed','playtime')){
            $a=$AndroidManaged.SelectSingleNode($tag);$b=$AndroidInbox.SelectSingleNode($tag)
            if(($null-ne$a)-ne($null-ne$b) -or ($a -and $a.InnerText-cne$b.InnerText)){throw 'Android 정식/예약 path runtime 충돌'}
        }
    }
    foreach($node in @($DropboxManaged,$AndroidManaged)|Where-Object {$_}){
        if((Get-EsdeGamePathInfo $node.SelectSingleNode('path').InnerText).Key-cne$target.Key){throw '정식 game target path 불일치'}
    }
    if(-not$AndroidInbox -and -not$DropboxManaged){return [pscustomobject]@{DropboxNode=$null;AndroidNode=$null;NeedsPolicyDecision=$false;CreateGame=$false}}
    $source=if($DropboxManaged){$DropboxManaged.CloneNode($true)}else{$AndroidInbox.CloneNode($true)}
    $source.SelectSingleNode('path').InnerText=$target.Key
    $pending=@(if($AndroidInbox){$AndroidInbox.ChildNodes|Where-Object {$_.NodeType-eq[Xml.XmlNodeType]::Element -and $_.Name-in@('favorite','hidden','kidgame','broken','completed','hidemetadata','altemulator','image','thumbnail','marquee','fanart','video','manual','controller','screen','nomultiscrape','nogamecount','collectionsortname','sortname','platform','emulator','core','androidPackage')}|ForEach-Object Name})
    if($AndroidInbox){
        foreach($child in @($AndroidInbox.ChildNodes|Where-Object {$_.NodeType-eq[Xml.XmlNodeType]::Element -and $_.Name-notin@('path','name','desc','playcount','playtime','lastplayed')})){
            if($child.OuterXml-match'(?i)(/storage/|/home/|[A-Z]:\\)'){$pending+=@($child.Name)}
        }
        $pending=@($pending|Sort-Object -Unique)
    }
    if(-not$DropboxManaged){
        # 기기 플레이 기록은 공유 DB의 새 node로 승격시키지 않는다.
        foreach($tag in @('playcount','lastplayed','playtime')){foreach($node in @($source.SelectNodes($tag))){[void]$source.RemoveChild($node)}}
        # 공유 여부가 미확정인 preference/platform/media field가 있으면 실제 commit을 차단해야 한다.

    }
    $android=if($DropboxManaged){$source.CloneNode($true)}else{$AndroidInbox.CloneNode($true)}
    $android.SelectSingleNode('path').InnerText=$target.Key
    if($AndroidInbox){[void](Merge-EsdeRuntimeGameTags $android $AndroidInbox)}
    return [pscustomobject]@{DropboxNode=$source;AndroidNode=$android;NeedsPolicyDecision=($pending.Count-gt0);PendingFields=$pending;CreateGame=$true}
}

function Get-AdoptionSourceRemovalDecision([string]$State,[bool]$DropboxRomVerified,[bool]$DropboxGamelistVerified,[bool]$AndroidGamelistVerified,[bool]$SourceUnchanged,[bool]$AndroidManagedRomVerified=$false,[bool]$PolicyResolved=$false) {
    return ($State-ceq'android-gamelist-installed' -and $DropboxRomVerified -and $DropboxGamelistVerified -and $AndroidGamelistVerified -and $SourceUnchanged -and $AndroidManagedRomVerified -and $PolicyResolved)
}

function Get-AdoptionResumeDisposition([string]$State) {
    if($State-ceq'completed'){return 'VerifyCompleted'}
    if($State-in@('discovered','staged','source-verified','dropbox-installed','gamelist-prepared','dropbox-gamelist-installed','android-rom-installed','android-gamelist-installed','android-source-removed','failed')){return 'BlockedManualReview'}
    throw '알 수 없는 adoption journal state'
}

function Merge-EsdeGamelist($Base,$Local,[scriptblock]$Warning,[string[]]$PreservedUnmanagedPaths=@()) {
    $warnings=New-Object 'Collections.Generic.List[string]'
    $emit={param($message)$warnings.Add($message);if($Warning){& $Warning $message|Out-Null}}.GetNewClosure()
    $baseEntries=@(Get-EsdeGameEntries $Base $emit)
    $unmanaged=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($path in $PreservedUnmanagedPaths){
        $info=Get-EsdeGamePathInfo $path
        if($info.Class-ne'Managed'){throw 'unmanaged preservation path 오류'}
        [void]$unmanaged.Add($info.Key)
    }
    $localEntries=@(Get-EsdeGameEntries $Local $emit|Where-Object {$_.Class-in@('LocalTest','LocalUnregistered') -or $unmanaged.Contains($_.Key)})
    $localAlternative=@(if($Local){$Local.Document.DocumentElement.SelectNodes('alternativeEmulator')})
    if($localAlternative.Count-gt1){throw 'Android alternativeEmulator 중복'}
    if($null-eq$Base -and $localEntries.Count-eq0 -and $localAlternative.Count-eq0){return $null}
    $template=if($null-ne$Base){$Base}else{$Local}
    $result=ConvertFrom-EsdeGamelistBytes $template.Bytes 'merge copy'
    $result.Document=$template.Document.CloneNode($true)
    $root=$result.Document.DocumentElement
    $list=$root.SelectSingleNode('gameList')
    if(-not$list){$list=$result.Document.CreateElement('gameList');[void]$root.AppendChild($list)}
    $changed=($null-eq$Base)
    if($localAlternative.Count-eq1){
        $baseAlternative=@($root.SelectNodes('alternativeEmulator'))
        if($baseAlternative.Count-gt1){throw '관리본 alternativeEmulator 중복'}
        $imported=$result.Document.ImportNode($localAlternative[0],$true)
        if($baseAlternative.Count-eq1){
            if($baseAlternative[0].OuterXml-cne$imported.OuterXml){[void]$root.ReplaceChild($imported,$baseAlternative[0]);$changed=$true}
        }else{[void]$root.InsertBefore($imported,$list);$changed=$true}
    }
    # Android 파일만 있을 때는 normal metadata를 승격시키지 않는다.
    if($null-eq$Base){foreach($node in @($list.ChildNodes)){[void]$list.RemoveChild($node)}}
    $keys=New-Object 'Collections.Generic.Dictionary[string,System.Xml.XmlElement]' ([StringComparer]::Ordinal)
    foreach($node in @($list.SelectNodes('game'))){
        $info=Get-EsdeGamePathInfo $node.SelectSingleNode('path').InnerText
        if($info.Class-ne'Managed'){& $emit ('Dropbox local-only 경로 발견: '+$info.Key)}
        if($keys.ContainsKey($info.Key)){
            [void]$list.RemoveChild($node);$changed=$true;& $emit ('Dropbox 중복 path: '+$info.Key)
        }else{$keys.Add($info.Key,$node)}
    }
    # 일반 노드는 Dropbox 기준을 유지하고 Android runtime 3개 태그만 이식한다.
    $managedKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($entry in @(Get-EsdeGameEntries $Local $emit|Where-Object Class -eq Managed)){
        if(-not$managedKeys.Add($entry.Key)){throw ('Android managed path 중복: '+$entry.Key)}
        if($keys.ContainsKey($entry.Key) -and (Merge-EsdeRuntimeGameTags $keys[$entry.Key] $entry.Node)){$changed=$true}
    }
    $localKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($entry in $localEntries){
        if(-not$localKeys.Add($entry.Key)){& $emit ('Android local-only 중복 path, 첫 항목 보존: '+$entry.Key);continue}
        if($entry.Class-eq'Managed' -and $keys.ContainsKey($entry.Key)){throw 'unmanaged/master path 분류 충돌'}
        $imported=$result.Document.ImportNode($entry.Node,$true)
        if($keys.ContainsKey($entry.Key)){
            & $emit ('local-only 충돌: Android 우선 '+$entry.Key)
            [void]$list.ReplaceChild($imported,$keys[$entry.Key]);$keys[$entry.Key]=$imported
        }else{
            [void]$list.AppendChild($result.Document.CreateWhitespace($template.Newline))
            [void]$list.AppendChild($imported);$keys.Add($entry.Key,$imported)
        }
        $changed=$true
    }
    $result.Bytes=if($changed){ConvertTo-EsdeGamelistBytes $result}else{$template.Bytes}
    [void](ConvertFrom-EsdeGamelistBytes $result.Bytes 'merge verification')
    $result|Add-Member -NotePropertyName Warnings -NotePropertyValue @($warnings.ToArray())
    $result|Add-Member -NotePropertyName InputPaths -NotePropertyValue @($Base.Source,$Local.Source|Where-Object {$_})
    return $result
}

function New-RomPreservationContext([string]$StateRoot,[string]$LibraryRoot,[string]$DeviceSerial) {
    $root=[IO.Path]::GetFullPath($LibraryRoot).TrimEnd('\')
    $identity=Get-MediaTextHash ($root.ToLowerInvariant()+'|'+$DeviceSerial)
    $file=Join-Path (Join-Path $StateRoot 'managed-rom-paths') ($identity+'.json')
    [void](Assert-MediaDiskPath $file $StateRoot)
    $record=[pscustomobject]@{schemaVersion=1;identity=$identity;entries=@()}
    if([IO.File]::Exists($file)){
        $record=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json
        if($record.schemaVersion-ne1 -or $record.identity-cne$identity -or $record.entries-isnot[Array]){throw 'ROM preservation State 불일치'}
        $keys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $record.entries){
            [void](Get-MediaRelativePath $entry.relativePath)
            if($entry.system-notmatch'^[a-zA-Z0-9_-]+$' -or (Is-ExcludedRelativePath $entry.relativePath)){throw 'ROM preservation path 오류'}
            if(-not$keys.Add($entry.system+'/'+$entry.relativePath)){throw 'ROM preservation 중복 key'}
        }
    }
    return [pscustomobject]@{File=$file;StateRoot=$StateRoot;Record=$record}
}
function Prepare-RomPreservationPlan($Job,$Context) {
    $source=@(Get-ManagedLocalItems $Job.LocalPath $SourceRoot|Where-Object {-not$_.PSIsContainer}|ForEach-Object {$_.FullName.Substring($Job.LocalPath.Length).TrimStart('\','/').Replace('\','/')})
    $known=@($Context.Record.entries|Where-Object system -CEQ $Job.System|ForEach-Object relativePath)
    $managed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($p in @($source+$known)){[void]$managed.Add($p)}
    $remote=@(Get-RemoteFiles $Job.RemotePath)
    $unmanaged=@($remote|Where-Object {-not$managed.Contains($_)})
    $managedDirs=@($source+$known|ForEach-Object {
        $parts=$_.Split('/')
        for($i=1;$i-lt$parts.Length;$i++){($parts[0..($i-1)]-join'/')}
    }|Sort-Object -Unique)
    return [pscustomobject]@{System=$Job.System;RemotePath=$Job.RemotePath;Managed=$managed;ManagedDirs=$managedDirs;Unmanaged=$unmanaged;Source=$source}
}
function Sync-PreservedRomSystem($Job,$Plan,$Context,[string]$Label) {
    if($Job.System-cne$Plan.System -or $Job.RemotePath-cne$Plan.RemotePath){throw 'ROM preservation 범위 오류'}
    $files=(Get-Item Function:Get-RemoteFiles).ScriptBlock;$dirs=(Get-Item Function:Get-RemoteDirs).ScriptBlock
    $allowed=$Plan.Managed;$allowedDirs=$Plan.ManagedDirs;$root=$Plan.RemotePath
    $fileFilter={param($path)if($path-cne$root){throw 'ROM remote scope mismatch'}; & $files $path|Where-Object {$allowed.Contains($_)}}.GetNewClosure()
    $dirFilter={param($path)if($path-cne$root){throw 'ROM remote scope mismatch'}; & $dirs $path|Where-Object {$allowedDirs-ccontains$_}}.GetNewClosure()
    Set-Item -Path Function:local:Get-RemoteFiles -Value $fileFilter
    Set-Item -Path Function:local:Get-RemoteDirs -Value $dirFilter
    Mirror-SystemFolder $Job.LocalPath $Job.RemotePath $Label
    $other=@($Context.Record.entries|Where-Object system -CNE $Job.System)
    $current=@(Get-ManagedLocalItems $Job.LocalPath $SourceRoot|Where-Object {-not$_.PSIsContainer}|ForEach-Object {
        [pscustomobject]@{system=$Job.System;relativePath=$_.FullName.Substring($Job.LocalPath.Length).TrimStart('\','/').Replace('\','/')}
    })
    $Context.Record.entries=@($other+$current)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Context.File))
    Write-MediaJson $Context.File $Context.Record $Context.StateRoot
}
function Initialize-AdoptionAccessCheck {
    if('EsdeAdoptionAccess'-as[type]){return}
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class EsdeAdoptionAccess {
 [StructLayout(LayoutKind.Sequential)] public struct Mapping { public uint Read,Write,Execute,All; }
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateToken(IntPtr token,int level,out IntPtr copy);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool AccessCheck(byte[] sd,IntPtr token,uint desired,ref Mapping mapping,IntPtr privileges,ref uint size,out uint granted,out bool allowed);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 public static bool Check(byte[] sd,uint desired) {
  using(var identity=WindowsIdentity.GetCurrent()) {
   IntPtr token; if(!DuplicateToken(identity.Token,2,out token))throw new Win32Exception(Marshal.GetLastWin32Error());
   try {
    var mapping=new Mapping{Read=0x120089,Write=0x120116,Execute=0x1200A0,All=0x1F01FF};
    uint size=1024,granted;bool allowed;IntPtr buffer=Marshal.AllocHGlobal((int)size);
    try {
     if(!AccessCheck(sd,token,desired,ref mapping,buffer,ref size,out granted,out allowed))throw new Win32Exception(Marshal.GetLastWin32Error());
     return allowed;
    } finally {Marshal.FreeHGlobal(buffer);}
   } finally {CloseHandle(token);}
  }
 }
}
"@
}

function Test-AdoptionSecurityAccess([byte[]]$Descriptor,[uint32]$Mask) {
    try{
        Initialize-AdoptionAccessCheck
        $raw=New-Object Security.AccessControl.RawSecurityDescriptor($Descriptor,0)
        # 지원 범위를 명시적으로 제한. callback/object ACE, 비canonical DACL은 UNKNOWN.
        $acl=New-Object Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorBinaryForm($Descriptor)
        if(-not$raw.Owner -or -not$raw.Group -or -not$acl.AreAccessRulesCanonical){throw 'unsupported/noncanonical security descriptor'}
        foreach($ace in $raw.DiscretionaryAcl){
            if($ace-isnot[Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceQualifier-notin@('AccessAllowed','AccessDenied')){throw 'unsupported ACE'}
        }
        $allowed=[EsdeAdoptionAccess]::Check($Descriptor,$Mask)
        $blocking=@()
        if(-not$allowed){
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try{
                $sids=@($identity.User.Value)+@($identity.Groups|ForEach-Object Value)
                foreach($ace in $raw.DiscretionaryAcl){
                    if($ace.AceQualifier-eq'AccessDenied' -and -not(([int]$ace.AceFlags)-band[int][Security.AccessControl.AceFlags]::InheritOnly) -and ($ace.AccessMask-band$Mask) -and $sids-contains$ace.SecurityIdentifier.Value){
                        $blocking+=[pscustomobject]@{Sid=$ace.SecurityIdentifier.Value;Mask=('0x{0:X}'-f$ace.AccessMask);Inherited=[bool](([int]$ace.AceFlags)-band[int][Security.AccessControl.AceFlags]::Inherited)}
                    }
                }
            }finally{$identity.Dispose()}
        }
        return [pscustomobject]@{Result=$(if($allowed){'Allowed'}else{'Denied'});Mask=$Mask;BlockingAce=$blocking;Reason='Windows AccessCheck';Allowed=$allowed}
    }catch{return [pscustomobject]@{Result='Unknown';Mask=$Mask;BlockingAce=@();Reason=$_.Exception.Message;Allowed=$false}}
}

function Get-AdoptionInheritedDescriptor([byte[]]$Descriptor,[bool]$Directory) {
    $raw=New-Object Security.AccessControl.RawSecurityDescriptor($Descriptor,0)
    $acl=New-Object Security.AccessControl.RawAcl(2,0)
    foreach($ace in $raw.DiscretionaryAcl){
        if($ace-isnot[Security.AccessControl.CommonAce] -or $ace.IsCallback){throw 'unsupported inherited ACE'}
        if($Directory -and (([int]$ace.AceFlags)-band1) -and -not(([int]$ace.AceFlags)-band2)){throw 'object-only directory pass-through inheritance unsupported'}
        $flag=if($Directory){[Security.AccessControl.AceFlags]::ContainerInherit}else{[Security.AccessControl.AceFlags]::ObjectInherit}
        if(-not(([int]$ace.AceFlags)-band([int]$flag))){continue}
        $sid=$ace.SecurityIdentifier
        if($sid.Value-ceq'S-1-3-1'){throw 'creator-group inheritance prediction unsupported'}
        if($sid.Value-ceq'S-1-3-0'){$ownerIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$ownerIdentity.User}finally{$ownerIdentity.Dispose()}}
        $flags=[Security.AccessControl.AceFlags]::Inherited
        if($Directory -and -not(([int]$ace.AceFlags)-band[int][Security.AccessControl.AceFlags]::NoPropagateInherit)){
            $flags=[Security.AccessControl.AceFlags](([int]$flags)-bor(([int]$ace.AceFlags)-band(1-bor2)))
        }
        $copy=New-Object Security.AccessControl.CommonAce($flags,$ace.AceQualifier,$ace.AccessMask,$sid,$false,$null)
        $acl.InsertAce($acl.Count,$copy)
    }
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$result=New-Object Security.AccessControl.RawSecurityDescriptor([Security.AccessControl.ControlFlags]::DiscretionaryAclPresent,$id.User,$raw.Group,$null,$acl)}
    finally{$id.Dispose()}
    $bytes=New-Object byte[] $result.BinaryLength;$result.GetBinaryForm($bytes,0);return ,$bytes
}

function Get-AdoptionDiskDescriptor([string]$Path,[bool]$Directory=$false) {
    $full=[IO.Path]::GetFullPath($Path)
    if(Test-Path -LiteralPath $full){
        $item=Get-Item -LiteralPath $full -Force
        if($Directory-ne[bool]$item.PSIsContainer){throw 'capability object type mismatch'}
        return ,(Get-Acl -LiteralPath $full).GetSecurityDescriptorBinaryForm()
    }
    $parent=Split-Path -Parent $full
    if(-not$parent -or $parent-ceq$full){throw 'capability parent unknown'}
    $parentDescriptor=Get-AdoptionDiskDescriptor $parent $true
    return ,(Get-AdoptionInheritedDescriptor $parentDescriptor $Directory)
}

function Get-AdoptionRequiredCapabilities($Plan) {
    foreach($entry in $Plan.Entries){
        if(-not$entry.DestinationHash){[pscustomobject]@{Path=$entry.DropboxPath;Kind='CreateRom';RequiresWrite=$true}}
        else{[pscustomobject]@{Path=$entry.DropboxPath;Kind='ReadRom';RequiresWrite=$false}}
    }
    foreach($system in $Plan.Systems){
        if($system.SharedOutput){[pscustomobject]@{Path=$system.DropboxGamelist;Kind=$(if($system.DropboxHash){'ReplaceXml'}else{'CreateXml'});RequiresWrite=$true}}
    }
}

function Test-AdoptionDestinationCapability([string]$Path,[string]$Kind) {
    $checks=@();$required=@();$missing=@();$unknown=$false
    try{
        if($Kind-ceq'ReadRom'){
            $r=Test-AdoptionSecurityAccess (Get-AdoptionDiskDescriptor $Path $false) 0x120089
            return [pscustomobject]@{Path=$Path;Kind=$Kind;Result=$r.Result;CanReadFile=($r.Result-eq'Allowed');CanCreateFile=$null;CanWriteExistingFile=$null;CanDeleteFile=$null;CanDeleteChild=$null;CanCreateDirectory=$null;CanRenameOrReplace=$null;RequiredCapabilities=@('CanReadFile');MissingCapabilities=@(if($r.Result-ne'Allowed'){'CanReadFile'});BlockingAce=$r.BlockingAce;Reason=$r.Reason;VolumeStatus='NotRequired';FreeSpaceStatus='NotRequired'}
        }
        $parent=Split-Path -Parent $Path
        $parentSd=Get-AdoptionDiskDescriptor $parent $true
        $fileSd=Get-AdoptionDiskDescriptor $Path $false
        $stagingSd=Get-AdoptionInheritedDescriptor $parentSd $false
        $masks=[ordered]@{CanCreateFile=@($parentSd,2);CanWriteExistingFile=@($fileSd,0x120116);CanDeleteFile=@($fileSd,65536);CanDeleteChild=@($parentSd,64);CanCreateDirectory=@($parentSd,4);CanReadFile=@($fileSd,0x120089);CanWriteStagingFile=@($stagingSd,0x12019F);CanDeleteStagingFile=@($stagingSd,65536)}
        $values=@{}
        foreach($name in $masks.Keys){
            $r=Test-AdoptionSecurityAccess $masks[$name][0] $masks[$name][1]
            $values[$name]=($r.Result-eq'Allowed');$checks+=[pscustomobject]@{Capability=$name;Result=$r.Result;BlockingAce=$r.BlockingAce;Reason=$r.Reason}
        }
        if($Kind-ceq'ReadRom'){$required=@('CanReadFile')}
        else{
            $required=@('CanCreateFile','CanReadFile','CanWriteExistingFile','CanWriteStagingFile')
            # staging 파일 삭제/rename에는 파일 DELETE 또는 parent DELETE_CHILD 중 하나.
            $values.CanRenameOrReplace=(($values.CanDeleteStagingFile-or$values.CanDeleteChild) -and ($Kind-cne'ReplaceXml' -or $values.CanDeleteFile-or$values.CanDeleteChild))
            $checks+=[pscustomobject]@{Capability='CanRenameOrReplace';Result=$(if($values.CanRenameOrReplace){'Allowed'}elseif(@($checks|Where-Object {$_.Capability-in@('CanDeleteFile','CanDeleteChild','CanDeleteStagingFile') -and $_.Result-eq'Unknown'}).Count){'Unknown'}else{'Denied'});BlockingAce=@($checks|Where-Object Capability -IN @('CanDeleteFile','CanDeleteChild','CanDeleteStagingFile')|ForEach-Object BlockingAce);Reason='DELETE or DELETE_CHILD'}
            $required+=@('CanRenameOrReplace')
            if(-not(Test-Path -LiteralPath $parent)){
                # 없는 directory chain의 각 기존/예측 parent에 mkdir 권한 필요.
                $cursor=$parent
                while(-not(Test-Path -LiteralPath $cursor)){
                    $p=Split-Path -Parent $cursor
                    $r=Test-AdoptionSecurityAccess (Get-AdoptionDiskDescriptor $p $true) 4
                    $name='CreateDirectory:'+ $cursor;$required+=@($name)
                    $checks+=[pscustomobject]@{Capability=$name;Result=$r.Result;BlockingAce=$r.BlockingAce;Reason=$r.Reason}
                    $cursor=$p
                }
            }
            if($Kind-ceq'ReplaceXml'){
                # 현재 목적지와 새 staging이 모두 write/read 가능한지 확인.
                $required+=@('CanWriteExistingFile')
            }
        }
        foreach($name in $required){
            $r=@($checks|Where-Object Capability -CEQ $name)[0]
            if($r.Result-ne'Allowed'){$missing+=@($name);if($r.Result-eq'Unknown'){$unknown=$true}}
        }
        $result=if($unknown){'Unknown'}elseif($missing.Count){'Denied'}else{'Allowed'}
        return [pscustomobject]@{Path=$Path;Kind=$Kind;Result=$result;CanCreateFile=$values.CanCreateFile;CanWriteExistingFile=$values.CanWriteExistingFile;CanDeleteFile=$values.CanDeleteFile;CanDeleteChild=$values.CanDeleteChild;CanCreateDirectory=$values.CanCreateDirectory;CanRenameOrReplace=$values.CanRenameOrReplace;RequiredCapabilities=$required;MissingCapabilities=$missing;BlockingAce=@($checks|Where-Object {$missing-contains$_.Capability}|ForEach-Object BlockingAce);Checks=$checks;VolumeStatus='NotChecked';FreeSpaceStatus='NotChecked';SameVolumeDesign='DestinationSibling'}
    }catch{return [pscustomobject]@{Path=$Path;Kind=$Kind;Result='Unknown';RequiredCapabilities=@($Kind);MissingCapabilities=@($Kind);BlockingAce=@();Reason=$_.Exception.Message;VolumeStatus='NotChecked';FreeSpaceStatus='NotChecked'}}
}

function Test-AdoptionPlanCapability($Plan) {
    $results=@(Get-AdoptionRequiredCapabilities $Plan|ForEach-Object {Test-AdoptionDestinationCapability $_.Path $_.Kind})
    $state=if(@($results|Where-Object Result -EQ Unknown).Count){'Unknown'}elseif(@($results|Where-Object Result -EQ Denied).Count){'Denied'}else{'Allowed'}
    return [pscustomobject]@{Result=$state;Allowed=($state-eq'Allowed');Destinations=$results;RequiredCapabilities=@($results|ForEach-Object RequiredCapabilities);MissingCapabilities=@($results|ForEach-Object MissingCapabilities)}
}

function Read-AdoptionObservation([string]$Path,[bool]$Remote) {
    try{
        if(-not$Remote){
            if(-not(Test-Path -LiteralPath $Path)){return [pscustomobject]@{State='Absent';Sha256=''}}
            $item=Get-Item -LiteralPath $Path -Force
            if($item.PSIsContainer -or ($item.Attributes-band[IO.FileAttributes]::ReparsePoint)){
                # cloud placeholder 검증은 기존 안전 검사로 수행.
                Assert-LocalSourcePath $Path $SourceRoot
                if($item.PSIsContainer){throw 'not a file'}
            }
            return [pscustomobject]@{State='Present';Sha256=(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}
        }
        Assert-RemotePath $Path
        $q=Quote-Sh $Path;$checks=''
        $checks='cd /storage/emulated/0 || exit 1; '
        $parts=$Path.Split('/')
        for($i=4;$i-lt$parts.Length-1;$i++){
            $parent=Quote-Sh ($parts[0..$i]-join'/')
            $checks+='if [ -L '+$parent+' ]; then exit 1; elif [ -d '+$parent+' ]; then cd '+$parent+' || exit 1; elif [ -e '+$parent+' ]; then exit 1; else printf ABSENT; exit 0; fi; '
        }
        $checks+='[ ! -L '+$q+' ] || exit 1; '
        $r=Invoke-Adb -s $Serial shell ($checks+'if [ -f '+$q+' ]; then printf PRESENT; elif [ -e '+$q+' ]; then exit 1; else printf ABSENT; fi')
        if($r.Code-ne0 -or $r.StdErr -or $r.StdOut-cnotin@('PRESENT','ABSENT')){throw 'remote state unknown'}
        if($r.StdOut-ceq'ABSENT'){return [pscustomobject]@{State='Absent';Sha256=''}}
        foreach($command in @('sha256sum ','toybox sha256sum ')){
            $r=Invoke-Adb -s $Serial shell ($command+$q)
            if($r.Code-eq0 -and -not$r.StdErr -and $r.StdOut.TrimEnd([char]13,[char]10)-match('^([a-fA-F0-9]{64})  '+[regex]::Escape($Path)+'$')){
                return [pscustomobject]@{State='Present';Sha256=$matches[1].ToLowerInvariant()}
            }
        }
        throw 'read-only remote hash unsupported'
    }catch{return [pscustomobject]@{State='Unknown';Sha256='';Reason=$_.Exception.Message}}
}

function Read-AdoptionRemoteResidue([string]$Path,[string]$Suffix='.esde-adoption-*') {
    try{
        Assert-RemotePath $Path
        $parent=$Path.Substring(0,$Path.LastIndexOf('/'));$leaf=$Path.Substring($Path.LastIndexOf('/')+1)
        $q=Quote-Sh $parent
        $cmd='if [ -L '+$q+' ]; then exit 1; elif [ -d '+$q+' ]; then cd '+$q+' || exit 1; find '+$q+' -maxdepth 1 -name '+(Quote-Sh ($leaf+$Suffix))+' \( -type f -o -type l \) -print; elif [ -e '+$q+' ]; then exit 1; fi'
        $r=Invoke-Adb -s $Serial shell $cmd
        if($r.Code-ne0 -or $r.StdErr){throw 'remote residue lookup failed'}
        return [pscustomobject]@{State='Known';Paths=@($r.StdOut-split'\r?\n'|Where-Object {$_})}
    }catch{return [pscustomobject]@{State='Unknown';Paths=@();Reason=$_.Exception.Message}}
}
function Assert-AdoptionJournalSchema($Journal,$Context,[string]$FileName) {
    foreach($name in @('schemaVersion','identity','transactionId','state','completed','entries','history','createdAt','updatedAt')){
        if($Journal.PSObject.Properties.Name-cnotcontains$name){throw ('journal missing '+$name)}
    }
    if($Journal.schemaVersion-ne1 -or $Journal.schemaVersion-isnot[int] -or $Journal.completed-isnot[bool] -or $Journal.identity-cne$Context.Identity -or $Journal.transactionId-cnotmatch'^[a-f0-9]{32}$' -or $FileName-cne($Journal.transactionId+'.json') -or $Journal.entries-isnot[Array] -or @($Journal.entries).Count-eq0 -or $Journal.history-isnot[Array]){throw 'journal schema/identity'}
    $states=@('staged','source-verified','dropbox-installed','gamelist-prepared','dropbox-gamelist-installed','android-rom-installed','android-gamelist-installed','android-source-removed','completed','failed')
    if($Journal.state-cnotin$states -or @($Journal.history).Count-eq0 -or $Journal.history[-1].state-cne$Journal.state -or $Journal.completed-ne($Journal.state-ceq'completed')){throw 'journal state/history mismatch'}
    foreach($stamp in @($Journal.createdAt,$Journal.updatedAt)+@($Journal.history|ForEach-Object at)){
        $date=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse([string]$stamp,[ref]$date)){throw 'journal timestamp'}
    }
    foreach($step in $Journal.history){if($step.state-cnotin$states){throw 'journal history unknown'}}
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $Journal.entries){
        $prefix='/storage/emulated/0/ROMs/'+$entry.System+'/'
        if(-not([string]$entry.InboxPath).StartsWith($prefix,[StringComparison]::Ordinal)){throw 'journal inbox scope'}
        $info=Get-UnregisteredAdoptionPath $entry.System $entry.InboxPath.Substring($prefix.Length) @($entry.System)
        $disk=Join-Path (Join-Path (Join-Path $Context.SourceRoot 'roms') $entry.System) $entry.RelativePath
        if(-not[string]::Equals($info.DestinationRelativePath,$entry.RelativePath,[StringComparison]::OrdinalIgnoreCase) -or $entry.DropboxPath-cne$disk -or $entry.AndroidPath-cne($prefix+$entry.RelativePath) -or $entry.Sha256-cnotmatch'^[a-f0-9]{64}$' -or -not$seen.Add($entry.System+'/'+$entry.RelativePath)){throw 'journal path/hash'}
        if($entry.PSObject.Properties.Name-cnotcontains'DestinationHash' -or ($entry.DestinationHash -and $entry.DestinationHash-cnotmatch'^[a-f0-9]{64}$')){throw 'journal destination baseline missing'}
    }
}

function Get-AdoptionInspection([string]$JournalPath,$Context,[string]$BaselinePath) {
    $evidence=@();$reason=@();$result='UNKNOWN';$journalHash='';$id=''
    try{
        [void](Assert-MediaDiskPath $JournalPath $Context.StateRoot)
        $j=Get-Content -LiteralPath $JournalPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-AdoptionJournalSchema $j $Context (Split-Path -Leaf $JournalPath)
        $id=$j.transactionId;$journalHash=(Get-FileHash -LiteralPath $JournalPath).Hash.ToLowerInvariant()
        $baseline=$null;$baselineHash=''
        if($BaselinePath){
            $baseline=Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8|ConvertFrom-Json
            $baselineHash=(Get-FileHash -LiteralPath $BaselinePath).Hash.ToLowerInvariant()
        }
        $systems=@($j.entries|ForEach-Object System|Sort-Object -Unique)
        $xmlBaseline=@()
        if($j.PSObject.Properties.Name-ccontains'systemSnapshots'){$xmlBaseline=@($j.systemSnapshots)}
        elseif($baseline -and $systems.Count-eq1 -and $systems[0]-ceq'gb' -and $baseline.Android-is[Array] -and $baseline.Dropbox-is[Array] -and $baseline.DropboxXmlSha-match'^[a-fA-F0-9]{64}$' -and $baseline.AndroidXmlSha-match'^[a-fA-F0-9]{64}$'){
            $xmlBaseline=@([pscustomobject]@{System='gb';DropboxHash=$baseline.DropboxXmlSha.ToLowerInvariant();AndroidHash=$baseline.AndroidXmlSha.ToLowerInvariant()})
        }else{throw 'missing gamelist baseline evidence'}
        $partial=$false;$mismatch=$false;$unknown=$false
        foreach($entry in $j.entries){
            $inbox=Read-AdoptionObservation $entry.InboxPath $true
            $pc=Read-AdoptionObservation $entry.DropboxPath $false
            $android=Read-AdoptionObservation $entry.AndroidPath $true
            $androidBefore=$null
            if($entry.PSObject.Properties.Name-ccontains'AndroidDestinationHash'){$androidBefore=[string]$entry.AndroidDestinationHash}
            elseif($baseline -and $baseline.Android-is[Array]){
                $old=@($baseline.Android|Where-Object Path -CEQ $entry.AndroidPath)
                if($old.Count-gt1){throw 'duplicate baseline ROM'}
                $androidBefore=if($old.Count){[string]$old[0].Sha256}else{''}
            }else{throw 'missing Android canonical baseline'}
            if($androidBefore -and $androidBefore-cnotmatch'^[a-f0-9]{64}$'){throw 'invalid Android baseline hash'}
            foreach($obs in @($inbox,$pc,$android)){if($obs.State-eq'Unknown'){$unknown=$true;$reason+=@($obs.Reason)}}
            if($inbox.State-ne'Unknown' -and ($inbox.State-ne'Present' -or $inbox.Sha256-cne$entry.Sha256)){$mismatch=$true}
            foreach($pair in @(@($pc,[string]$entry.DestinationHash),@($android,$androidBefore))){
                $obs=$pair[0];$oldHash=$pair[1]
                if($obs.State-eq'Unknown'){continue}
                if($oldHash){
                    if($obs.State-ne'Present' -or $obs.Sha256-cne$oldHash){$mismatch=$true}
                }elseif($obs.State-eq'Present'){
                    if($obs.Sha256-ceq$entry.Sha256){$partial=$true}else{$mismatch=$true}
                }
            }
            $residue=@(Get-ChildItem -LiteralPath (Split-Path -Parent $entry.DropboxPath) -File -ErrorAction Stop|Where-Object {$_.Name.StartsWith((Split-Path -Leaf $entry.DropboxPath)+'.esde-adoption-',[StringComparison]::Ordinal)})
            $remoteResidue=Read-AdoptionRemoteResidue $entry.AndroidPath
            $inboxResidue=Read-AdoptionRemoteResidue $entry.InboxPath
            if($residue.Count -or @($remoteResidue.Paths).Count -or @($inboxResidue.Paths).Count -or $remoteResidue.State-ne'Known' -or $inboxResidue.State-ne'Known'){$unknown=$true;$reason+=@('staging residue/lookup unknown')}
            $evidence+=[pscustomobject]@{System=$entry.System;InboxPath=$entry.InboxPath;CanonicalPath=$entry.RelativePath;ExpectedSha=$entry.Sha256;Inbox=$inbox;Dropbox=$pc;Android=$android;DropboxBefore=[string]$entry.DestinationHash;AndroidBefore=$androidBefore;Residue=@($residue|ForEach-Object Name)+@($remoteResidue.Paths)+@($inboxResidue.Paths)}
        }
        foreach($system in $systems){
            $snapshot=@($xmlBaseline|Where-Object System -CEQ $system)
            if($snapshot.Count-ne1){throw 'missing/duplicate XML baseline'}
            $snapshot=$snapshot[0]
            foreach($side in @('Dropbox','Android')){
                $old=[string]$snapshot.($side+'Hash')
                if($old -and $old-cnotmatch'^[a-f0-9]{64}$'){throw 'invalid XML baseline hash'}
                $path=if($side-eq'Dropbox'){Join-Path (Join-Path (Join-Path $Context.SourceRoot 'gamelists') $system) 'gamelist.xml'}else{'/storage/emulated/0/ES-DE/gamelists/'+$system+'/gamelist.xml'}
                $obs=Read-AdoptionObservation $path ($side-eq'Android')
                if($side-eq'Android'){
                    $xmlResidue=Read-AdoptionRemoteResidue $path '.esde-sync-new-*'
                    if($xmlResidue.State-ne'Known' -or @($xmlResidue.Paths).Count){$unknown=$true;$reason+=@('Android XML staging residue/unknown')}
                }else{
                    $dir=Split-Path -Parent $path
                    if(Test-Path -LiteralPath $dir){
                        $xmlResidue=@(Get-ChildItem -LiteralPath $dir -File|Where-Object {$_.Name.StartsWith('gamelist.xml.esde-adoption-',[StringComparison]::Ordinal)})
                        if($xmlResidue.Count){$unknown=$true;$reason+=@('Dropbox XML staging residue')}
                    }
                }
                if($obs.State-eq'Unknown'){$unknown=$true;$reason+=@($obs.Reason)}
                elseif(($old -and ($obs.State-ne'Present' -or $obs.Sha256-cne$old)) -or (-not$old -and $obs.State-ne'Absent')){$mismatch=$true}
                $evidence+=[pscustomobject]@{System=$system;Side=$side;GamelistPath=$path;Before=$old;Current=$obs}
            }
        }
        $late=@($j.history|Where-Object {$_.state-cnotin@('staged','source-verified','failed')}).Count-gt0
        $result=if($mismatch){'STATE_MISMATCH'}elseif($partial){'PARTIAL_COMMIT'}elseif($unknown){'UNKNOWN'}elseif($late -or $j.completed){'STATE_MISMATCH'}elseif($j.state-cne'failed'){$reason+=@('nonterminal journal: active/crashed state requires review');'UNKNOWN'}else{'NO_COMMIT_CONFIRMED'}
        $payload=[pscustomobject]@{JournalSha256=$journalHash;BaselineSha256=$baselineHash;Observations=$evidence;History=@($j.history)}
        $fingerprint=Get-MediaTextHash ($payload|ConvertTo-Json -Depth 20 -Compress)
        return [pscustomobject]@{Result=$result;TransactionId=$id;JournalPath=$JournalPath;JournalSha256=$journalHash;Identity=$Context.Identity;Evidence=$payload;EvidenceSha256=$fingerprint;Reasons=$reason}
    }catch{return [pscustomobject]@{Result='UNKNOWN';TransactionId=$id;JournalPath=$JournalPath;JournalSha256=$journalHash;Identity=$Context.Identity;Evidence=$evidence;Reasons=@($_.Exception.Message)}}
}

function Assert-AdoptionResolution($Resolution,$Journal,[string]$JournalSha,$Context) {
    foreach($name in @('schemaVersion','transactionId','identity','resolution','approved','approvedAt','approvedBy','reason','inspectorResult','journalSha256','evidence','evidenceSha256')){
        if($Resolution.PSObject.Properties.Name-cnotcontains$name){throw 'ADOPTION BLOCK: resolution missing field'}
    }
    $date=[DateTimeOffset]::MinValue
    if($Journal.state-cne'failed' -or $Journal.completed){throw 'ADOPTION BLOCK: only failed no-commit journal can be abandoned'}
    if($Resolution.schemaVersion-isnot[int] -or $Resolution.schemaVersion-ne1 -or $Resolution.transactionId-cne$Journal.transactionId -or $Resolution.identity-cne$Context.Identity -or $Resolution.resolution-cne'abandoned' -or $Resolution.approved-isnot[bool] -or -not$Resolution.approved -or -not$Resolution.approvedBy -or -not$Resolution.reason -or -not[DateTimeOffset]::TryParse([string]$Resolution.approvedAt,[ref]$date) -or $Resolution.inspectorResult-cne'NO_COMMIT_CONFIRMED' -or $Resolution.journalSha256-cne$JournalSha -or $Resolution.evidence.JournalSha256-cne$JournalSha){throw 'ADOPTION BLOCK: resolution schema/identity/evidence mismatch'}
    if((Get-MediaTextHash ($Resolution.evidence|ConvertTo-Json -Depth 20 -Compress))-cne$Resolution.evidenceSha256){throw 'ADOPTION BLOCK: resolution evidence fingerprint'}
    # 판정 결과 문자열만으로 폐기하지 않음: 관찰 내용과 baseline/hash를 다시 검증.
    if(($Resolution.evidence.History|ConvertTo-Json -Depth 8 -Compress)-cne($Journal.history|ConvertTo-Json -Depth 8 -Compress)){throw 'ADOPTION BLOCK: resolution history mismatch'}
    if(@($Resolution.evidence.History|Where-Object {$_.state-cnotin@('staged','source-verified','failed')}).Count){throw 'ADOPTION BLOCK: committed history resolution'}
    $rom=@($Resolution.evidence.Observations|Where-Object {$_.PSObject.Properties.Name-ccontains'InboxPath'})
    if($rom.Count-ne@($Journal.entries).Count){throw 'ADOPTION BLOCK: incomplete resolution observations'}
    foreach($entry in $Journal.entries){
        $obs=@($rom|Where-Object InboxPath -CEQ $entry.InboxPath)
        if($obs.Count-ne1){throw 'ADOPTION BLOCK: resolution ROM missing'}
        $obs=$obs[0]
        if($obs.DropboxBefore-cne$entry.DestinationHash -or ($entry.PSObject.Properties.Name-ccontains'AndroidDestinationHash' -and $obs.AndroidBefore-cne$entry.AndroidDestinationHash)){throw 'ADOPTION BLOCK: resolution baseline mismatch'}
        if($obs.ExpectedSha-cne$entry.Sha256 -or $obs.Inbox.State-cne'Present' -or $obs.Inbox.Sha256-cne$entry.Sha256 -or @($obs.Residue).Count){throw 'ADOPTION BLOCK: resolution inbox evidence'}
        foreach($side in @('Dropbox','Android')){
            $before=[string]$obs.($side+'Before');$actual=$obs.$side
            if(($before -and ($actual.State-cne'Present' -or $actual.Sha256-cne$before)) -or (-not$before -and $actual.State-cne'Absent')){throw 'ADOPTION BLOCK: resolution canonical evidence'}
        }
    }
    foreach($system in @($Journal.entries|ForEach-Object System|Sort-Object -Unique)){
        foreach($side in @('Dropbox','Android')){
            $xml=@($Resolution.evidence.Observations|Where-Object {$_.System-ceq$system -and $_.Side-ceq$side -and $_.PSObject.Properties.Name-ccontains'GamelistPath'})
            if($xml.Count-ne1){throw 'ADOPTION BLOCK: resolution XML missing'}
            $xml=$xml[0]
            $expectedPath=if($side-eq'Dropbox'){Join-Path (Join-Path (Join-Path $Context.SourceRoot 'gamelists') $system) 'gamelist.xml'}else{'/storage/emulated/0/ES-DE/gamelists/'+$system+'/gamelist.xml'}
            if($xml.GamelistPath-cne$expectedPath){throw 'ADOPTION BLOCK: resolution XML path'}
            if($Journal.PSObject.Properties.Name-ccontains'systemSnapshots'){
                $snap=@($Journal.systemSnapshots|Where-Object System -CEQ $system)
                if($snap.Count-ne1 -or $xml.Before-cne$snap[0].($side+'Hash')){throw 'ADOPTION BLOCK: resolution XML baseline'}
            }elseif($Resolution.evidence.BaselineSha256-cnotmatch'^[a-f0-9]{64}$'){throw 'ADOPTION BLOCK: resolution legacy baseline missing'}
            if(($xml.Before -and ($xml.Current.State-cne'Present' -or $xml.Current.Sha256-cne$xml.Before)) -or (-not$xml.Before -and $xml.Current.State-cne'Absent')){throw 'ADOPTION BLOCK: resolution XML evidence'}
        }
    }
}

function New-AdoptionAbandonResolution([string]$JournalPath,$Context,[string]$BaselinePath,[string]$Reason,[switch]$Approved) {
    if(-not$Approved -or [string]::IsNullOrWhiteSpace($Reason)){throw 'ADOPTION BLOCK: explicit user approval/reason required'}
    $inspection=Get-AdoptionInspection $JournalPath $Context $BaselinePath
    if($inspection.Result-cne'NO_COMMIT_CONFIRMED'){throw 'ADOPTION BLOCK: abandon requires NO_COMMIT_CONFIRMED'}
    $j=Get-Content -LiteralPath $JournalPath -Raw -Encoding UTF8|ConvertFrom-Json
    $resolution=[pscustomobject]@{schemaVersion=1;transactionId=$j.transactionId;identity=$Context.Identity;resolution='abandoned';approved=$true;approvedAt=[DateTimeOffset]::UtcNow.ToString('o');approvedBy=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;reason=$Reason;inspectorResult=$inspection.Result;journalSha256=$inspection.JournalSha256;evidence=$inspection.Evidence;evidenceSha256=$inspection.EvidenceSha256}
    Assert-AdoptionResolution $resolution $j $inspection.JournalSha256 $Context
    Assert-AdoptionFingerprint $JournalPath $inspection.JournalSha256
    $folder=Join-Path (Join-Path $Context.StateRoot 'adoption-resolutions') $Context.Identity
    $path=Join-Path $folder ($j.transactionId+'.json')
    [void](Assert-MediaDiskPath $path $Context.StateRoot)
    if(Test-Path -LiteralPath $path){throw 'ADOPTION BLOCK: resolution already exists'}
    [void][IO.Directory]::CreateDirectory($folder)
    $prepared=Join-Path $folder ([guid]::NewGuid().ToString('N')+'.new')
    try{
        Write-MediaJson $prepared $resolution $Context.StateRoot
        $check=Get-Content -LiteralPath $prepared -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-AdoptionResolution $check $j $inspection.JournalSha256 $Context
        Assert-AdoptionFingerprint $JournalPath $inspection.JournalSha256
        [IO.File]::Move($prepared,$path) # no overwrite: concurrent resolution cannot be replaced
    }finally{if([IO.File]::Exists($prepared)){[IO.File]::Delete($prepared)}}
    return $resolution
}

function New-AdoptionExecutorContext([string]$StateRoot,[string]$LibraryRoot,[string]$DeviceSerial,[string[]]$Systems,[switch]$DeferJournalGate) {
    $root=[IO.Path]::GetFullPath($LibraryRoot).TrimEnd('\')
    if(-not$DeviceSerial -or -not$Systems.Count){throw 'ADOPTION BLOCK: identity/selected systems 필요'}
    $identity=Get-MediaTextHash ($root.ToLowerInvariant()+'|'+$DeviceSerial)
    $folder=Join-Path (Join-Path $StateRoot 'adoption-transactions') $identity
    [void](Assert-MediaDiskPath (Join-Path $folder 'guard.json') $StateRoot)
    if(-not$DeferJournalGate -and (Test-Path -LiteralPath $folder)){
        foreach($file in Get-ChildItem -LiteralPath $folder -File){
            if($file.Name-cmatch'^[a-f0-9]{32}\.json\.bak$'){continue}
            if($file.Name-cnotmatch'^[a-f0-9]{32}\.json$'){throw 'ADOPTION BLOCK: 알 수 없는 journal 자료'}
            $j=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
            foreach($field in @('schemaVersion','identity','transactionId','createdAt','updatedAt','state','completed','originalError','entries')){
                if($j.PSObject.Properties.Name-cnotcontains$field){throw 'ADOPTION BLOCK: journal 필수 field 누락'}
            }
            if($j.schemaVersion-isnot[int] -or $j.schemaVersion-ne1 -or $j.completed-isnot[bool] -or $j.identity-cne$identity -or $j.entries-isnot[Array] -or $j.transactionId-cnotmatch'^[a-f0-9]{32}$' -or $file.Name-cne($j.transactionId+'.json') -or @($j.entries).Count-eq0){throw 'ADOPTION BLOCK: 미완료/identity journal 수동 검토 필요'}
            $ctx=[pscustomobject]@{Identity=$identity;SourceRoot=$root}
            if(-not$j.completed -or $j.state-cne'completed'){
                Assert-AdoptionJournalSchema $j $ctx $file.Name
                $resolutionPath=Join-Path (Join-Path (Join-Path $StateRoot 'adoption-resolutions') $identity) $file.Name
                [void](Assert-MediaDiskPath $resolutionPath $StateRoot)
                if(-not(Test-Path -LiteralPath $resolutionPath)){throw 'ADOPTION BLOCK: incomplete journal requires review'}
                $resolution=Get-Content -LiteralPath $resolutionPath -Raw -Encoding UTF8|ConvertFrom-Json
                Assert-AdoptionResolution $resolution $j ((Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()) $ctx
            }
            $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach($entry in $j.entries){
                $prefix='/storage/emulated/0/ROMs/'+$entry.System+'/'
                if(-not([string]$entry.InboxPath).StartsWith($prefix,[StringComparison]::Ordinal)){throw 'ADOPTION BLOCK: journal inbox scope'}
                $info=Get-UnregisteredAdoptionPath $entry.System $entry.InboxPath.Substring($prefix.Length) @($entry.System)
                if(-not[string]::Equals($info.DestinationRelativePath,$entry.RelativePath,[StringComparison]::OrdinalIgnoreCase) -or $entry.Sha256-cnotmatch'^[a-f0-9]{64}$' -or -not$seen.Add($entry.System+'/'+$entry.RelativePath)){throw 'ADOPTION BLOCK: journal path/hash/key'}
            }
        }
    }
    return [pscustomobject]@{StateRoot=[IO.Path]::GetFullPath($StateRoot);SourceRoot=$root;Serial=$DeviceSerial;Systems=$Systems;Identity=$identity;JournalRoot=$folder}
}

function Get-AdoptionRemoteFile([string]$Path,[string]$Session) {
    Assert-RemotePath $Path
    if(-not$Path.StartsWith('/storage/emulated/0/ROMs/')){throw 'adoption ROM root 오류'}
    $parts=$Path.Split('/')
    $checks=New-Object 'Collections.Generic.List[string]'
    for($i=4;$i-lt$parts.Length;$i++){
        $parent=($parts[0..$i]-join'/')
        $checks.Add('[ ! -L '+(Quote-Sh $parent)+' ] || exit 1')
    }
    $q=Quote-Sh $Path
    $command=($checks-join'; ')+'; if [ -f '+$q+' ]; then printf PRESENT; elif [ -e '+$q+' ]; then exit 1; else printf ABSENT; fi'
    $r=Invoke-Adb -s $Serial shell $command
    if($r.Code-ne0 -or $r.StdErr -or $r.StdOut-cnotin@('PRESENT','ABSENT')){throw 'adoption ROM 상태/링크 조회 실패'}
    if($r.StdOut-ceq'ABSENT'){return $null}
    $nativeHash=$null;$method='pull'
    foreach($hashCommand in @('sha256sum ','toybox sha256sum ')){
        $hashReply=Invoke-Adb -s $Serial shell ($hashCommand+$q)
        if($hashReply.Code-eq0 -and -not$hashReply.StdErr -and $hashReply.StdOut.TrimEnd([char]13,[char]10)-match('^([a-fA-F0-9]{64})  '+[regex]::Escape($Path)+'$')){
            $nativeHash=$matches[1].ToLowerInvariant();$method=$hashCommand.Trim();break
        }
    }
    # native/toybox가 없으면 pull SHA를 사용하며, 지원되면 실제 Android SHA와 비교한다.
    $file=Join-Path $Session ([guid]::NewGuid().ToString('N')+'.rom')
    $r=Invoke-Adb -s $Serial pull $Path $file
    if($r.Code-ne0 -or -not[IO.File]::Exists($file)){throw 'adoption ROM pull 실패'}
    $pulledHash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if($nativeHash -and $nativeHash-cne$pulledHash){throw 'adoption Android/pull SHA 불일치'}
    return [pscustomobject]@{Path=$Path;File=$file;Sha256=$pulledHash;HashMethod=$method}
}

function Get-AdoptionInboxPaths([string]$System) {
    [void](Get-UnregisteredAdoptionPath $System '_UNREGISTERED/probe.gb' $selectedSystems)
    $root='/storage/emulated/0/ROMs/'+$System+'/_UNREGISTERED'
    Assert-RemotePath $root
    $q=Quote-Sh $root
    $command='if [ -L '+$q+' ]; then exit 1; elif [ -d '+$q+' ]; then find '+$q+' -mindepth 1 \( -type f -o -type l \) -print0; elif [ -e '+$q+' ]; then exit 1; fi'
    $r=Invoke-Adb -s $Serial shell $command
    if($r.Code-ne0 -or $r.StdErr){throw 'ADOPTION BLOCK: inbox scan 실패'}
    foreach($path in $r.StdOut.Split([char]0)){
        if(-not$path){continue}
        if(-not$path.StartsWith($root+'/',[StringComparison]::Ordinal)){throw 'ADOPTION BLOCK: inbox 범위 밖'}
        $relative='_UNREGISTERED/'+$path.Substring($root.Length+1)
        [void](Get-UnregisteredAdoptionPath $System $relative $selectedSystems)
        $relative
    }
}

function Get-AdoptionBytesHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Assert-AdoptionFingerprint([string]$Path,[string]$ExpectedHash) {
    $actual=if([IO.File]::Exists($Path)){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
    if($actual-cne$ExpectedHash){throw ('CONCURRENT MODIFICATION: '+$Path)}
}

function Assert-AdoptionDestinationPath([string]$Path,$Context) {
    $full=[IO.Path]::GetFullPath($Path)
    $root=$Context.SourceRoot.TrimEnd('\')+'\'
    if(-not$full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'ADOPTION BLOCK: source root 탈출'}
    $cursor=$full
    while(-not(Test-Path -LiteralPath $cursor)){
        $parent=Split-Path -Parent $cursor
        if(-not$parent -or $parent-ceq$cursor){throw 'ADOPTION BLOCK: destination parent 없음'}
        $cursor=$parent
    }
    Assert-LocalSourcePath $cursor $Context.SourceRoot
}
function Install-AdoptionDiskFile([string]$Staged,[string]$Destination,[string]$ExpectedHash,$Context,[bool]$Xml=$false) {
    Assert-AdoptionDestinationPath $Destination $Context
    $hash=(Get-FileHash -LiteralPath $Staged -Algorithm SHA256).Hash.ToLowerInvariant()
    if($Xml){[void](Read-EsdeGamelist $Staged)}
    $parent=Split-Path -Parent $Destination
    [void][IO.Directory]::CreateDirectory($parent)
    Assert-AdoptionDestinationPath $Destination $Context
    $temp=$Destination+'.esde-adoption-'+[guid]::NewGuid().ToString('N')
    try{
        [IO.File]::Copy($Staged,$temp,$false)
        if((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()-cne$hash){throw 'adoption PC staging SHA 불일치'}
        if($Xml){[void](Read-EsdeGamelist $temp)}
        Assert-AdoptionFingerprint $Destination $ExpectedHash
        if($ExpectedHash){[IO.File]::Replace($temp,$Destination,[Management.Automation.Language.NullString]::Value)}
        else{[IO.File]::Move($temp,$Destination)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    Assert-AdoptionFingerprint $Destination $hash
}

function Install-AdoptionRemoteRom($Entry,[string]$Session) {
    $current=Get-AdoptionRemoteFile $Entry.AndroidPath $Session
    if($current){
        if($current.Sha256-cne$Entry.Sha256){throw 'ADOPTION BLOCK: Android canonical 충돌'}
        return
    }
    $temp=$Entry.AndroidPath+'.esde-adoption-'+[guid]::NewGuid().ToString('N')
    Assert-RemotePath $temp
    Ensure-RemoteDir (Split-Path -Parent $Entry.AndroidPath).Replace('\','/')
    $attempted=$false
    try{
        $attempted=$true
        $r=Invoke-Adb -s $Serial push $Entry.StagedFile $temp
        if($r.Code-ne0){throw 'adoption Android temp push 실패'}
        $back=Get-AdoptionRemoteFile $temp $Session
        if(-not$back -or $back.Sha256-cne$Entry.Sha256){throw 'adoption Android staging SHA 불일치'}
        # no-clobber: 다른 writer가 canonical을 만들었으면 검증 후 충돌/재사용.
        $r=Invoke-Adb -s $Serial shell ('mv -n '+(Quote-Sh $temp)+' '+(Quote-Sh $Entry.AndroidPath))
        if($r.Code-ne0 -or $r.StdErr){throw 'adoption Android canonical mv 실패'}
        $final=Get-AdoptionRemoteFile $Entry.AndroidPath $Session
        if(-not$final -or $final.Sha256-cne$Entry.Sha256){throw 'adoption Android canonical SHA 불일치'}
    }finally{
        if($attempted){try{Remove-RemoteFile $temp}catch{Write-Log ('ADOPTION TEMP CLEANUP FAILED: '+$_.Exception.Message)}}
    }
}

function Remove-AdoptionInboxSource($Entry,$Context,[string]$Session,[bool]$AllVerified) {
    if(-not$AllVerified){throw 'ADOPTION BLOCK: 최종 검증 전 inbox 삭제 금지'}
    $info=Get-UnregisteredAdoptionPath $Entry.System $Entry.InboxRelative $Context.Systems
    $expected='/storage/emulated/0/ROMs/'+$Entry.System+'/'+$Entry.InboxRelative
    if($Entry.InboxPath-cne$expected -or -not[string]::Equals($Entry.RelativePath,$info.DestinationRelativePath,[StringComparison]::OrdinalIgnoreCase)){throw 'ADOPTION BLOCK: inbox 삭제 범위 불일치'}
    $current=Get-AdoptionRemoteFile $expected $Session
    if(-not$current -or $current.Sha256-cne$Entry.Sha256){throw 'ADOPTION BLOCK: inbox source 변경'}
    # 일반 삭제 함수의 reserved 보호는 그대로 유지; 이 검증된 단일 inbox 파일만 삭제.
    $r=Invoke-Adb -s $Serial shell ('rm -f '+(Quote-Sh $expected))
    if($r.Code-ne0 -or $r.StdErr -or (Get-AdoptionRemoteFile $expected $Session)){throw 'adoption inbox 삭제 실패'}
}

function Prepare-UnregisteredAdoptionSystem($RomJob,$GamelistJob,$GamelistPlan,$Context,[string]$Session) {
    if($RomJob.System-cne$GamelistJob.System -or $Context.Systems-cnotcontains$RomJob.System){throw 'adoption selected system 오류'}
    $system=$RomJob.System
    $paths=@(Get-AdoptionInboxPaths $system)
    if(-not$paths.Count){return $null}
    $candidates=@();$destinations=@();$staged=@{}
    foreach($relative in $paths){
        $info=Get-UnregisteredAdoptionPath $system $relative $Context.Systems
        $source=Get-AdoptionRemoteFile ('/storage/emulated/0/ROMs/'+$system+'/'+$relative) $Session
        if(-not$source){throw 'adoption source 누락'}
        $candidate=[pscustomobject]@{System=$system;RelativePath=$relative;AndroidSha256=$source.Sha256;StagedSha256=(Get-FileHash -LiteralPath $source.File).Hash.ToLowerInvariant()}
        $candidates+=$candidate;$staged[$relative]=$source
    }
    # 목적지 전체 목록을 검사해 Windows case-insensitive 충돌과 링크를 차단.
    foreach($file in @(Get-ManagedLocalItems $RomJob.LocalPath $Context.SourceRoot|Where-Object {-not$_.PSIsContainer})){
        $relative=$file.FullName.Substring($RomJob.LocalPath.Length).TrimStart('\','/').Replace('\','/')
        $destinations+=[pscustomobject]@{System=$system;RelativePath=$relative;Sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()}
    }
    $pure=@(New-UnregisteredAdoptionPlan $candidates $destinations $Context.Systems)
    $entries=@()
    $base=$GamelistJob.GamelistSource
    $shared=if($base){ConvertFrom-EsdeGamelistBytes $base.Bytes}else{ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<gameList/>'))}
    $local=if($GamelistPlan.Local){ConvertFrom-EsdeGamelistBytes $GamelistPlan.Local.Bytes}else{$null}
    $sharedChanged=$false
    foreach($item in $pure){
        $relative=$item.DestinationRelativePath
        $disk=Join-Path $RomJob.LocalPath $relative
        Assert-AdoptionDestinationPath $disk $Context
        $inbox=$staged[$item.InboxPath.Substring(2)]
        $androidPath='/storage/emulated/0/ROMs/'+$system+'/'+$relative
        $existing=Get-AdoptionRemoteFile $androidPath $Session
        if($existing -and $existing.Sha256-cne$item.Sha256){throw 'ADOPTION BLOCK: Android canonical SHA 충돌'}
        $inboxNode=@(Get-EsdeGameEntries $local|Where-Object Key -CEQ $item.InboxPath)
        $normalNode=@(Get-EsdeGameEntries $local|Where-Object Key -CEQ $item.ManagedPath)
        $baseNode=@(Get-EsdeGameEntries $shared|Where-Object Key -CEQ $item.ManagedPath)
        if($inboxNode.Count-gt1 -or $normalNode.Count-gt1 -or $baseNode.Count-gt1){throw 'ADOPTION BLOCK: metadata 중복'}
        $proposal=New-AdoptionGamePromotion $(if($inboxNode.Count){$inboxNode[0].Node}) $item.ManagedPath $(if($baseNode.Count){$baseNode[0].Node}) $(if($normalNode.Count){$normalNode[0].Node})
        if($proposal.NeedsPolicyDecision){throw ('ADOPTION BLOCK: policy unresolved / '+($proposal.PendingFields-join','))}
        if($proposal.CreateGame){
            $list=$shared.Document.DocumentElement.SelectSingleNode('gameList')
            if(-not$baseNode.Count){[void]$list.AppendChild($shared.Document.ImportNode($proposal.DropboxNode,$true));$sharedChanged=$true}
            if($local){
                $localList=$local.Document.DocumentElement.SelectSingleNode('gameList')
                if($inboxNode.Count){[void]$localList.RemoveChild($inboxNode[0].Node)}
                if($normalNode.Count){[void]$localList.RemoveChild($normalNode[0].Node)}
                [void]$localList.AppendChild($local.Document.ImportNode($proposal.AndroidNode,$true))
                $local.Bytes=ConvertTo-EsdeGamelistBytes $local
            }
        }
        $entries+=[pscustomobject]@{System=$system;InboxRelative=$item.InboxPath.Substring(2);InboxPath=$inbox.Path;RelativePath=$relative;Sha256=$item.Sha256;StagedFile=$inbox.File;DropboxPath=$disk;AndroidPath=$androidPath;DestinationHash=$(if($item.Action-ceq'ReuseIdentical'){$item.Sha256}else{''});AndroidDestinationHash=$(if($existing){$existing.Sha256}else{''})}
    }
    $shared.Bytes=ConvertTo-EsdeGamelistBytes $shared
    $sharedOutput=$null
    if($sharedChanged){$sharedOutput=Join-Path $Session ([guid]::NewGuid().ToString('N')+'-shared.xml');[void](Write-EsdeGamelist $shared $sharedOutput)}
    $bound=Get-AndroidBoundGamelist $(if($base -or $sharedChanged){$shared}) $local $system $GamelistPlan.PreservedUnmanagedPaths
    $output=$null
    if($bound){$output=Join-Path $Session ([guid]::NewGuid().ToString('N')+'-android.xml');[void](Write-EsdeGamelist $bound $output)}
    $androidPlan=$GamelistPlan.PSObject.Copy();$androidPlan.Output=$output
    $dropboxXml=Join-Path $GamelistJob.LocalPath 'gamelist.xml'
    $systemPlan=[pscustomobject]@{System=$system;DropboxGamelist=$dropboxXml;DropboxHash=$(if($base){Get-AdoptionBytesHash $base.Bytes}else{''});SharedOutput=$sharedOutput;SharedHash=$(if($sharedOutput){(Get-FileHash -LiteralPath $sharedOutput).Hash.ToLowerInvariant()}else{''});AndroidHash=$(if($output){(Get-FileHash -LiteralPath $output).Hash.ToLowerInvariant()}else{''});AndroidPlan=$androidPlan}
    return [pscustomobject]@{Validated=$true;Identity=$Context.Identity;Entries=$entries;Systems=@($systemPlan);Session=$Session}
}

function Restore-AdoptionInboxSource($Entry,$Context,[string]$Session) {
    # 실행 중 cleanup 실패의 보상은 inbox 복사본에만 한정한다.
    # 기존 canonical/XML은 되돌리지 않으며 미완료 journal의 자동 복구도 하지 않는다.
    $info=Get-UnregisteredAdoptionPath $Entry.System $Entry.InboxRelative $Context.Systems
    $path='/storage/emulated/0/ROMs/'+$Entry.System+'/'+$Entry.InboxRelative
    if($Entry.InboxPath-cne$path -or -not[string]::Equals($info.DestinationRelativePath,$Entry.RelativePath,[StringComparison]::OrdinalIgnoreCase)){throw 'inbox 보상 범위 불일치'}
    $current=Get-AdoptionRemoteFile $path $Session
    if($current){
        if($current.Sha256-cne$Entry.Sha256){throw 'inbox 보상 충돌: 사용자 파일 덮어쓰기 금지'}
        return
    }
    Assert-AdoptionFingerprint $Entry.StagedFile $Entry.Sha256
    $temp=$path+'.esde-adoption-restore-'+[guid]::NewGuid().ToString('N')
    try{
        $r=Invoke-Adb -s $Serial push $Entry.StagedFile $temp
        if($r.Code-ne0){throw 'inbox 보상 전송 실패'}
        $back=Get-AdoptionRemoteFile $temp $Session
        if(-not$back -or $back.Sha256-cne$Entry.Sha256){throw 'inbox 보상 SHA 불일치'}
        $r=Invoke-Adb -s $Serial shell ('mv -n '+(Quote-Sh $temp)+' '+(Quote-Sh $path))
        if($r.Code-ne0 -or $r.StdErr){throw 'inbox 보상 mv 실패'}
        $back=Get-AdoptionRemoteFile $path $Session
        if(-not$back -or $back.Sha256-cne$Entry.Sha256){throw 'inbox 보상 최종 검증 실패'}
    }finally{
        # reserved 일반 삭제 보호를 우회하지 않고 이 함수가 만든 정확한 임시 파일만 정리.
        $r=Invoke-Adb -s $Serial shell ('rm -f '+(Quote-Sh $temp))
        if($r.Code-ne0 -or $r.StdErr){Write-Log ('ADOPTION RESTORE TEMP 보존: '+$temp)}
    }
}
function Invoke-AdoptionWithCapabilityGate($Plan,$Context) {
    $capability=Test-AdoptionPlanCapability $Plan
    [void](New-AdoptionExecutorContext $Context.StateRoot $Context.SourceRoot $Context.Serial $Context.Systems)
    if(-not$capability.Allowed){
        Write-Log ('ADOPTION BLOCK: Dropbox destination does not allow required write operations; inbox preserved; normal sync continues / '+$capability.Result)
        return [pscustomobject]@{Applied=$false;Status='Blocked';Capability=$capability;Journal=$null}
    }
    $journal=Invoke-UnregisteredAdoptionTransaction $Plan $Context
    return [pscustomobject]@{Applied=$true;Status='Completed';Capability=$capability;Journal=$journal}
}
function Invoke-UnregisteredAdoptionTransaction($Plan,$Context) {
    if(-not$Plan.Validated -or $Plan.Identity-cne$Context.Identity -or @($Plan.Entries).Count-eq0 -or @($Plan.Systems).Count-eq0){throw 'ADOPTION BLOCK: 검증되지 않은 plan'}
    # prepare 후에도 미완료 journal을 다시 검사한다.

    foreach($entry in $Plan.Entries){
        $info=Get-UnregisteredAdoptionPath $entry.System $entry.InboxRelative $Context.Systems
        if(-not[string]::Equals($entry.RelativePath,$info.DestinationRelativePath,[StringComparison]::OrdinalIgnoreCase) -or $entry.DropboxPath-cne(Join-Path (Join-Path (Join-Path $Context.SourceRoot 'roms') $entry.System) $entry.RelativePath)){throw 'adoption plan 경로 변조'}
        if($entry.InboxPath-cne('/storage/emulated/0/ROMs/'+$entry.System+'/'+$entry.InboxRelative) -or $entry.AndroidPath-cne('/storage/emulated/0/ROMs/'+$entry.System+'/'+$entry.RelativePath)){throw 'ADOPTION BLOCK: remote plan 경로 변조'}
        Assert-AdoptionDestinationPath $entry.DropboxPath $Context
        if((Get-FileHash -LiteralPath $entry.StagedFile -Algorithm SHA256).Hash.ToLowerInvariant()-cne$entry.Sha256){throw 'adoption staged ROM 변경'}
    }
    $systems=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($system in $Plan.Systems){
        if($Context.Systems-cnotcontains$system.System -or -not$systems.Add($system.System) -or $system.DropboxGamelist-cne(Join-Path (Join-Path (Join-Path $Context.SourceRoot 'gamelists') $system.System) 'gamelist.xml') -or $system.AndroidPlan.System-cne$system.System){throw 'ADOPTION BLOCK: XML plan 범위 변조'}
        Assert-AdoptionDestinationPath $system.DropboxGamelist $Context
        if($system.SharedOutput){Assert-AdoptionFingerprint $system.SharedOutput $system.SharedHash}
        if($system.AndroidPlan.Output){Assert-AdoptionFingerprint $system.AndroidPlan.Output $system.AndroidHash}
    }
    foreach($entry in $Plan.Entries){if(-not$systems.Contains($entry.System)){throw 'ADOPTION BLOCK: XML system plan 누락'}}
    foreach($entry in $Plan.Entries){
        Assert-AdoptionFingerprint $entry.DropboxPath $entry.DestinationHash
        $source=Get-AdoptionRemoteFile $entry.InboxPath $Plan.Session
        if(-not$source -or $source.Sha256-cne$entry.Sha256){throw 'ADOPTION BLOCK: source changed before journal'}
    }
    foreach($system in $Plan.Systems){
        Assert-AdoptionFingerprint $system.DropboxGamelist $system.DropboxHash
        Assert-GamelistSnapshot $system.AndroidPlan
    }
    $capability=Test-AdoptionPlanCapability $Plan
    if(-not$capability.Allowed){
        Write-Log ('ADOPTION BLOCK: Dropbox destination does not allow required write operations / '+$capability.Result+' / '+($capability.MissingCapabilities-join','))
        throw 'ADOPTION BLOCK: Dropbox destination does not allow required write operations'
    }
    [void](New-AdoptionExecutorContext $Context.StateRoot $Context.SourceRoot $Context.Serial $Context.Systems)
    [void][IO.Directory]::CreateDirectory($Context.JournalRoot)
    $journal=[pscustomobject]@{sourceRestoreErrors=@();history=@();stagingPath=$Plan.Session;schemaVersion=1;identity=$Context.Identity;transactionId=[guid]::NewGuid().ToString('N');createdAt=[DateTimeOffset]::UtcNow.ToString('o');updatedAt='';state='staged';completed=$false;originalError='';entries=@($Plan.Entries|Select-Object System,InboxPath,RelativePath,Sha256,DropboxPath,AndroidPath,StagedFile,DestinationHash,AndroidDestinationHash);systemSnapshots=@($Plan.Systems|ForEach-Object {[pscustomobject]@{System=$_.System;DropboxHash=$_.DropboxHash;AndroidHash=$(if($_.AndroidPlan.Pulled){(Get-FileHash -LiteralPath $_.AndroidPlan.Pulled).Hash.ToLowerInvariant()}else{''})}})}
    $journalFile=Join-Path $Context.JournalRoot ($journal.transactionId+'.json')
    $save={param($state)$journal.state=$state;$journal.updatedAt=[DateTimeOffset]::UtcNow.ToString('o');$journal.history+=@([pscustomobject]@{state=$state;at=$journal.updatedAt});Write-MediaJson $journalFile $journal $Context.StateRoot}.GetNewClosure()
    & $save 'staged'
    $cleanupAttempted=$false
    try{
        foreach($entry in $Plan.Entries){
            $source=Get-AdoptionRemoteFile $entry.InboxPath $Plan.Session
            if(-not$source -or $source.Sha256-cne$entry.Sha256){throw 'adoption source hash 변경'}
            Assert-AdoptionFingerprint $entry.DropboxPath $entry.DestinationHash
        }
        & $save 'source-verified'
        foreach($entry in $Plan.Entries){
            if(-not$entry.DestinationHash){Install-AdoptionDiskFile $entry.StagedFile $entry.DropboxPath '' $Context}
        }
        & $save 'dropbox-installed'
        & $save 'gamelist-prepared'
        foreach($system in $Plan.Systems){
            Assert-AdoptionFingerprint $system.DropboxGamelist $system.DropboxHash
            Assert-GamelistSnapshot $system.AndroidPlan
            if($system.SharedOutput -and $system.DropboxHash){[IO.File]::Copy($system.DropboxGamelist,(Join-Path $Plan.Session ($system.System+'-master-backup.xml')),$false)}
            if($system.SharedOutput){Install-AdoptionDiskFile $system.SharedOutput $system.DropboxGamelist $system.DropboxHash $Context $true}
        }
        & $save 'dropbox-gamelist-installed'
        foreach($entry in $Plan.Entries){Install-AdoptionRemoteRom $entry $Plan.Session}
        & $save 'android-rom-installed'
        foreach($system in $Plan.Systems){Sync-GamelistSystem $system.AndroidPlan}
        & $save 'android-gamelist-installed'
        foreach($entry in $Plan.Entries){
            Assert-AdoptionFingerprint $entry.DropboxPath $entry.Sha256
            $final=Get-AdoptionRemoteFile $entry.AndroidPath $Plan.Session
            if(-not$final -or $final.Sha256-cne$entry.Sha256){throw 'adoption canonical 최종 검증 실패'}
        }
        foreach($system in $Plan.Systems){
            if($system.SharedOutput){Assert-AdoptionFingerprint $system.DropboxGamelist ((Get-FileHash -LiteralPath $system.SharedOutput).Hash.ToLowerInvariant())}
            if($system.AndroidPlan.Output){
                $check=Join-Path $Plan.Session ([guid]::NewGuid().ToString('N')+'.xml')
                $r=Invoke-Adb -s $Serial pull $system.AndroidPlan.RemoteFile $check
                if($r.Code-ne0){throw 'adoption final gamelist pull 실패'}
                [void](Read-EsdeGamelist $check)
                if((Get-FileHash -LiteralPath $check).Hash-cne(Get-FileHash -LiteralPath $system.AndroidPlan.Output).Hash){throw 'adoption final gamelist SHA 실패'}
            }
        }
        # 모든 canonical/XML 검증 후에만 source cleanup. 다중 파일 삭제는 원자적이지 않음.
        $cleanupAttempted=$true
        foreach($entry in $Plan.Entries){Remove-AdoptionInboxSource $entry $Context $Plan.Session $true}
        & $save 'android-source-removed'
        $journal.completed=$true
        & $save 'completed'
    }catch{
        $journal.completed=$false;$journal.originalError=$_.Exception.Message
        if($cleanupAttempted){foreach($entry in $Plan.Entries){try{Restore-AdoptionInboxSource $entry $Context $Plan.Session}catch{$journal.sourceRestoreErrors+=@($_.Exception.Message);Write-Log ('ADOPTION FATAL: inbox 보상 실패; PC staging/canonical 보존: '+$_.Exception.Message)}}}
        try{& $save 'failed'}catch{Write-Log ('ADOPTION JOURNAL SAVE FAILED: '+$_.Exception.Message)}
        Write-Log ('ADOPTION BLOCK: 원본/생성된 canonical 및 journal 보존, 수동 검토 필요: '+$journal.originalError)
        throw
    }
    return $journal
}

function Get-AndroidBoundGamelist($Master,$Android,[string]$System,[string[]]$PreservedUnmanagedPaths=@()) {
    $merged=Merge-EsdeGamelist $Master $Android {param($message)Write-Log ('GAMELIST WARNING: '+$message)} $PreservedUnmanagedPaths
    if($null-eq$merged){return $null}
    $arcade=@('arcade','atomiswave','consolearcade','cps','cps1','cps2','cps3','fba','fbneo','mame','mame-advmame','model2','model3','naomi','naomi2','naomigd','pcarcade','stv','triforce','type-x')
    if($System-in@('neogeo','neogeocd','neogeocdjp')){
        Write-Log ('ALTEMULATOR POLICY UNRESOLVED: '+$System+' / game-level 변환 생략')
        return $merged
    }
    return Convert-EsdeAndroidAltemulators $merged $System ($arcade-contains$System) -Warning {param($m)Write-Log ('ALTEMULATOR BLOCK: '+$m)} -PreservedUnmanagedPaths $PreservedUnmanagedPaths
}
function Write-EsdeGamelist($Gamelist,[string]$Path) {
    if($null-eq$Gamelist){return $false}
    if([string]::IsNullOrWhiteSpace($Path)){throw '출력 경로가 필요합니다.'}
    $destination=[IO.Path]::GetFullPath($Path)
    if($Gamelist.InputPaths -icontains $destination -or [IO.File]::Exists($destination)){throw '원본/기존 파일 덮어쓰기 금지'}
    # 새 PC staging 파일만 생성한다. 검증된 bytes를 임시 파일에 쓴 후 이동한다.
    $validated=ConvertFrom-EsdeGamelistBytes $Gamelist.Bytes 'write verification'
    [void]@(Get-EsdeGameEntries $validated)
    $temporary=$destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($Gamelist.Bytes,0,$Gamelist.Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        [void](Read-EsdeGamelist $temporary)
        [IO.File]::Move($temporary,$destination)
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    return $true
}

function Get-GamelistSource([string]$LocalSystemPath) {
    $file=Join-Path $LocalSystemPath 'gamelist.xml'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        Assert-LocalSourcePath $file $SourceRoot
        $source=Read-EsdeGamelist $file
        [void]@(Get-EsdeGameEntries $source)
        return $source
    } catch { Write-Log 'GAMELIST BLOCK: malformed/unreadable Dropbox XML'; throw }
}

function Get-RemoteGamelistState([string]$RemoteFile) {
    Assert-RemotePath $RemoteFile
    $q=Quote-Sh $RemoteFile
    $dir=Quote-Sh ($RemoteFile.Substring(0,$RemoteFile.LastIndexOf('/')))
    # test false를 ADB 실패와 구분한다. 부모 조회 실패/비정상 타입/링크는 absent로 숨기지 않는다.
    $command=@'
if [ -L {0} ]; then exit 1
elif [ -d {0} ]; then cd {0} || exit 1
elif [ -e {0} ]; then exit 1
else
  ok=0
  for parent in /storage/emulated/0/ES-DE/gamelists /storage/emulated/0/ES-DE /storage/emulated/0; do
    if [ -L "$parent" ]; then exit 1
    elif [ -d "$parent" ]; then cd "$parent" || exit 1; ok=1; break
    elif [ -e "$parent" ]; then exit 1; fi
  done
  [ "$ok" = 1 ] || exit 1
fi
if [ -L {1} ]; then exit 1
elif [ -f {1} ]; then printf PRESENT
elif [ -e {1} ]; then exit 1
else printf ABSENT; fi
'@
    $r=Invoke-Adb -s $Serial shell ($command -f $dir,$q)
    if ($r.Code-ne0 -or $r.StdErr -or $r.StdOut -cnotin @('PRESENT','ABSENT')) { throw 'Android gamelist 존재 조회 실패' }
    return ($r.StdOut-ceq'PRESENT')
}

function Prepare-GamelistSystem($Job,[string]$Session,[string[]]$PreservedUnmanagedPaths=@()) {
    $remote=$Job.RemotePath+'/gamelist.xml'
    Assert-RemotePath $remote
    $folder=Join-Path $Session ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $folder)
    Write-Log ('GAMELIST '+$Job.System+': DROPBOX: '+$(if($Job.GamelistSource){'present'}else{'absent'}))
    $present=Get-RemoteGamelistState $remote
    Write-Log ('GAMELIST '+$Job.System+': ANDROID: '+$(if($present){'present'}else{'absent'}))
    $local=$null;$pulled=$null
    if($present){
        $pulled=Join-Path $folder 'android.xml'
        $r=Invoke-Adb -s $Serial pull $remote $pulled
        if($r.Code-ne0 -or -not(Test-Path -LiteralPath $pulled -PathType Leaf)){throw 'Android gamelist pull 실패'}
        try{$local=Read-EsdeGamelist $pulled}catch{Write-Log 'GAMELIST BLOCK: malformed Android XML';throw}
    }
    $entries=@(Get-LocalOnlyGameEntries $local {param($message)Write-Log ('GAMELIST WARNING: '+$message)})
    Write-Log ('GAMELIST '+$Job.System+': LOCAL-ONLY: '+$entries.Count+' _TEST: '+@($entries|Where-Object Class -eq LocalTest).Count+' _UNREGISTERED: '+@($entries|Where-Object Class -eq LocalUnregistered).Count)
    $merged=Get-AndroidBoundGamelist $Job.GamelistSource $local $Job.System $PreservedUnmanagedPaths
    $output=$null
    if($merged){
        $output=Join-Path $folder 'merged.xml'
        [void](Write-EsdeGamelist $merged $output)
        [void]@(Get-EsdeGameEntries (Read-EsdeGamelist $output))
        Write-Log ('GAMELIST '+$Job.System+': MERGE: created VALIDATION: pass')
    }
    return [pscustomobject]@{System=$Job.System;RemotePath=$Job.RemotePath;RemoteFile=$remote;Present=$present;Output=$output;Pulled=$pulled;Validated=$true;LocalOnlyCount=$entries.Count;SourcePresent=[bool]$Job.GamelistSource;Local=$local;PreservedUnmanagedPaths=$PreservedUnmanagedPaths}
}

function Assert-GamelistSnapshot($Plan) {
    $present=Get-RemoteGamelistState $Plan.RemoteFile
    if($present-ne$Plan.Present){throw 'Android gamelist 상태가 준비 이후 변경되었습니다.'}
    if($present){
        $current=Join-Path (Split-Path -Parent $Plan.Pulled) 'current-before-commit.xml'
        $r=Invoke-Adb -s $Serial pull $Plan.RemoteFile $current
        if($r.Code-ne0 -or -not(Test-Path -LiteralPath $current -PathType Leaf)){throw 'Android gamelist 교체 전 재확인 실패'}
        if((Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash-cne(Get-FileHash -LiteralPath $Plan.Pulled -Algorithm SHA256).Hash){throw 'Android gamelist 내용이 준비 이후 변경되었습니다.'}
    }
}

function Sync-GamelistSystem($Plan) {
    # Plan이 호출자에 의해 바뀌어도 선택된 gamelist.xml 외 파일은 취급하지 않는다.
    Assert-RemotePath $Plan.RemoteFile
    if(-not$Plan.Validated){throw '검증되지 않은 gamelist plan'}
    if($Plan.RemotePath-cne('/storage/emulated/0/ES-DE/gamelists/'+$Plan.System) -or $Plan.RemoteFile-cne($Plan.RemotePath+'/gamelist.xml')){throw 'gamelist 처리 범위 오류'}
    if(-not$Plan.Output){
        if($Plan.Present){
            if($Plan.SourcePresent -or $Plan.LocalOnlyCount-ne0 -or -not$Plan.Pulled){throw 'gamelist 삭제 조건 불일치'}
            if(@(Get-LocalOnlyGameEntries (Read-EsdeGamelist $Plan.Pulled)).Count){throw 'local-only metadata 삭제 금지'}
            Assert-GamelistSnapshot $Plan
            Write-Log ('GAMELIST '+$Plan.System+': ACTION: remove gamelist.xml (pulled/parsed, local-only=0)')
            Remove-RemoteFile $Plan.RemoteFile
            # 기존 경로 검증은 시스템 루트 rmdir도 막는다. 폴더/unknown 파일은 그대로 둔다.
        }else{Write-Log ('GAMELIST '+$Plan.System+': ACTION: no-op')}
        return
    }
    [void]@(Get-EsdeGameEntries (Read-EsdeGamelist $Plan.Output))
    Ensure-RemoteDir $Plan.RemotePath
    $temporary=$Plan.RemoteFile+'.esde-sync-new-'+[guid]::NewGuid().ToString('N')
    if(Get-RemoteGamelistState $temporary){throw 'Android staging 파일 충돌'}
    $attempted=$false
    try{
        $attempted=$true
        $r=Invoke-Adb -s $Serial push $Plan.Output $temporary
        if($r.Code-ne0){throw 'gamelist temp push 실패'}
        Write-Log ('GAMELIST '+$Plan.System+': PUSH TEMP: pass')
        $r=Invoke-Adb -s $Serial shell ('stat -c %s '+(Quote-Sh $temporary))
        $size=(Get-Item -LiteralPath $Plan.Output).Length
        if($r.Code-ne0 -or $r.StdErr -or $r.StdOut.Trim()-cne[string]$size){throw 'Android gamelist staging 크기 검증 실패'}
        $readBack=Join-Path (Split-Path -Parent $Plan.Output) 'pushed-back.xml'
        $r=Invoke-Adb -s $Serial pull $temporary $readBack
        if($r.Code-ne0 -or -not(Test-Path -LiteralPath $readBack -PathType Leaf)){throw 'Android staging 재확인 pull 실패'}
        [void]@(Get-EsdeGameEntries (Read-EsdeGamelist $readBack))
        if((Get-FileHash -LiteralPath $readBack -Algorithm SHA256).Hash-cne(Get-FileHash -LiteralPath $Plan.Output -Algorithm SHA256).Hash){throw 'Android staging 전송 해시 불일치'}
        Write-Log ('GAMELIST '+$Plan.System+': REMOTE VALIDATION: pass')
        # 같은 디렉터리의 rename. 최종 파일을 먼저 삭제하거나 직접 push하지 않는다.
        Assert-GamelistSnapshot $Plan
        $r=Invoke-Adb -s $Serial shell ('mv -f '+(Quote-Sh $temporary)+' '+(Quote-Sh $Plan.RemoteFile))
        if($r.Code-ne0 -or $r.StdErr){throw 'gamelist final mv 실패 (완료 여부를 로그로 확인해야 합니다.)'}
        $attempted=$false
        Write-Log ('GAMELIST '+$Plan.System+': REPLACE: pass')
    }finally{
        if($attempted){try{Remove-RemoteFile $temporary;Write-Log 'GAMELIST TEMP CLEANUP: pass'}catch{Write-Log ('GAMELIST TEMP CLEANUP FAILED: '+$_.Exception.Message)}}
    }
}

function Get-MediaRelativePath([string]$Path) {
    $value=$Path.Replace('\','/')
    if($value.StartsWith('./')){$value=$value.Substring(2)}
    if(-not$value -or $value.StartsWith('/') -or $value.Contains(':') -or $value-match'[\x00-\x1f\x7f]' -or @($value.Split('/')|Where-Object {$_-in@('','.', '..')}).Count){throw 'invalid media relativePath'}
    return $value
}

function Get-MediaRemotePath([string]$System,[string]$Relative) {
    if((Get-MediaRelativePath $System)-cne$System -or $System.Contains('/')){throw 'invalid media system'}
    $relative=Get-MediaRelativePath $Relative
    if(Is-ExcludedRelativePath $relative){throw '예약 media 경로 접근 금지'}
    $path='/storage/emulated/0/ES-DE/downloaded_media/'+$System+'/'+$relative
    Assert-RemotePath $path
    return $path
}

function Get-MediaTextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

function Assert-MediaDiskPath([string]$Path,[string]$StateRoot) {
    $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    if(-not$full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'media State 범위 밖 경로'}
    $cursor=$full
    while($cursor -and $cursor.Length-ge$root.Length){
        if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'media State reparse 경로 금지'}}
        $cursor=Split-Path -Parent $cursor
    }
    return $full
}

function Assert-MediaManifest($Manifest,$Context) {
    foreach($name in @('schemaVersion','sourceRoot','sourceIdentity','deviceSerial','createdAt','updatedAt','entries')){if($Manifest.PSObject.Properties.Name-cnotcontains$name){throw ('media manifest 필수 필드 누락: '+$name)}}
    if($Manifest.schemaVersion-isnot[int] -or $Manifest.schemaVersion-ne1 -or $Manifest.sourceRoot-cne$Context.SourceRoot -or $Manifest.sourceIdentity-cne$Context.SourceIdentity -or $Manifest.deviceSerial-cne$Context.Serial){throw 'media manifest schema/identity 불일치'}
    foreach($stamp in @($Manifest.createdAt,$Manifest.updatedAt)){$parsed=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse([string]$stamp,[ref]$parsed)){throw 'media manifest 시각 오류'}}
    if($Manifest.entries-isnot[Array]){throw 'media manifest entries 배열 필요'}
    $keys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($entry in $Manifest.entries){
        foreach($name in @('system','relativePath','sourceSha256','deployedSha256','sourceSize','deployedAt','lastVerifiedAt')){if($entry.PSObject.Properties.Name-cnotcontains$name){throw ('media entry 필수 필드 누락: '+$name)}}
        $relative=Get-MediaRelativePath $entry.relativePath
        if($relative-cne$entry.relativePath -or (Is-ExcludedRelativePath $relative) -or (Get-MediaRelativePath $entry.system)-cne$entry.system -or $entry.system.Contains('/')){throw 'media manifest 경로 오류'}
        if(-not$keys.Add($entry.system+'/'+$relative)){throw 'media manifest 중복 key'}
        if($entry.sourceSha256-cnotmatch'^[a-f0-9]{64}$' -or $entry.deployedSha256-cnotmatch'^[a-f0-9]{64}$' -or $entry.sourceSize-isnot[ValueType] -or $entry.sourceSize-is[bool] -or [double]$entry.sourceSize-lt0 -or [double]$entry.sourceSize-ne[long]$entry.sourceSize){throw 'media manifest hash/size 오류'}
        foreach($stamp in @($entry.deployedAt,$entry.lastVerifiedAt)){$parsed=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse([string]$stamp,[ref]$parsed)){throw 'media entry 시각 오류'}}
    }
}

function Write-MediaJson([string]$Path,$Value,[string]$StateRoot) {
    [void](Assert-MediaDiskPath $Path $StateRoot)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Value|ConvertTo-Json -Depth 12))
        $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        [void]([IO.File]::ReadAllText($temporary)|ConvertFrom-Json)
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,$Path+'.bak')}
        else{[IO.File]::Move($temporary,$Path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function New-MediaContext([string]$StateRoot,[string]$Source,[string]$Device) {
    if(-not$Device -or $Device-match'[\x00-\x1f\x7f]'){throw 'media device identity 필요'}
    $source=[IO.Path]::GetFullPath($Source).TrimEnd('\').ToUpperInvariant()
    $sourceId=Get-MediaTextHash $source;$id=Get-MediaTextHash ($sourceId+'|'+$Device)
    $context=[pscustomobject]@{StateRoot=[IO.Path]::GetFullPath($StateRoot);SourceRoot=$source;SourceIdentity=$sourceId;Serial=$Device;ManifestPath=(Join-Path $StateRoot ('media-ownership/'+$id+'.json'));Transactions=(Join-Path $StateRoot ('media-transactions/'+$id));Session=$null;Manifest=$null;OriginalBytes=$null}
    foreach($folder in @((Split-Path -Parent $context.ManifestPath),$context.Transactions)){[void](Assert-MediaDiskPath $folder $StateRoot);[void](New-Item -ItemType Directory -Path $folder -Force)}
    foreach($folder in @(Get-ChildItem -LiteralPath $context.Transactions -Directory)){
        $journalPath=Join-Path $folder.FullName 'journal.json';[void](Assert-MediaDiskPath $journalPath $StateRoot)
        if(-not(Test-Path -LiteralPath $journalPath)){throw ('미완료 media 준비 세션: '+$folder.FullName)}
        try{$journal=Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{throw 'media journal 손상'}
        if($journal.state-cnotin@('completed','rolled_back')){throw ('미완료 media transaction 복구 필요: '+$folder.FullName)}
    }
    if(Test-Path -LiteralPath $context.ManifestPath){
        [void](Assert-MediaDiskPath $context.ManifestPath $StateRoot)
        $context.OriginalBytes=[IO.File]::ReadAllBytes($context.ManifestPath)
        try{$context.Manifest=[Text.Encoding]::UTF8.GetString($context.OriginalBytes).TrimStart([char]0xfeff)|ConvertFrom-Json}catch{throw 'media manifest JSON 손상'}
    }else{
        $now=(Get-Date).ToUniversalTime().ToString('o')
        $context.Manifest=[pscustomobject]@{schemaVersion=1;sourceRoot=$source;sourceIdentity=$sourceId;deviceSerial=$Device;createdAt=$now;updatedAt=$now;entries=@()}
    }
    Assert-MediaManifest $context.Manifest $context
    $context.Session=Join-Path $context.Transactions ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $context.Session)
    if($context.OriginalBytes){[IO.File]::WriteAllBytes((Join-Path $context.Session 'original-manifest.json'),$context.OriginalBytes)}
    Write-MediaJson (Join-Path $context.Session 'journal.json') ([pscustomobject]@{state='preparing';operations=@()}) $StateRoot
    return $context
}

function Get-MediaSourceFiles($Jobs,$Context) {
    $files=@()
    foreach($job in $Jobs){
        if(-not(Test-Path -LiteralPath $job.LocalPath)){continue}
        foreach($item in @(Get-ManagedLocalItems $job.LocalPath $SourceRoot|Where-Object {-not$_.PSIsContainer})){
            $relative=Get-MediaRelativePath ($item.FullName.Substring($job.LocalPath.Length).TrimStart('\','/'))
            [void](Get-MediaRemotePath $job.System $relative)
            $copy=Join-Path $Context.Session ([guid]::NewGuid().ToString('N')+'.source')
            $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            Copy-Item -LiteralPath $item.FullName -Destination $copy
            if((Get-FileHash -LiteralPath $copy).Hash-ine$hash){throw 'media 원본이 준비 중 변경됨'}
            $files+=[pscustomobject]@{system=$job.System;relativePath=$relative;hash=$hash;size=(Get-Item -LiteralPath $copy).Length;path=$copy}
        }
    }
    return $files
}

function Get-MediaRemoteHash([string]$Path,[string]$Session) {
    Assert-RemotePath $Path
    if(-not$Path.StartsWith('/storage/emulated/0/ES-DE/downloaded_media/',[StringComparison]::Ordinal)){throw 'media 범위 오류'}
    if(Is-ExcludedRelativePath $Path.Substring('/storage/emulated/0/ES-DE/downloaded_media/'.Length)){throw '예약 media hash 조회 금지'}
    $q=Quote-Sh $Path
    $checks='';$parent=$Path.Substring(0,$Path.LastIndexOf('/'))
    while($parent.StartsWith('/storage/emulated/0/ES-DE/downloaded_media',[StringComparison]::Ordinal)){
        $p=Quote-Sh $parent
        $checks+="if [ -L $p ]; then exit 1; elif [ -d $p ]; then cd $p || exit 1; elif [ -e $p ]; then exit 1; fi; "
        $parent=$parent.Substring(0,$parent.LastIndexOf('/'))
    }
    $r=Invoke-Adb -s $Serial shell ($checks+"if [ -L $q ]; then exit 1; elif [ -f $q ]; then printf PRESENT; elif [ -e $q ]; then exit 1; else printf ABSENT; fi")
    if($r.Code-ne0 -or $r.StdErr -or $r.StdOut-cnotin@('PRESENT','ABSENT')){throw 'media remote 상태 불명확'}
    if($r.StdOut-ceq'ABSENT'){return $null}
    foreach($command in @('sha256sum ','toybox sha256sum ')){
        $r=Invoke-Adb -s $Serial shell ($command+$q)
        if($r.Code-eq0 -and -not$r.StdErr -and $r.StdOut.TrimEnd([char]13,[char]10)-match('^([a-fA-F0-9]{64})  '+[regex]::Escape($Path)+'$')){return $matches[1].ToLowerInvariant()}
    }
    $copy=Join-Path $Session ([guid]::NewGuid().ToString('N')+'.hash')
    $r=Invoke-Adb -s $Serial pull $Path $copy
    if($r.Code-ne0 -or -not(Test-Path -LiteralPath $copy -PathType Leaf)){throw 'media hash unknown: pull 실패'}
    return (Get-FileHash -LiteralPath $copy).Hash.ToLowerInvariant()
}

function Prepare-MediaPlan($Jobs,$Sources,$Context) {
    $operations=@();$conflicts=@();$summary=0
    $entries=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($entry in $Context.Manifest.entries){$entries.Add($entry.system+'/'+$entry.relativePath,$entry)}
    $sourceMap=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($file in $Sources){$sourceMap.Add($file.system+'/'+$file.relativePath,$file)}
    foreach($job in $Jobs){
        Assert-RemotePath $job.RemotePath
        if($job.RemotePath-cne('/storage/emulated/0/ES-DE/downloaded_media/'+$job.System)){throw 'media job 범위 오류'}
        $remote=@(Get-RemoteFiles $job.RemotePath);[void]@(Get-RemoteDirs $job.RemotePath)
        foreach($relative in $remote){if(-not$sourceMap.ContainsKey($job.System+'/'+$relative) -and -not$entries.ContainsKey($job.System+'/'+$relative)){$summary++}}
        $paths=@(@($Sources|Where-Object system -ceq $job.System|ForEach-Object relativePath)+@($Context.Manifest.entries|Where-Object system -ceq $job.System|ForEach-Object relativePath)|Sort-Object -Unique -CaseSensitive)
        foreach($relative in $paths){
            $key=$job.System+'/'+$relative;$path=Get-MediaRemotePath $job.System $relative
            $current=Get-MediaRemoteHash $path $Context.Session
            $source=if($sourceMap.ContainsKey($key)){$sourceMap[$key]}else{$null}
            $entry=if($entries.ContainsKey($key)){$entries[$key]}else{$null}
            $kind=''
            if($entry -and $current -and $current-cne$entry.deployedSha256){$conflicts+=('managedModified '+$key);continue}
            if($source){
                if(-not$current){$kind='create'}
                elseif(-not$entry){if($current-cne$source.hash){$conflicts+=('unmanaged collision '+$key)};continue}
                elseif($current-cne$source.hash){$kind='update'}
                else{$kind='verify'}
            }elseif($entry){$kind=if($current){'delete'}else{'forget'}}
            if($kind){$operations+=[pscustomobject]@{kind=$kind;system=$job.System;relativePath=$relative;remote=$path;oldHash=$current;newHash=$(if($source){$source.hash}else{$null});source=$source;backup=$null;attempted=$false;commitAttempted=$false}}
        }
    }
    Write-Log ('MEDIA PLAN: unmanaged Android-only preserved='+$summary+' operations='+$operations.Count)
    foreach($conflict in $conflicts){Write-Log ('MEDIA CONFLICT: '+$conflict)}
    if($conflicts.Count){throw 'media conflict: 원격 변경 전에 전체 작업 차단'}
    return ,$operations
}

function Set-MediaRemoteFile([string]$Remote,[string]$Local,[string]$ExpectedHash,[string]$Session,[string]$OldHash,$Operation=$null,$Context=$null,$Journal=$null) {
    Assert-RemotePath $Remote
    $root='/storage/emulated/0/ES-DE/downloaded_media/'
    if(-not$Remote.StartsWith($root,[StringComparison]::Ordinal)){throw 'media 전송 범위 오류'}
    $parts=$Remote.Substring($root.Length)-split'/',2
    if($parts.Count-ne2 -or (Get-MediaRemotePath $parts[0] $parts[1])-cne$Remote){throw 'media 전송 경로 오류'}
    $parent=$Remote.Substring(0,$Remote.LastIndexOf('/'))
    Ensure-RemoteDir $parent
    $temporary=$Remote+'.esde-media-new-'+[guid]::NewGuid().ToString('N')
    $attempted=$false
    try{
        if(Get-MediaRemoteHash $temporary $Session){throw 'media temp 경로 충돌'}
        $attempted=$true;$r=Invoke-Adb -s $Serial push $Local $temporary
        if($r.Code-ne0){throw 'media temp push 실패'}
        if((Get-MediaRemoteHash $temporary $Session)-cne$ExpectedHash){throw 'media 전송 SHA 검증 실패'}
        if([string](Get-MediaRemoteHash $Remote $Session)-cne$OldHash){throw 'media rename 직전 외부 변경 감지'}
        if($Operation){
            $Operation.commitAttempted=$true
            try{Write-MediaJson (Join-Path $Context.Session 'journal.json') $Journal $Context.StateRoot}
            catch{$Operation.commitAttempted=$false;throw}
        }
        $r=Invoke-Adb -s $Serial shell ('mv -f '+(Quote-Sh $temporary)+' '+(Quote-Sh $Remote))
        if($r.Code-ne0 -or $r.StdErr){throw 'media rename 실패/완료 여부 불명'}
        $attempted=$false
        if((Get-MediaRemoteHash $Remote $Session)-cne$ExpectedHash){throw 'media final SHA 검증 실패'}
    }finally{if($attempted){try{Remove-RemoteFile $temporary}catch{Write-Log ('MEDIA TEMP CLEANUP FAILED: '+$_.Exception.Message)}}}
}

function Save-MediaManifest($Context,$Manifest) {
    if($Context.OriginalBytes){
        $before=Join-Path $Context.Session 'original-manifest.json'
        if(-not(Test-Path -LiteralPath $Context.ManifestPath) -or (Get-FileHash -LiteralPath $Context.ManifestPath).Hash-cne(Get-FileHash -LiteralPath $before).Hash){throw 'media manifest concurrent modification'}
    }elseif(Test-Path -LiteralPath $Context.ManifestPath){throw 'media manifest가 실행 중 새로 생성됨'}
    Assert-MediaManifest $Manifest $Context
    # 생성한 JSON도 다시 파싱/계약 검증한다.
    $roundtrip=$Manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
    Assert-MediaManifest $roundtrip $Context
    Write-MediaJson $Context.ManifestPath $roundtrip $Context.StateRoot
}

function Restore-MediaManifest($Context,$AttemptedManifest) {
    if(Test-Path -LiteralPath $Context.ManifestPath){
        $disk=(Get-FileHash -LiteralPath $Context.ManifestPath).Hash.ToLowerInvariant()
        if($Context.OriginalBytes){
            $before=Join-Path $Context.Session 'original-manifest.json'
            if($disk-ceq(Get-FileHash -LiteralPath $before).Hash.ToLowerInvariant()){return}
        }
        $attempt=Get-MediaTextHash ($AttemptedManifest|ConvertTo-Json -Depth 12)
        if($disk-cne$attempt){throw 'manifest rollback 중 외부 변경 감지'}
    }
    if($Context.OriginalBytes){
        $temporary=$Context.ManifestPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try{
            [IO.File]::WriteAllBytes($temporary,$Context.OriginalBytes)
            if(Test-Path -LiteralPath $Context.ManifestPath){[IO.File]::Replace($temporary,$Context.ManifestPath,$Context.ManifestPath+'.bak')}
            else{[IO.File]::Move($temporary,$Context.ManifestPath)}
        }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
    }elseif(Test-Path -LiteralPath $Context.ManifestPath){[IO.File]::Delete($Context.ManifestPath)}
}

function Invoke-MediaTransaction($Plan,$Context) {
    $manifest=$Context.Manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
    $journal=[pscustomobject]@{state='applying';operations=$Plan}
    $journalPath=Join-Path $Context.Session 'journal.json'
    $committed=$false
    try{
        # 어떤 media 변경보다 먼저 모든 기존 managed 파일을 백업/검증한다.
        foreach($operation in $Plan){
            if((Get-MediaRemoteHash $operation.remote $Context.Session)-cne$operation.oldHash){throw 'media concurrent modification'}
            if($operation.kind-in@('create','update','delete')){
                if((Get-MediaRemoteHash $operation.remote $Context.Session)-cne$operation.oldHash){throw 'media concurrent modification'}
                if($operation.oldHash){
                    $operation.backup=Join-Path $Context.Session ([guid]::NewGuid().ToString('N')+'.backup')
                    $r=Invoke-Adb -s $Serial pull $operation.remote $operation.backup
                    if($r.Code-ne0 -or -not(Test-Path -LiteralPath $operation.backup) -or (Get-FileHash -LiteralPath $operation.backup).Hash-ine$operation.oldHash){throw 'media backup 검증 실패'}
                }
            }
        }
        Write-MediaJson $journalPath $journal $Context.StateRoot
        foreach($operation in $Plan){
            $key=$operation.system+'/'+$operation.relativePath
            if($operation.kind-in@('create','update','delete')){
                if((Get-MediaRemoteHash $operation.remote $Context.Session)-cne$operation.oldHash){throw 'media concurrent modification'}
                $operation.attempted=$true
                Write-MediaJson $journalPath $journal $Context.StateRoot
                if($operation.kind-eq'delete'){
                    $operation.commitAttempted=$true
                    try{Write-MediaJson $journalPath $journal $Context.StateRoot}catch{$operation.commitAttempted=$false;throw}
                    Remove-RemoteFile $operation.remote;if(Get-MediaRemoteHash $operation.remote $Context.Session){throw 'media delete 확인 실패'}
                }
                else{Set-MediaRemoteFile $operation.remote $operation.source.path $operation.newHash $Context.Session $operation.oldHash $operation $Context $journal}
                Write-Log ('MEDIA SUCCESS: '+$operation.kind+' '+$key)
            }
            $manifest.entries=@($manifest.entries|Where-Object {($_.system+'/'+$_.relativePath)-cne$key})
            if($operation.kind-in@('create','update','verify')){
                $now=(Get-Date).ToUniversalTime().ToString('o')
                $deployed=$now
                if($operation.kind-eq'verify'){$deployed=@($Context.Manifest.entries|Where-Object {($_.system+'/'+$_.relativePath)-ceq$key})[0].deployedAt}
                $manifest.entries+=[pscustomobject]@{system=$operation.system;relativePath=$operation.relativePath;sourceSha256=$operation.source.hash;deployedSha256=$operation.source.hash;sourceSize=$operation.source.size;deployedAt=$deployed;lastVerifiedAt=$now}
            }
        }
        $manifest.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Save-MediaManifest $Context $manifest
        $committed=$true;$journal.state='completed'
        Write-MediaJson $journalPath $journal $Context.StateRoot
        Write-Log 'MEDIA MANIFEST COMMIT: pass'
    }catch{
        $original=$_.Exception.Message;Write-Log ('MEDIA ORIGINAL ERROR: '+$original)
        if($committed){throw ('MEDIA FATAL: manifest commit 완료, journal 정리 필요: '+$Context.Session+' / '+$original)}
        $rollbackErrors=@()
        $attempts=@($Plan|Where-Object commitAttempted -eq $true);[array]::Reverse($attempts)
        foreach($operation in $attempts){
            if(-not$operation){continue}
            try{
                $current=Get-MediaRemoteHash $operation.remote $Context.Session
                if($current-ceq$operation.oldHash){continue}
                if($current -and $current-cne$operation.newHash){throw 'rollback 중 외부 변경 감지'}
                if($operation.oldHash){Set-MediaRemoteFile $operation.remote $operation.backup $operation.oldHash $Context.Session $current}
                elseif($current){Remove-RemoteFile $operation.remote}
                Write-Log ('MEDIA ROLLBACK: pass '+$operation.remote)
            }catch{$rollbackErrors+=$_.Exception.Message;Write-Log ('MEDIA ROLLBACK FAILED: '+$operation.remote+' '+$_.Exception.Message)}
        }
        try{Restore-MediaManifest $Context $manifest}catch{$rollbackErrors+=$_.Exception.Message;Write-Log ('MEDIA MANIFEST ROLLBACK FAILED: '+$_.Exception.Message)}
        if($rollbackErrors.Count){$journal.state='rollback_failed';try{Write-MediaJson $journalPath $journal $Context.StateRoot}catch{};throw ('MEDIA FATAL: '+$original+' / rollback: '+($rollbackErrors-join'; ')+' / backup: '+$Context.Session)}
        $journal.state='rolled_back';Write-MediaJson $journalPath $journal $Context.StateRoot
        throw $original
    }
}

function Close-MediaSession($Context) {
    if(-not$Context){return}
    try{
        $path=Join-Path $Context.Session 'journal.json';[void](Assert-MediaDiskPath $path $Context.StateRoot)
        $journal=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($journal.state-eq'preparing'){$journal.state='rolled_back';Write-MediaJson $path $journal $Context.StateRoot}
        if($journal.state-in@('completed','rolled_back')){
            foreach($file in @(Get-ChildItem -LiteralPath $Context.Session -File|Where-Object {$_.Name-cmatch'^[a-f0-9]{32}\.(source|backup|hash)$'})){
                [void](Assert-MediaDiskPath $file.FullName $Context.StateRoot);Remove-Item -LiteralPath $file.FullName
            }
        }
    }catch{Write-Log ('MEDIA SESSION CLEANUP FAILED: '+$_.Exception.Message)}
}

function Write-EsdeLifecycleLog([string]$Message) {
    try { Write-Log $Message } catch {}
}

function Invoke-EsdeSync([scriptblock]$Work) {
    $stopped = $false
    $originalError = $null
    Write-EsdeLifecycleLog 'ESDE STOPPED: false'
    try {
        Preflight-CheckForeground
        Stop-Esde
        $stopped = $true
        Write-EsdeLifecycleLog 'ESDE STOPPED: true'
        & $Work
    }
    catch {
        $originalError = $_
        Write-EsdeLifecycleLog "ORIGINAL SYNC ERROR: $($_.Exception.Message)"
        throw
    }
    finally {
        if ($stopped) {
            Write-EsdeLifecycleLog ('ESDE RESTART ATTEMPT: recovery=' + [bool]$originalError)
            try {
                Start-Esde
                Write-EsdeLifecycleLog 'ESDE RESTART SUCCESS'
            }
            catch {
                Write-EsdeLifecycleLog "ESDE RESTART FAILED: $($_.Exception.Message)"
                if (-not $originalError) { throw }
            }
        }
        else { Write-EsdeLifecycleLog 'ESDE RESTART SKIPPED: not stopped by this worker' }
    }
}

$esdeLifecycleStarted = $false
$mediaContext=$null
try {
    Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
    Write-Status "starting" "ADB 연결 확인 중..." 0 1
    Write-Log ("===== SELECTED-SYSTEM MIRROR START v" + $AppVersion.version + " =====")
    Write-Log ('ADB executable='+$AdbPath+' default WorkingDirectory='+$AdbWorkingDirectory)
    Write-EsdeLifecycleLog 'ESDE STOPPED: false (source validation pending)'

    $dev = Invoke-Adb -s $Serial get-state
    if ($dev.Code -ne 0 -or (($dev.StdOut).Trim() -ne "device")) {
        throw "ADB 기기 연결이 끊어졌습니다.`r`n$($dev.StdErr)"
    }

    foreach ($b in $Buckets) {
        if (-not (Test-Path (Join-Path $SourceRoot $b.Local))) {
            throw "원본 폴더 없음: $($b.Local)"
        }
    }

    # Selected systems are exactly the first-level system folders present in Dropbox/roms.
    $romRoot = Join-Path $SourceRoot "roms"
    Assert-LocalSourcePath $romRoot $SourceRoot
    $selectedSystems = @((Get-ChildItem -LiteralPath $romRoot -Directory | Sort-Object Name).Name)

    if ($selectedSystems.Count -eq 0) {
        throw "선택된 시스템이 없습니다. 안전을 위해 동기화를 중단합니다."
    }

    Write-Log ("SELECTED SYSTEMS: " + ($selectedSystems -join ", "))
    Write-Log "SCOPE: selected system folders only; unselected systems are never deleted or modified"

    $jobs = @()
    foreach ($b in $Buckets) {
        foreach ($sys in $selectedSystems) {
            $jobs += [pscustomobject]@{
                Bucket = $b
                System = $sys
                LocalPath = Join-Path (Join-Path $SourceRoot $b.Local) $sys
                RemotePath = $b.Remote.TrimEnd("/") + "/" + $sys
            }
        }
    }

    # 전체 원본 검증을 마쳐야 어떤 시스템의 삭제도 시작할 수 있다.
    foreach ($job in $jobs) {
        Assert-LocalSourcePath (Split-Path -Parent $job.LocalPath) $SourceRoot
        if (Test-Path -LiteralPath $job.LocalPath) { [void]@(Get-ManagedLocalItems $job.LocalPath $SourceRoot) }
        if($job.Bucket.Local-eq'gamelists'){$job|Add-Member -NotePropertyName GamelistSource -NotePropertyValue (Get-GamelistSource $job.LocalPath)}
    }
    $mediaJobs=@($jobs|Where-Object {$_.Bucket.Local-eq'downloaded_media'})
    $mediaContext=New-MediaContext $StateDir $SourceRoot $Serial
    $mediaSources=@(Get-MediaSourceFiles $mediaJobs $mediaContext)
    $adoptionContext=New-AdoptionExecutorContext $StateDir $SourceRoot $Serial $selectedSystems -DeferJournalGate
    $romContext=New-RomPreservationContext $StateDir $SourceRoot $Serial

    $esdeLifecycleStarted = $true
    Invoke-EsdeSync {
        $gamelistSession=Join-Path ([IO.Path]::GetTempPath()) ('ESDE-gamelist-'+[guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $gamelistSession)
        try {
        # ES-DE 종료 후 모든 Android XML을 pull/병합 검증해야 어떤 bucket의 변경도 시작한다.
        $romPlans=@{}
        foreach($job in $jobs){if($job.Bucket.Local-eq'roms'){$romPlans[$job.System]=Prepare-RomPreservationPlan $job $romContext}}
        $gamelistPlans=@{}
        foreach($job in $jobs){if($job.Bucket.Local-eq'gamelists'){$gamelistPlans[$job.System]=Prepare-GamelistSystem $job $gamelistSession @($romPlans[$job.System].Unmanaged|ForEach-Object {'./'+$_})}}
        $adoptions=@()
        foreach($system in $selectedSystems){
            $romJob=@($jobs|Where-Object {$_.System-ceq$system -and $_.Bucket.Local-eq'roms'})[0]
            $xmlJob=@($jobs|Where-Object {$_.System-ceq$system -and $_.Bucket.Local-eq'gamelists'})[0]
            $plan=Prepare-UnregisteredAdoptionSystem $romJob $xmlJob $gamelistPlans[$system] $adoptionContext $gamelistSession
            if($plan){$adoptions+=$plan}
        }
        $mediaPlan=Prepare-MediaPlan $mediaJobs $mediaSources $mediaContext
        if(-not$adoptions.Count){[void](New-AdoptionExecutorContext $StateDir $SourceRoot $Serial $selectedSystems)}
        $adopted=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        if($adoptions.Count){
            $combined=[pscustomobject]@{Validated=$true;Identity=$adoptionContext.Identity;Entries=@($adoptions|ForEach-Object Entries);Systems=@($adoptions|ForEach-Object Systems);Session=$gamelistSession}
            $outcome=Invoke-AdoptionWithCapabilityGate $combined $adoptionContext
            if($outcome.Applied){foreach($p in $combined.Systems){[void]$adopted.Add($p.System)}}
        }
        $mediaApplied=$false
        $i = 0
        foreach ($job in $jobs) {
            $i++
            $label = "$($job.Bucket.Name): $($job.System)"
            Write-Status "running" "$label 처리 중..." $i $jobs.Count
            Write-Log "PROCESS $label"
    
            if($job.Bucket.Local-eq'gamelists'){
                if(-not$adopted.Contains($job.System)){Sync-GamelistSystem $gamelistPlans[$job.System]}
            }
            elseif($job.Bucket.Local-eq'downloaded_media'){
                if(-not$mediaApplied){Invoke-MediaTransaction $mediaPlan $mediaContext;$mediaApplied=$true}
            }
            elseif (Test-Path -LiteralPath $job.LocalPath) {
                Sync-PreservedRomSystem $job $romPlans[$job.System] $romContext $label
            }
            else {
                # The system is selected via ROMs, but this bucket has no corresponding folder in Dropbox.
                # Within the selected-system scope, absence means the Android counterpart should also be absent.
                if ($job.Bucket.Local -eq 'roms') {
                    Write-Log "  SOURCE ROM FOLDER ABSENT -> REMOVE MANAGED CONTENTS; PRESERVE RESERVED"
                    Remove-ManagedRemoteContents $job.RemotePath
                }
                else {
                    Write-Log "  SOURCE SYSTEM FOLDER ABSENT -> VALIDATE LISTS AND REMOVE REMOTE SYSTEM FOLDER"
                    [void]@(Get-RemoteFiles $job.RemotePath)
                    [void]@(Get-RemoteDirs $job.RemotePath)
                    Remove-RemoteTree $job.RemotePath
                }
            }
        }
        } finally {
            try {
                $incomplete=@();try{[void](New-AdoptionExecutorContext $StateDir $SourceRoot $Serial $selectedSystems)}catch{$incomplete=@($_)}
                if($incomplete.Count){Write-Log ('ADOPTION STAGING PRESERVED: '+$gamelistSession)}
                else{[IO.Directory]::Delete($gamelistSession,$true); Write-Log 'GAMELIST PC STAGING CLEANUP: pass'}
            }
            catch { Write-Log ('GAMELIST PC STAGING CLEANUP FAILED: '+$_.Exception.Message) }
        }
    }
    Write-Status "done" "동기화 완료" $jobs.Count $jobs.Count
    Write-Log "===== SELECTED-SYSTEM MIRROR COMPLETE ====="
    exit 0
}
catch {
    $msg = $_.Exception.Message
    if (-not $esdeLifecycleStarted) {
        Write-EsdeLifecycleLog 'ESDE RESTART SKIPPED: failed before ES-DE stop'
    }
    try { Write-Log ("ERROR: " + $msg) } catch {}
    try { Write-Status "error" ("오류: " + $msg) 0 100 } catch {}
    exit 1
}

}
finally {
    try { if($mediaContext){Close-MediaSession $mediaContext} }
    finally { [Environment]::CurrentDirectory=$PreviousProcessDirectory; Exit-AppMutex $OperationMutex }
}
