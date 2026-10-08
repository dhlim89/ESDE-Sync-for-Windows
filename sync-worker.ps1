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
    }

    $esdeLifecycleStarted = $true
    Invoke-EsdeSync {
        $i = 0
        foreach ($job in $jobs) {
            $i++
            $label = "$($job.Bucket.Name): $($job.System)"
            Write-Status "running" "$label 처리 중..." $i $jobs.Count
            Write-Log "PROCESS $label"
    
            if (Test-Path -LiteralPath $job.LocalPath) {
                Mirror-SystemFolder $job.LocalPath $job.RemotePath $label
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
finally { [Environment]::CurrentDirectory=$PreviousProcessDirectory; Exit-AppMutex $OperationMutex }
