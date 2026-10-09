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

function Write-Status([string]$State,[string]$Message,[int]$Current,[int]$Total,$Summary=$null) {
    $percent = 0
    if ($Total -gt 0) { $percent = [math]::Floor(($Current / $Total) * 100) }
    $record=@{state=$State;message=$Message;current=$Current;total=$Total;percent=$percent}
    if($null-ne$Summary){$record.summary=$Summary}
    $record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $StatusFile -Encoding UTF8
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

$LocalOnlyFolders = @('_TEST', '_UNREGISTERED')
$ReservedFolders = $LocalOnlyFolders

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


function Is-LocalOnlyRelativePath([string]$Path) { return (Is-ExcludedRelativePath $Path) }

function Get-ClassificationRelativePath([string]$System,[string]$Path,[string[]]$Systems) {
    if($System-cnotin$Systems -or $System-cnotmatch'^[a-zA-Z0-9_-]+$' -or $System-in@('_TEST','_UNREGISTERED')){throw 'CLASSIFICATION BLOCK: system scope'}
    $info=Get-EsdeGamePathInfo $Path
    if($info.Class-ne'Managed'){throw 'CLASSIFICATION BLOCK: normal relative path required'}
    $relative=$info.Key.Substring(2)
    foreach($part in $relative.Split('/')){
        if($part-match'[<>:"|?*]' -or $part-match'[. ]$' -or $part-match'^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'CLASSIFICATION BLOCK: invalid/reserved segment'}
    }
    return $relative
}

function Get-ClassificationExtensions([string]$System) {
    # Stage 1의 실제 ES-DE GB/GBC 정의에서 확인된 extension만.
    if($System-cnotin@('gb','gbc')){throw 'CLASSIFICATION BLOCK: ROM extension policy unresolved'}
    return @('.gb','.gbc','.dmg','.gbx','.bs','.cgb','.sgb','.sfc','.smc','.zip','.7z')
}

function Is-ClassificationAuxiliaryPath([string]$Path) {
    # These are data/sidecars, never ROM classification or automatic relocation sources.
    return ($Path-cin@('metadata.txt','systeminfo.txt') -or [IO.Path]::GetExtension($Path).ToLowerInvariant()-cin@('.sav','.srm','.rtc') -or $Path-match'(?i)\.state(?:[0-9]+|\.auto)?$')
}

function New-UnregisteredClassificationPlan([string]$System,[object[]]$Source,[object[]]$Android,[object[]]$Destinations,[string[]]$Systems) {
    $index=New-ManagedRomShaIndex $System $Source $Systems
    $managed=$index.Paths
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $dest=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($row in $Destinations){
        if($dest.ContainsKey($row.RelativePath)){throw 'CLASSIFICATION BLOCK: destination case collision'}
        $dest.Add($row.RelativePath,$row)
    }
    $plan=@()
    foreach($row in $Android){
        $result=[pscustomobject]@{System=$System;RelativePath=$row.RelativePath;AndroidRelativePath=$row.RelativePath;Sha256=$row.Sha256;AndroidSha256=$row.Sha256;ManagedSha256=$null;MatchedDropboxPaths=@();MatchedShaPaths=@();Classification='INVALID';Status='INVALID';Reason='';Action='BLOCK';DestinationRelativePath=$null}
        try{$relative=Get-ClassificationRelativePath $System $row.RelativePath $Systems}catch{
            if(Is-LocalOnlyRelativePath $row.RelativePath){
                # Local-only still requires a valid XML/path shape before being protected.
                $info=Get-EsdeGamePathInfo $row.RelativePath
                if($info.Class-ne'Invalid'){$result.Classification='LOCAL_ONLY';$result.Status='LOCAL_ONLY';$result.Action='PRESERVE';$result.Reason='local-only folder';$plan+=$result;continue}
            }
            $result.Reason=$_.Exception.Message;$plan+=$result;continue
        }
        if(Is-LocalOnlyRelativePath $row.RelativePath){
            $result.Classification='LOCAL_ONLY';$result.Status='LOCAL_ONLY';$result.Action='PRESERVE';$result.Reason='local-only folder';$plan+=$result;continue
        }
        if(-not$seen.Add($relative)){$result.Reason='Android case collision';$plan+=$result;continue}
        if($row.Sha256-cnotmatch'^[a-f0-9]{64}$'){$result.Reason='Android hash unknown';$plan+=$result;continue}
        if([IO.Path]::GetExtension($relative).ToLowerInvariant()-cnotin(Get-ClassificationExtensions $System)){$result.Reason='invalid ROM extension';$plan+=$result;continue}
        if($managed.ContainsKey($relative)){$result.MatchedDropboxPaths=@($managed[$relative].RelativePath);$result.ManagedSha256=$managed[$relative].Sha256}
        if($index.Hashes.ContainsKey($row.Sha256)){$result.MatchedShaPaths=@($index.Hashes[$row.Sha256])}
        if($result.MatchedShaPaths.Count-gt1){$result.Classification='AMBIGUOUS';$result.Action='REVIEW';$result.Reason='multiple managed SHA candidates'}
        elseif($managed.ContainsKey($relative) -and $managed[$relative].RelativePath-ceq$relative){
            if($managed[$relative].Sha256-ceq$row.Sha256){$result.Classification='MANAGED';$result.Action='SYNC';$result.Reason='canonical path and SHA match'}
            else{$result.Classification='MANAGED_CONFLICT';$result.Action='PRESERVE_AND_WARN';$result.Reason='ROM version/revision/patch requires review; managed metadata remains applicable'}
        }
        elseif($result.MatchedShaPaths.Count-eq1){$result.Classification='MANAGED_PATH_MISMATCH';$result.Action='REVIEW';$result.Reason='save/state/media canonicalization mapping not verified'}
        elseif($managed.ContainsKey($relative)){$result.Classification='AMBIGUOUS';$result.Action='REVIEW';$result.Reason='case-insensitive canonical path collision'}
        else{
            $result.Classification='UNMANAGED';$result.Action='MOVE_TO_UNREGISTERED';$result.Reason='no managed path or SHA match';$result.DestinationRelativePath='_UNREGISTERED/'+$relative
            if($dest.ContainsKey($result.DestinationRelativePath)){
                $result.Action='BLOCK';$result.Reason=if($dest[$result.DestinationRelativePath].Sha256-ceq$row.Sha256){'DESTINATION_DUPLICATE_BLOCK'}else{'DESTINATION_COLLISION'}
            }
        }
        $result.Status=$result.Classification;$plan+=$result
    }
    return @($plan)
}

function New-ManagedRomShaIndex([string]$System,[object[]]$Source,[string[]]$Systems) {
    if($System-cnotin$Systems){throw 'CLASSIFICATION BLOCK: system scope'}
    $paths=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $hashes=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($row in $Source){
        if(Is-LocalOnlyRelativePath $row.RelativePath){continue}
        $relative=Get-ClassificationRelativePath $System $row.RelativePath $Systems
        if(Is-ClassificationAuxiliaryPath $relative){continue}
        if([IO.Path]::GetExtension($relative).ToLowerInvariant()-cnotin(Get-ClassificationExtensions $System)){throw 'CLASSIFICATION BLOCK: invalid source ROM extension'}
        if($row.Sha256-cnotmatch'^[a-f0-9]{64}$'){throw 'CLASSIFICATION BLOCK: source hash unknown'}
        if($paths.ContainsKey($relative)){throw 'CLASSIFICATION BLOCK: source case collision'}
        $paths.Add($relative,$row)
        if(-not$hashes.ContainsKey($row.Sha256)){$hashes.Add($row.Sha256,@())}
        $hashes[$row.Sha256]=@($hashes[$row.Sha256])+@($relative)
    }
    return [pscustomobject]@{System=$System;Paths=$paths;Hashes=$hashes}
}

function Get-RomClassificationNotice($Entry) {
    $message=switch($Entry.Classification){
        'MANAGED_CONFLICT' {'관리 라이브러리와 기기의 ROM 파일명이 같지만 파일 내용이 다릅니다. 기기의 ROM은 보존하며 덮어쓰거나 이동하지 않습니다. 게임 버전, 리비전, 번역/패치 여부를 확인해 주세요.'}
        'MANAGED_PATH_MISMATCH' {'기기에 관리 라이브러리와 내용이 같은 ROM이 있지만 파일 이름 또는 경로가 다릅니다. 중복 ROM은 생성하지 않습니다. 세이브/상태 파일 연결을 보호하기 위해 자동 이름 변경을 수행하지 않습니다.'}
        'AMBIGUOUS' {'정확한 관리 ROM 대응 경로를 결정할 수 없습니다. 같은 내용의 후보가 여러 개이거나 경로 대응이 모호하여 자동 변경을 수행하지 않습니다. 관리 후보 경로를 확인해 주세요.'}
        default {''}
    }
    $canonical=if(@($Entry.MatchedDropboxPaths).Count){@($Entry.MatchedDropboxPaths)}else{@($Entry.MatchedShaPaths)}
    return [pscustomobject]@{System=$Entry.System;RelativePath=$Entry.RelativePath;Classification=$Entry.Classification;Action=$Entry.Action;ManagedSha256=$Entry.ManagedSha256;AndroidSha256=$Entry.AndroidSha256;CanonicalPaths=@($canonical);ShaCandidates=@($Entry.MatchedShaPaths);Reason=$Entry.Reason;Message=$message}
}

function Write-RomClassificationNotice($Entry) {
    $notice=Get-RomClassificationNotice $Entry
    if($notice.Message){
        Write-Log ('ROM WARNING: '+$notice.Classification+' '+$notice.System+'/'+$notice.RelativePath+' action='+$notice.Action+' managedSHA='+$notice.ManagedSha256+' androidSHA='+$notice.AndroidSha256+' canonical='+($notice.CanonicalPaths -join ',')+' SHA-candidates='+($notice.ShaCandidates -join ',')+' / '+$notice.Message)
    }
}

function Get-RomReviewSummary([object[]]$Entries) {
    # UI-independent proposal. Do not change GUI/status contracts in this stage.
    $items=@($Entries|Where-Object {$_.Classification-in@('MANAGED_CONFLICT','MANAGED_PATH_MISMATCH','AMBIGUOUS')}|ForEach-Object {Get-RomClassificationNotice $_})
    $reasons=@($items|Group-Object Classification,Reason|ForEach-Object {[pscustomobject]@{ReasonCode=$_.Group[0].Classification;Reason=$_.Group[0].Reason;Count=$_.Count}})
    return [pscustomobject]@{
        ManagedCount=@($Entries|Where-Object Classification -CEQ MANAGED).Count
        ManagedConflictCount=@($Entries|Where-Object Classification -CEQ MANAGED_CONFLICT).Count
        UnmanagedMoveCount=@($Entries|Where-Object Action -CEQ MOVE_TO_UNREGISTERED).Count
        LocalOnlyCount=@($Entries|Where-Object Classification -CEQ LOCAL_ONLY).Count
        ReviewCount=$items.Count
        NoMutationReviewCount=@($Entries|Where-Object Action -CEQ REVIEW).Count
        Reasons=$reasons;Items=$items
    }
}

function Get-RomReviewIsolation([object[]]$Entries) {
    $review=@($Entries|Where-Object Action -CEQ REVIEW)
    $paths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $groups=@()
    foreach($group in @($review|Group-Object Sha256)){
        $android=@($group.Group|ForEach-Object RelativePath|Sort-Object -Unique)
        $candidates=@($group.Group|ForEach-Object {@($_.MatchedDropboxPaths)+@($_.MatchedShaPaths)}|Sort-Object -Unique)
        foreach($path in @($android)+@($candidates)){[void]$paths.Add($path)}
        $groups+=[pscustomobject]@{Sha256=$group.Name;AndroidPaths=$android;ManagedCandidatePaths=$candidates;RomAction='Preserve';GamelistAction='PreserveExisting';MediaAction='ReviewSystem'}
    }
    return [pscustomobject]@{Groups=$groups;ExcludedRomPaths=@($paths);PreservedGamePaths=@($paths|ForEach-Object {'./'+$_});HoldMedia=($review.Count-gt0)}
}

function New-ManagedCanonicalizationPlan($Classification,$Mapping,[object[]]$Bindings,[string[]]$ExistingPaths,[string[]]$ExistingGamePaths=@()) {
    # Pure proposal only. No real emulator is currently registered as verified.
    $review=[pscustomobject]@{Status='REVIEW';Reason='save/state/media mapping not verified';Operations=@()}
    if($Classification.Classification-cne'MANAGED_PATH_MISMATCH'){return $review}
    if(-not$Mapping -or $Mapping.schemaVersion-ne1 -or $Mapping.Verified-ne$true -or $Mapping.CompleteInventory-ne$true -or $Mapping.System-cne$Classification.System -or [string]::IsNullOrWhiteSpace($Mapping.Evidence)){return $review}
    if(@($Classification.MatchedShaPaths).Count-ne1){return $review}
    $roots=@{ROM=('/storage/emulated/0/ROMs/'+$Classification.System);Save=$Mapping.SaveRoot;State=$Mapping.StateRoot;Media=$Mapping.MediaRoot}
    $operations=@();$sources=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $targets=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($binding in $Bindings){
        if($binding.Kind-cnotin@('ROM','Save','State','Media')){throw 'CANONICALIZATION BLOCK: invalid binding kind'}
        $root=[string]$roots[$binding.Kind]
        if(-not$root.StartsWith('/storage/emulated/0/') -or $root.Contains('..')){throw 'CANONICALIZATION BLOCK: unknown asset root'}
        foreach($path in @($binding.SourcePath,$binding.DestinationPath)){
            if(-not$path.StartsWith($root.TrimEnd('/')+'/',[StringComparison]::Ordinal) -or (Get-EsdeGamePathInfo $path.Substring($root.TrimEnd('/').Length+1)).Class-ne'Managed'){throw 'CANONICALIZATION BLOCK: asset scope/path'}
        }
        if($binding.Sha256-cnotmatch'^[a-f0-9]{64}$' -or -not$sources.Add($binding.SourcePath) -or -not$targets.Add($binding.DestinationPath) -or $ExistingPaths-icontains$binding.DestinationPath){throw 'CANONICALIZATION BLOCK: collision or hash unknown'}
        $operations+=[pscustomobject]@{Kind=$binding.Kind;Action='Rename';SourcePath=$binding.SourcePath;DestinationPath=$binding.DestinationPath;Sha256=$binding.Sha256}
    }
    $rom=@($operations|Where-Object Kind -CEQ ROM)
    if($rom.Count-ne1 -or $rom[0].SourcePath-cne($roots.ROM+'/'+$Classification.RelativePath) -or $rom[0].DestinationPath-cne($roots.ROM+'/'+$Classification.MatchedShaPaths[0]) -or $rom[0].Sha256-cne$Classification.Sha256){throw 'CANONICALIZATION BLOCK: ROM binding mismatch'}
    # A ROM-only proposal is never accepted. Absent assets also need explicit verified evidence.
    foreach($kind in @('Save','State','Media')){
        $count=@($operations|Where-Object Kind -CEQ $kind).Count
        if(-not$count -and @($Mapping.VerifiedAbsentKinds)-cnotcontains$kind){return $review}
    }
    $gameTarget='./'+$Classification.MatchedShaPaths[0]
    foreach($path in $ExistingGamePaths){
        $info=Get-EsdeGamePathInfo $path
        if($info.Class-ceq'Invalid' -or $info.Key-ceq$gameTarget){throw 'CANONICALIZATION BLOCK: gamelist path collision/invalid'}
    }
    $operations+=[pscustomobject]@{Kind='Gamelist';Action='UpdatePath';SourcePath=('./'+$Classification.RelativePath);DestinationPath=$gameTarget;Sha256=$null}
    return [pscustomobject]@{Status='CANONICALIZATION_CANDIDATE';Reason=$Mapping.Evidence;Operations=$operations}
}

function Get-ClassificationSourceRows($Job) {
    foreach($item in @(Get-ManagedLocalItems $Job.LocalPath $SourceRoot|Where-Object {-not$_.PSIsContainer})){
        $relative=$item.FullName.Substring($Job.LocalPath.Length).TrimStart('\','/').Replace('\','/')
        [pscustomobject]@{RelativePath=$relative;Sha256=(Get-FileHash -LiteralPath $item.FullName).Hash.ToLowerInvariant();FullName=$item.FullName}
    }
}

function Assert-ClassificationRemoteLinks([string]$Root) {
    Assert-RemotePath ($Root+'/scope-probe')
    $q=Quote-Sh $Root
    $cmd='if [ -L '+$q+' ]; then exit 1; elif [ -d '+$q+' ]; then cd '+$q+' || exit 1; find '+$q+' -mindepth 1 \( -type d \( -iname _TEST -o -iname _UNREGISTERED \) -prune \) -o \( -type l -print \); elif [ -e '+$q+' ]; then exit 1; fi'
    $r=Invoke-Adb -s $Serial shell $cmd
    if($r.Code-ne0 -or $r.StdErr -or $r.StdOut.Trim()){throw 'CLASSIFICATION BLOCK: remote link/inventory uncertainty'}
}

function Test-LocalOnlySystemPresence([string]$Root) {
    $paths=@(($Root+'/_TEST'),($Root+'/_UNREGISTERED'))
    $cmd='if [ -e '+(Quote-Sh $paths[0])+' ] || [ -e '+(Quote-Sh $paths[1])+' ]; then printf PRESENT; else printf ABSENT; fi'
    $r=Invoke-Adb -s $Serial shell $cmd
    if($r.Code-ne0 -or $r.StdErr -or $r.StdOut-cnotin@('PRESENT','ABSENT')){throw 'local-only presence unknown'}
    return $r.StdOut-ceq'PRESENT'
}

function Get-ClassificationAndroidRows($Job,[string]$Session) {
    Assert-ClassificationRemoteLinks $Job.RemotePath
    foreach($relative in @(Get-RemoteFiles $Job.RemotePath)){
        # 기존 ES-DE sidecar는 ROM이 아님. 나머지 미확정 파일은 이동/삭제 대신 차단.
        if(Is-ClassificationAuxiliaryPath $relative){Write-Log ('ROM PRESERVE AUXILIARY: '+$Job.System+'/'+$relative);continue}
        $relative=Get-ClassificationRelativePath $Job.System $relative $selectedSystems
        $read=Read-ClassificationRom ($Job.RemotePath+'/'+$relative) $Session
        if(-not$read){throw 'CLASSIFICATION BLOCK: inventory changed'}
        [pscustomobject]@{RelativePath=$relative;Sha256=$read.Sha256}
    }
}

function New-ClassificationContext([string]$StateRoot,[string]$Source,[string]$Device) {
    $root=[IO.Path]::GetFullPath($Source).TrimEnd('\')
    $identity=Get-MediaTextHash ($root.ToLowerInvariant()+'|'+$Device)
    $folder=Join-Path $StateRoot 'android-classification'
    $file=Join-Path $folder ($identity+'.json')
    [void](Assert-MediaDiskPath $file $StateRoot)
    if(Test-Path -LiteralPath $file){
        $state=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
        if($state.schemaVersion-ne1 -or $state.identity-cne$identity -or $state.status-cne'completed'){throw 'CLASSIFICATION RECOVERY NEEDED: previous state requires manual review'}
    }
    return [pscustomobject]@{Identity=$identity;File=$file;StateRoot=$StateRoot;SourceRoot=$root;Serial=$Device}
}

function Prepare-ClassificationSystem($RomJob,$XmlJob,$XmlPlan,[string]$Session) {
    $source=@(Get-ClassificationSourceRows $RomJob)
    $android=@(Get-ClassificationAndroidRows $RomJob $Session)
    $destinations=@()
    foreach($row in $android){
        $destination=Read-ClassificationRom ($RomJob.RemotePath+'/_UNREGISTERED/'+$row.RelativePath) $Session
        if($destination){$destinations+=[pscustomobject]@{RelativePath=('_UNREGISTERED/'+$row.RelativePath);Sha256=$destination.Sha256}}
    }
    $classification=@(New-UnregisteredClassificationPlan $RomJob.System $source $android $destinations $selectedSystems)
    $blocked=@($classification|Where-Object Action -CEQ BLOCK)
    if($blocked.Count){throw ('CLASSIFICATION BLOCK: '+(($blocked|ForEach-Object {$_.RelativePath+': '+$_.Reason}) -join '; '))}
    $review=@($classification|Where-Object Action -CEQ REVIEW).Count-gt0
    foreach($entry in @($classification|Where-Object {$_.Classification-in@('MANAGED_CONFLICT','MANAGED_PATH_MISMATCH','AMBIGUOUS')})){
        Write-RomClassificationNotice $entry
    }
    $moves=@($classification|Where-Object Action -EQ MOVE_TO_UNREGISTERED)
    $isolation=Get-RomReviewIsolation $classification
    if($review){Write-Log ('ROM REVIEW: '+$RomJob.System+' 검토 경로/후보만 ROM 제외, existing XML 보존, system media 보류')}
    $local=if($XmlPlan.Local){ConvertFrom-EsdeGamelistBytes $XmlPlan.Local.Bytes}else{$null}
    $existing=@(Get-EsdeGameEntries $local)
    foreach($move in $moves){
        $key='./'+$move.RelativePath;$new='./'+$move.DestinationRelativePath
        if(@($existing|Where-Object Key -CEQ $new).Count){throw ('CLASSIFICATION BLOCK: destination game node collision '+$new)}
        $nodes=@($existing|Where-Object Key -CEQ $key)
        if($nodes.Count-gt1){throw 'CLASSIFICATION BLOCK: duplicate source game'}
        if($nodes.Count){$nodes[0].Node.SelectSingleNode('path').InnerText=$new}
        $move|Add-Member SourcePath ($RomJob.RemotePath+'/'+$move.RelativePath)
        $move|Add-Member DestinationPath ($RomJob.RemotePath+'/'+$move.DestinationRelativePath)
    }
    if($local){$local.Bytes=ConvertTo-EsdeGamelistBytes $local}
    # ROM source of truth: normal nodes not backed by source ROM remain whole-node (stale included).
    $sourceKeys=@($source|Where-Object {-not(Is-ClassificationAuxiliaryPath $_.RelativePath)}|ForEach-Object {'./'+$_.RelativePath})
    $preserve=@(Get-EsdeGameEntries $local|Where-Object {$_.Class-eq'Managed' -and $sourceKeys-cnotcontains$_.Key}|ForEach-Object Key)
    $preserve+=@($isolation.PreservedGamePaths)
    $master=$XmlJob.GamelistSource
    if($review -and $master){
        $master=ConvertFrom-EsdeGamelistBytes $master.Bytes
        foreach($entry in @(Get-EsdeGameEntries $master)){
            if($isolation.PreservedGamePaths-ccontains$entry.Key){[void]$entry.Node.ParentNode.RemoveChild($entry.Node)}
        }
        $master.Bytes=ConvertTo-EsdeGamelistBytes $master
    }
    $bound=Get-AndroidBoundGamelist $master $local $RomJob.System $preserve
    $output=$null
    if($bound){$output=Join-Path $Session ([guid]::NewGuid().ToString('N')+'-classified.xml');[void](Write-EsdeGamelist $bound $output)}
    $xml=$XmlPlan.PSObject.Copy();$xml.Output=$output
    return [pscustomobject]@{System=$RomJob.System;RomJob=$RomJob;Source=$source;Moves=$moves;Inventory=$classification;XmlPlan=$xml;Session=$Session;ReviewRequired=$review;ReviewIsolation=$isolation;ProtectMedia=($review -or $moves.Count-gt0 -or (Test-LocalOnlySystemPresence $RomJob.RemotePath) -or @(Get-LocalOnlyGameEntries $local).Count-gt0);Validated=$true}
}

function Assert-ClassificationSourceSnapshot($Plan) {
    $current=@(Get-ClassificationSourceRows $Plan.RomJob)
    if(($current|Select-Object RelativePath,Sha256|ConvertTo-Json -Compress)-cne($Plan.Source|Select-Object RelativePath,Sha256|ConvertTo-Json -Compress)){throw 'CLASSIFICATION BLOCK: managed source changed'}
}

function Invoke-ClassificationMoves([object[]]$Plans,$Context,[string]$Session) {
    $moving=@($Plans|Where-Object {$_.Moves.Count-gt0})
    if(-not$moving.Count){return}
    foreach($plan in $Plans){
        if(-not$plan.Validated){throw 'classification plan not validated'}
        Assert-ClassificationSourceSnapshot $plan
        Assert-GamelistSnapshot $plan.XmlPlan
        foreach($move in $plan.Moves){
            $relative=Get-ClassificationRelativePath $plan.System $move.RelativePath $selectedSystems
            if($move.SourcePath-cne($plan.RomJob.RemotePath+'/'+$relative) -or $move.DestinationPath-cne($plan.RomJob.RemotePath+'/_UNREGISTERED/'+$relative)){throw 'CLASSIFICATION BLOCK: move path tampered'}
            $src=Read-ClassificationRom $move.SourcePath $Session
            if(-not$src -or $src.Sha256-cne$move.Sha256 -or (Read-ClassificationRom $move.DestinationPath $Session)){throw 'CLASSIFICATION BLOCK: concurrent ROM change/collision'}
        }
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Context.File))
    $state=[pscustomobject]@{schemaVersion=1;identity=$Context.Identity;status='prepared';at=[DateTimeOffset]::UtcNow.ToString('o');moves=@($moving|ForEach-Object Moves|Select-Object SourcePath,DestinationPath,Sha256);error='';staging=$Session}
    Write-MediaJson $Context.File $state $Context.StateRoot
    try{
        foreach($plan in $moving){
            foreach($move in $plan.Moves){
                # same storage device check; no copy/delete fallback.
                $r=Invoke-Adb -s $Serial shell ('stat -c %d '+(Quote-Sh $move.SourcePath)+' '+(Quote-Sh $plan.RomJob.RemotePath))
                $devices=@($r.StdOut.Trim()-split'\r?\n')
                if($r.Code-ne0 -or $r.StdErr -or $devices.Count-ne2 -or $devices[0]-cne$devices[1]){throw 'CLASSIFICATION BLOCK: filesystem identity unknown/different'}
                $parent=$move.DestinationPath.Substring(0,$move.DestinationPath.LastIndexOf('/'))
                # source/hash/destination recheck immediately before no-clobber rename.
                $src=Read-ClassificationRom $move.SourcePath $Session
                if(-not$src -or $src.Sha256-cne$move.Sha256 -or (Read-ClassificationRom $move.DestinationPath $Session)){throw 'CLASSIFICATION BLOCK: move race'}
                Ensure-RemoteDir $parent
                if(Read-ClassificationRom $move.DestinationPath $Session){throw 'CLASSIFICATION BLOCK: destination appeared'}
                $r=Invoke-Adb -s $Serial shell ('stat -c %d '+(Quote-Sh $move.SourcePath)+' '+(Quote-Sh $parent))
                $devices=@($r.StdOut.Trim()-split'\r?\n')
                if($r.Code-ne0 -or $r.StdErr -or $devices.Count-ne2 -or $devices[0]-cne$devices[1]){throw 'CLASSIFICATION BLOCK: destination filesystem differs'}
                $state.status='moving';Write-MediaJson $Context.File $state $Context.StateRoot
                $r=Invoke-Adb -s $Serial shell ('mv -n '+(Quote-Sh $move.SourcePath)+' '+(Quote-Sh $move.DestinationPath))
                if($r.Code-ne0 -or $r.StdErr){throw 'CLASSIFICATION RECOVERY NEEDED: mv failed'}
                $dst=Read-ClassificationRom $move.DestinationPath $Session
                if(-not$dst -or $dst.Sha256-cne$move.Sha256 -or (Read-ClassificationRom $move.SourcePath $Session)){throw 'CLASSIFICATION RECOVERY NEEDED: move verification failed'}
            }
        }
        $state.status='roms-moved';Write-MediaJson $Context.File $state $Context.StateRoot
        foreach($plan in $moving){
            Assert-ClassificationSourceSnapshot $plan
            Sync-GamelistSystem $plan.XmlPlan
            if($plan.XmlPlan.Output){
                $back=Join-Path $Session ([guid]::NewGuid().ToString('N')+'-final.xml')
                $r=Invoke-Adb -s $Serial pull $plan.XmlPlan.RemoteFile $back
                if($r.Code-ne0 -or (Get-FileHash -LiteralPath $back).Hash-cne(Get-FileHash -LiteralPath $plan.XmlPlan.Output).Hash){throw 'CLASSIFICATION RECOVERY NEEDED: XML final SHA'}
                [void](Read-EsdeGamelist $back)
            }
            $plan.XmlPlan.ClassificationCommitted=$true
        }
        $state.status='completed';Write-MediaJson $Context.File $state $Context.StateRoot
    }catch{
        $state.status='recovery-needed';$state.error=$_.Exception.Message
        try{Write-MediaJson $Context.File $state $Context.StateRoot}catch{Write-Log ('CLASSIFICATION STATE SAVE FAILED: '+$_.Exception.Message)}
        throw
    }
}

function Confirm-ClassificationInventory($Plan,[string]$Session) {
    Assert-ClassificationSourceSnapshot $Plan
    $rows=@(Get-ClassificationAndroidRows $Plan.RomJob $Session)
    $refresh=@(New-UnregisteredClassificationPlan $Plan.System $Plan.Source $rows @() $selectedSystems)
    if(@($refresh|Where-Object Action -EQ MOVE_TO_UNREGISTERED).Count){throw 'CLASSIFICATION BLOCK: new unmanaged ROM after prepared inventory'}
    if(@($refresh|Where-Object Action -CEQ BLOCK).Count){throw 'CLASSIFICATION BLOCK: invalid refreshed inventory'}
    $expected=@($Plan.Inventory|Where-Object {$_.Action-cne'MOVE_TO_UNREGISTERED' -and $_.Classification-cne'LOCAL_ONLY'}|Sort-Object RelativePath|Select-Object RelativePath,Sha256,Classification|ConvertTo-Json -Compress)
    $actual=@($refresh|Sort-Object RelativePath|Select-Object RelativePath,Sha256,Classification|ConvertTo-Json -Compress)
    if(($expected -join '')-cne($actual -join '')){throw 'CLASSIFICATION BLOCK: ROM inventory changed after prepare'}
}

function Sync-ClassifiedManagedRom($Job,$Plan,[string]$Label) {
    if($Job.System-cne$Plan.System -or $Job.RemotePath-cne$Plan.RomJob.RemotePath){throw 'managed mirror scope'}
    $files=(Get-Item Function:Get-RemoteFiles).ScriptBlock;$dirs=(Get-Item Function:Get-RemoteDirs).ScriptBlock
    $adb=(Get-Item Function:Invoke-Adb).ScriptBlock
    $allowed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $conflicts=@($Plan.Inventory|Where-Object Classification -CEQ MANAGED_CONFLICT|ForEach-Object RelativePath)
    $conflicts+=@($Plan.ReviewIsolation.ExcludedRomPaths)
    $transfer=@($Plan.Source|Where-Object {$conflicts-cnotcontains$_.RelativePath -and (-not(Is-ClassificationAuxiliaryPath $_.RelativePath) -or $_.RelativePath-cin@('metadata.txt','systeminfo.txt'))})
    foreach($row in $transfer){[void]$allowed.Add($row.RelativePath)}
    $root=$Job.RemotePath
    $fileFilter={param($path)if($path-cne$root){throw 'mirror root mismatch'};& $files $path|Where-Object {$allowed.Contains($_)}}.GetNewClosure()
    $dirFilter={param($path)if($path-cne$root){throw 'mirror root mismatch'}; & $dirs $path|Where-Object {-not(Is-LocalOnlyRelativePath $_)}}.GetNewClosure()
    Set-Item Function:local:Get-RemoteFiles -Value $fileFilter
    Set-Item Function:local:Get-RemoteDirs -Value $dirFilter
    # The old fast path pushes a directory. Intercept it rather than weakening Mirror-SystemFolder.
    $pushFilter={
        param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
        if($Args.Count-ge6 -and $Args[2]-ceq'push'){
            $inputPath=$Args[4];$targetPath=$Args[5]
            if(Test-Path -LiteralPath $inputPath -PathType Container){
                if([IO.Path]::GetFullPath($inputPath).TrimEnd('\')-cne[IO.Path]::GetFullPath($Job.LocalPath).TrimEnd('\')){throw 'mirror push scope mismatch'}
                foreach($row in $transfer){
                    $destination=$root+'/'+$row.RelativePath
                    $r=Send-ClassifiedManagedFile $row $destination $Plan.Session $adb
                    if($r.Code-ne0){return $r}
                }
                return [pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}
            }
            $relative=$inputPath.Substring($Job.LocalPath.Length).TrimStart('\','/').Replace('\','/')
            if(-not$allowed.Contains($relative)){return [pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}}
            $row=@($transfer|Where-Object RelativePath -CEQ $relative)[0]
            return (Send-ClassifiedManagedFile $row ($root+'/'+$relative) $Plan.Session $adb)
        }
        & $adb @Args
    }.GetNewClosure()
    Set-Item Function:local:Invoke-Adb -Value $pushFilter
    Mirror-SystemFolder $Job.LocalPath $Job.RemotePath $Label
}

function Send-ClassifiedManagedFile($Row,[string]$Remote,[string]$Session,[scriptblock]$Adb) {
    $unchanged=[pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}
    if((Get-FileHash -LiteralPath $Row.FullName).Hash.ToLowerInvariant()-cne$Row.Sha256){throw 'CLASSIFICATION BLOCK: managed source changed before push'}
    $current=Read-ClassificationRom $Remote $Session
    if($current){
        if($current.Sha256-cne$Row.Sha256){throw 'CLASSIFICATION BLOCK: concurrent MANAGED_CONFLICT before push'}
        return $unchanged
    }
    Ensure-RemoteDir $Remote.Substring(0,$Remote.LastIndexOf('/'))
    $r=& $Adb -s $Serial push --sync $Row.FullName $Remote
    if($r.Code-ne0){return $r}
    $verify=Read-ClassificationRom $Remote $Session
    if(-not$verify -or $verify.Sha256-cne$Row.Sha256){throw 'CLASSIFICATION BLOCK: managed push SHA mismatch'}
    return $r
}

function Read-ClassificationRom([string]$Path,[string]$Session) {
    Assert-RemotePath $Path
    if(-not$Path.StartsWith('/storage/emulated/0/ROMs/')){throw 'classification ROM root 오류'}
    $parts=$Path.Split('/')
    $checks=New-Object 'Collections.Generic.List[string]'
    for($i=4;$i-lt$parts.Length;$i++){
        $parent=($parts[0..$i]-join'/')
        $checks.Add('[ ! -L '+(Quote-Sh $parent)+' ] || exit 1')
    }
    $q=Quote-Sh $Path
    $command=($checks-join'; ')+'; if [ -f '+$q+' ]; then printf PRESENT; elif [ -e '+$q+' ]; then exit 1; else printf ABSENT; fi'
    $r=Invoke-Adb -s $Serial shell $command
    if($r.Code-ne0 -or $r.StdErr -or $r.StdOut-cnotin@('PRESENT','ABSENT')){throw 'classification ROM 상태/링크 조회 실패'}
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
    if($r.Code-ne0 -or -not[IO.File]::Exists($file)){throw 'classification ROM pull 실패'}
    $pulledHash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if($nativeHash -and $nativeHash-cne$pulledHash){throw 'classification Android/pull SHA 불일치'}
    return [pscustomobject]@{Path=$Path;File=$file;Sha256=$pulledHash;HashMethod=$method}
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

function Prepare-GamelistSystem($Job,[string]$Session,[string[]]$PreservedUnmanagedPaths=@(),[switch]$PreserveNonMasterNodes,[switch]$SnapshotOnly) {
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
    if($PreserveNonMasterNodes){
        $baseKeys=@(Get-EsdeGameEntries $Job.GamelistSource|ForEach-Object Key)
        $PreservedUnmanagedPaths+=@(Get-EsdeGameEntries $local|Where-Object {$_.Class-eq'Managed' -and $baseKeys-cnotcontains$_.Key}|ForEach-Object Key)
    }
    $merged=$null; if(-not$SnapshotOnly){$merged=Get-AndroidBoundGamelist $Job.GamelistSource $local $Job.System $PreservedUnmanagedPaths}
    $output=$null
    if($merged){
        $output=Join-Path $folder 'merged.xml'
        [void](Write-EsdeGamelist $merged $output)
        [void]@(Get-EsdeGameEntries (Read-EsdeGamelist $output))
        Write-Log ('GAMELIST '+$Job.System+': MERGE: created VALIDATION: pass')
    }
    return [pscustomobject]@{System=$Job.System;RemotePath=$Job.RemotePath;RemoteFile=$remote;Present=$present;Output=$output;Pulled=$pulled;Validated=$true;LocalOnlyCount=$entries.Count;SourcePresent=[bool]$Job.GamelistSource;Local=$local;PreservedUnmanagedPaths=$PreservedUnmanagedPaths;ClassificationCommitted=$false}
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
    $classificationContext=New-ClassificationContext $StateDir $SourceRoot $Serial
    $esdeLifecycleStarted = $true
    Invoke-EsdeSync {
        $gamelistSession=Join-Path ([IO.Path]::GetTempPath()) ('ESDE-gamelist-'+[guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $gamelistSession)
        try {
        # ES-DE 종료 후 모든 Android XML을 pull/병합 검증해야 어떤 bucket의 변경도 시작한다.
        $gamelistPlans=@{}
        $classificationPlans=@()
        foreach($system in $selectedSystems){
            $romJob=@($jobs|Where-Object {$_.System-ceq$system -and $_.Bucket.Local-eq'roms'})[0]
            $xmlJob=@($jobs|Where-Object {$_.System-ceq$system -and $_.Bucket.Local-eq'gamelists'})[0]
            $xmlPlan=Prepare-GamelistSystem $xmlJob $gamelistSession -PreserveNonMasterNodes -SnapshotOnly
            $plan=Prepare-ClassificationSystem $romJob $xmlJob $xmlPlan $gamelistSession
            $classificationPlans+=$plan
            $gamelistPlans[$system]=$plan.XmlPlan
        }
        # Flat media ownership와 local-only ROM의 연결은 미확정: 해당 system의 media 전체를 보존.
        $protectedMedia=@($classificationPlans|Where-Object ProtectMedia|ForEach-Object System)
        foreach($sys in $protectedMedia){Write-Log ('MEDIA LOCAL-ONLY PROTECT: '+$sys+' / relocation/flat naming policy unresolved, system media unchanged')}
        $activeMediaJobs=@($mediaJobs|Where-Object {$protectedMedia-cnotcontains$_.System})
        $activeMediaSources=@($mediaSources|Where-Object {$protectedMedia-cnotcontains$_.system})
        $mediaPlan=Prepare-MediaPlan $activeMediaJobs $activeMediaSources $mediaContext
        Invoke-ClassificationMoves $classificationPlans $classificationContext $gamelistSession
        # 적용 후 재수집: 이전 inventory의 extra delete 목록은 절대 재사용하지 않는다.
        foreach($plan in $classificationPlans){Confirm-ClassificationInventory $plan $gamelistSession}
        foreach($plan in $classificationPlans){if(-not$plan.XmlPlan.ClassificationCommitted){Sync-GamelistSystem $plan.XmlPlan;$plan.XmlPlan.ClassificationCommitted=$true}}
        $mediaApplied=$false
        $i = 0
        foreach ($job in $jobs) {
            $i++
            $label = "$($job.Bucket.Name): $($job.System)"
            Write-Status "running" "$label 처리 중..." $i $jobs.Count
            Write-Log "PROCESS $label"
    
            if($job.Bucket.Local-eq'gamelists'){
                if(-not$gamelistPlans[$job.System].ClassificationCommitted){Sync-GamelistSystem $gamelistPlans[$job.System]}
            }
            elseif($job.Bucket.Local-eq'downloaded_media'){
                if(-not$mediaApplied){Invoke-MediaTransaction $mediaPlan $mediaContext;$mediaApplied=$true}
            }
            elseif (Test-Path -LiteralPath $job.LocalPath) {
                Sync-ClassifiedManagedRom $job @($classificationPlans|Where-Object System -CEQ $job.System)[0] $label
            }
            else {
                # The system is selected via ROMs, but this bucket has no corresponding folder in Dropbox.
                # Within the selected-system scope, absence means the Android counterpart should also be absent.
                if ($job.Bucket.Local -eq 'roms') {
                    Write-Log "  SOURCE ROM FOLDER ABSENT -> REMOVE MANAGED CONTENTS; PRESERVE RESERVED"
                    throw 'CLASSIFICATION BLOCK: source ROM folder disappeared'
                }
                else {
                    Write-Log "  SOURCE SYSTEM FOLDER ABSENT -> VALIDATE LISTS AND REMOVE REMOTE SYSTEM FOLDER"
                    [void]@(Get-RemoteFiles $job.RemotePath)
                    [void]@(Get-RemoteDirs $job.RemotePath)
                    Remove-RemoteTree $job.RemotePath
                }
            }
        }
        $script:RomCompletionSummary=Get-RomReviewSummary @($classificationPlans|ForEach-Object Inventory)
        } finally {
            try {
                $incomplete=@();try{[void](New-ClassificationContext $StateDir $SourceRoot $Serial)}catch{$incomplete=@($_)}
                if($incomplete.Count){Write-Log ('CLASSIFICATION STAGING PRESERVED: '+$gamelistSession)}
                else{[IO.Directory]::Delete($gamelistSession,$true); Write-Log 'GAMELIST PC STAGING CLEANUP: pass'}
            }
            catch { Write-Log ('GAMELIST PC STAGING CLEANUP FAILED: '+$_.Exception.Message) }
        }
    }
    Write-Status "done" "동기화 완료" $jobs.Count $jobs.Count $script:RomCompletionSummary
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
