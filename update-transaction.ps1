# App 디렉터리만 교체하는 로컬 트랜잭션. 네트워크/Android 호출은 하지 않는다.
function Get-AppMutexName([string]$AppRoot, [string]$Kind) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($sid + '|' + [IO.Path]::GetFullPath($AppRoot).TrimEnd('\').ToUpperInvariant())))).Replace('-','') }
    finally { $sha.Dispose() }
    return 'Global\ESDESync-' + $hash.Substring(0,32) + '-' + $Kind
}

function Enter-AppMutex([string]$AppRoot, [string]$Kind, [int]$TimeoutMilliseconds = 0) {
    $mutex = New-Object Threading.Mutex($false, (Get-AppMutexName $AppRoot $Kind))
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "다른 프로세스가 작업 중입니다: $Kind" }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-AppMutex($Mutex) {
    if ($Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
}

function Assert-UpdateDiskPath([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $boundary = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)' -or ($full -ine $boundary -and -not $full.StartsWith($boundary+'\',[StringComparison]::OrdinalIgnoreCase))) { throw "업데이트 경로 범위 오류: $Path" }
    $cursor = [IO.Path]::GetPathRoot($full)
    foreach ($part in ($full.Substring($cursor.Length) -split '\\')) {
        if (-not $part) { continue }
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "업데이트 경로 링크 금지: $cursor" }
        }
    }
    return $full
}

function Assert-UpdateSessionPath([string]$SessionPath, [string]$AppRoot) {
    $root = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
    $path = Assert-UpdateDiskPath $SessionPath $root
    if ((Split-Path $path -Parent) -ine (Join-Path $root '.Updates') -or (Split-Path $path -Leaf) -notmatch '^[a-f0-9]{32}$') { throw '업데이트 세션 경로 오류' }
    return $path
}

function Write-UpdateJson([string]$Path, $Value) {
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Value | ConvertTo-Json -Depth 10))
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}

function Read-UpdateJson([string]$Path) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
}

function Write-UpdateLog([string]$SessionPath, [string]$Message) {
    $stream = [IO.File]::Open((Join-Path $SessionPath 'update.log'),[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    $writer = New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)))
    try { $writer.WriteLine(('['+(Get-Date).ToUniversalTime().ToString('o')+'] '+$Message)) } finally { $writer.Dispose() }
}

function Set-UpdateState([string]$SessionPath, $State, [string]$Name) {
    $State.state = $Name; $State.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-UpdateJson (Join-Path $SessionPath 'state.json') $State
    Write-UpdateLog $SessionPath ("STATE: $Name")
}

function Get-PendingUpdate([string]$AppRoot, [string]$ExceptSession = '') {
    $updates = Join-Path $AppRoot '.Updates'
    [void](Assert-UpdateDiskPath $updates $AppRoot)
    if (-not (Test-Path $updates)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $updates -Directory -Force)) {
        if ($dir.FullName -ieq $ExceptSession) { continue }
        [void](Assert-UpdateDiskPath $dir.FullName $AppRoot)
        $path = Join-Path $dir.FullName 'state.json'
        if (Test-Path $path) {
            $state = Read-UpdateJson $path
            if ($state.state -notin @('completed','failed')) { return $dir.FullName }
        }
    }
}

function Get-UpdateProcess([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process -or $process.HasExited) { return $null }
    try { return [pscustomobject]@{pid=$process.Id;startTime=$process.StartTime.ToUniversalTime().ToString('o')} }
    catch [InvalidOperationException] { return $null }
}

function Wait-UpdateGuiExit($State, [int]$TimeoutSeconds) {
    if ($State.guiPid -le 0) { return }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $process = Get-UpdateProcess $State.guiPid
        if (-not $process -or $process.startTime -cne $State.guiStartTime) { return }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw '기존 GUI 종료 확인 시간 초과'
}

function Assert-NoAppProcesses([string]$AppRoot, [switch]$IncludeGui) {
    $paths = @((Join-Path $AppRoot 'App\sync-worker.ps1'))
    if ($IncludeGui) { $paths += Join-Path $AppRoot 'App\ESDE-Sync.ps1' }
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)) {
        if (-not $process.CommandLine) { throw 'PowerShell 프로세스 명령행을 확인할 수 없어 교체를 중단합니다.' }
        foreach ($path in $paths) {
            if ($process.CommandLine -and $process.CommandLine.IndexOf($path,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw '설치 루트의 GUI/sync worker가 아직 실행 중입니다.' }
        }
    }
}

function Get-AppSnapshot([string]$AppPath, [string]$AppRoot) {
    [void](Assert-UpdateDiskPath $AppPath $AppRoot)
    $queue = New-Object 'Collections.Generic.Queue[string]'; $queue.Enqueue($AppPath)
    $records = @()
    while ($queue.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $queue.Dequeue() -Force)) {
            [void](Assert-UpdateDiskPath $item.FullName $AppRoot)
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
            $records += [pscustomobject]@{path=($item.FullName.Substring($AppPath.Length).TrimStart('\') -replace '\\','/');size=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName).Hash}
        }
    }
    return $records
}

function Assert-AppSnapshot([string]$AppPath, $Expected, [string]$AppRoot) {
    if (-not (Test-Path -LiteralPath $AppPath -PathType Container)) { throw 'App 폴더 누락' }
    $actual = @(Get-AppSnapshot $AppPath $AppRoot)
    if ($actual.Count -ne @($Expected).Count) { throw 'App 파일 목록 불일치' }
    foreach ($record in @($Expected)) {
        [void](Assert-PackagePath $record.path)
        $match = @($actual | Where-Object { $_.path -ceq $record.path })
        if ($match.Count -ne 1 -or $match[0].size -ne $record.size -or $match[0].sha256 -ine $record.sha256) { throw "App 파일 검증 실패: $($record.path)" }
    }
}

function Get-InstalledAppVersion([string]$AppPath) {
    if (-not (Test-Path $AppPath)) { return $null }
    $file = Join-Path $AppPath 'version.json'
    if (Test-Path $file) { return (Get-AppVersion $file).version }
    # 최초 v1.4.7 업그레이드 호환. 임의 버전 추측은 하지 않는다.
    $gui = Get-Content -LiteralPath (Join-Path $AppPath 'ESDE-Sync.ps1') -Raw -Encoding UTF8
    if ($gui -match '\$form\.Text = "ES-DE Sync v1\.4\.7"') { return '1.4.7' }
    throw '설치된 이전 버전을 확인할 수 없습니다.'
}

function Test-GuiConfirmationSupport([string]$ScriptPath) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'GUI 구문 오류' }
    return ($ast.ParamBlock -and @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'UpdateSession' }).Count -eq 1)
}

function New-LocalUpdateSession([string]$AppRoot, [string]$PayloadDirectory, $TargetInfo, [int]$GuiPid = 0, [string]$GuiStartTime = '') {
    [void](Assert-VersionContract $TargetInfo)
    [void](Assert-UpdateDiskPath $AppRoot $AppRoot)
    if (Get-PendingUpdate $AppRoot) { throw '미완료 업데이트 세션을 먼저 복구해야 합니다.' }
    $id = [guid]::NewGuid().ToString('N'); $session = Join-Path $AppRoot ('.Updates\'+$id)
    [void](Assert-UpdateSessionPath $session $AppRoot)
    $stage = Join-Path $session 'staged\App'
    New-Item -ItemType Directory -Path $stage,(Join-Path $session 'backup') -Force | Out-Null
    foreach ($path in Get-PackageFiles | Where-Object { $_.StartsWith('App/') }) {
        $name = $path.Substring(4)
        [void](Assert-UpdateDiskPath (Join-Path $PayloadDirectory $name) $PayloadDirectory)
        Copy-Item -LiteralPath (Join-Path $PayloadDirectory $name) -Destination (Join-Path $stage $name)
    }
    if ((Get-AppVersion (Join-Path $stage 'version.json')).version -cne $TargetInfo.version) { throw 'staged 버전 불일치' }
    # 실행기는 현재 승인된 코드에서 복사하며 App 밖에서 계속 실행된다.
    foreach ($name in @('update-worker.ps1','update-common.ps1','update-transaction.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $session $name)
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $state = [pscustomobject]@{schemaVersion=1;sessionId=$id;sourceVersion=(Get-InstalledAppVersion (Join-Path $AppRoot 'App'));targetVersion=$TargetInfo.version;state='verified';guiPid=$GuiPid;guiStartTime=$GuiStartTime;workerPid=0;workerStartTime='';startedAt=$now;updatedAt=$now;originalError=$null;rollbackError=$null;sourceFiles=@();targetFiles=@(Get-AppSnapshot $stage $AppRoot);sourceHadApp=(Test-Path (Join-Path $AppRoot 'App'));newGuiPid=0;newGuiStartTime='';rollbackGuiPid=0;rollbackGuiStartTime=''}
    Write-UpdateJson (Join-Path $session 'state.json') $state
    Write-UpdateLog $session 'STATE: verified'
    return $session
}

function New-PackageUpdateSession([string]$AppRoot, $VerifiedPackage, $CurrentVersion, [int]$GuiPid, [string]$GuiStartTime) {
    [void](Assert-UpdateDiskPath $VerifiedPackage.ZipPath $AppRoot)
    if (-not $VerifiedPackage.Verified -or -not $VerifiedPackage.Sha256 -or
        (Get-FileHash -LiteralPath $VerifiedPackage.ZipPath).Hash -ine $VerifiedPackage.Sha256) { throw '승인된 패키지 SHA-256 불일치' }
    $packageLock = [IO.File]::Open($VerifiedPackage.ZipPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $zip=$null; $session=$null; $scratch=$null
    try {
    if ((Get-FileHash -LiteralPath $VerifiedPackage.ZipPath).Hash -ine $VerifiedPackage.Sha256) { throw '패키지가 검증 후 변경되었습니다.' }
    [void](Test-UpdatePackage $VerifiedPackage.ZipPath $VerifiedPackage.Version $CurrentVersion)
    $scratch = Join-Path $AppRoot ('.Updates\extract-'+[guid]::NewGuid().ToString('N'))
    [void](Assert-UpdateDiskPath $scratch $AppRoot)
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($VerifiedPackage.ZipPath)
    try {
        foreach ($entry in $zip.Entries | Where-Object { $_.FullName.StartsWith('App/') -and -not $_.FullName.EndsWith('/') }) {
            $name = $entry.FullName.Substring(4)
            $target = Join-Path $scratch $name
            [void](Assert-UpdateDiskPath $target $AppRoot)
            $entryStream = $entry.Open(); $output = [IO.File]::Open($target,[IO.FileMode]::CreateNew)
            try { $entryStream.CopyTo($output) } finally { $entryStream.Dispose(); $output.Dispose() }
        }
        $session = New-LocalUpdateSession $AppRoot $scratch (Get-AppVersion (Join-Path $scratch 'version.json')) $GuiPid $GuiStartTime
        Copy-Item -LiteralPath $VerifiedPackage.ZipPath -Destination (Join-Path $session 'package.zip')
        [IO.File]::WriteAllText((Join-Path $session 'package.sha256'), ($VerifiedPackage.Sha256+'  package.zip'))
        return $session
    }
    finally { if ($zip) { $zip.Dispose() }; if ($scratch -and (Test-Path $scratch)) { [void](Assert-UpdateDiskPath $scratch $AppRoot); Remove-Item -LiteralPath $scratch -Recurse -Force } }
    }
    catch {
        if ($session) {
            $state=Read-UpdateJson (Join-Path $session 'state.json')
            $state.originalError=$_.Exception.Message
            Set-UpdateState $session $state 'failed'
        }
        throw
    }
    finally { $packageLock.Dispose() }
}

function Move-UpdateDirectory([string]$Source, [string]$Destination, [string]$AppRoot) {
    [void](Assert-UpdateDiskPath $Source $AppRoot); [void](Assert-UpdateDiskPath $Destination $AppRoot)
    if (Test-Path -LiteralPath $Destination) { throw '이동 대상이 이미 존재합니다.' }
    [IO.Directory]::Move($Source,$Destination)
}

function Start-UpdateGui([string]$AppRoot, [string]$SessionPath, [string]$Version, [switch]$Rollback) {
    $script = Join-Path $AppRoot 'App\ESDE-Sync.ps1'
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'))
    if (Test-GuiConfirmationSupport $script) {
        $arguments += @('-InstallRoot',('"'+$AppRoot+'"'),'-UpdateSession',('"'+$SessionPath+'"'),'-UpdateSessionId',(Split-Path $SessionPath -Leaf),'-ConfirmationFile',$(if ($Rollback) { 'rollback-confirmation.json' } else { 'startup-confirmation.json' }))
    }
    elseif (-not $Rollback) { throw '새 GUI에 시작 확인 기능이 없습니다.' }
    elseif ([IO.Path]::GetFullPath($AppRoot).TrimEnd('\') -ine (Join-Path $env:LOCALAPPDATA 'ESDE-Sync')) {
        throw '이전 GUI는 사용자 지정 설치 루트의 재실행을 지원하지 않습니다. 원본 App은 복원되어 있습니다.'
    }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru
    return [pscustomobject]@{pid=$process.Id;startTime=$process.StartTime.ToUniversalTime().ToString('o');confirmation=(Test-GuiConfirmationSupport $script)}
}

function Stop-UpdateGui($State) {
    if ($State.newGuiPid -le 0) { return }
    $process = Get-UpdateProcess $State.newGuiPid
    if (-not $process) { return }
    if ($process.startTime -cne $State.newGuiStartTime) { throw '새 GUI PID가 다른 프로세스로 재사용되었습니다.' }
    Stop-Process -Id $State.newGuiPid -ErrorAction Stop
    $p = Get-Process -Id $State.newGuiPid -ErrorAction SilentlyContinue
    if ($p -and -not $p.WaitForExit(10000)) { throw '새 GUI 종료 실패' }
}

function Wait-GuiConfirmation([string]$SessionPath, $Process, [string]$Version, [string]$FileName, [int]$TimeoutSeconds = 30) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $alive = Get-UpdateProcess $Process.pid
        if (-not $alive -or $alive.startTime -cne $Process.startTime) { throw '새 GUI 프로세스가 종료되거나 PID가 변경되었습니다.' }
        $path = Join-Path $SessionPath $FileName
        if (Test-Path $path) {
            $confirmation = Read-UpdateJson $path
            if ($confirmation.sessionId -cne (Split-Path $SessionPath -Leaf) -or $confirmation.version -cne $Version -or
                $confirmation.pid -ne $Process.pid -or $confirmation.processStartTime -cne $Process.startTime -or
                -not $confirmation.confirmedAt) { throw 'GUI 시작 확인 정보 불일치' }
            return
        }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'GUI 시작 확인 시간 초과'
}

function Write-GuiConfirmation([string]$SessionPath, [string]$AppRoot, [string]$SessionId, [string]$Version, [string]$FileName) {
    $session = Assert-UpdateSessionPath $SessionPath $AppRoot
    if ((Split-Path $session -Leaf) -cne $SessionId -or $FileName -notin @('startup-confirmation.json','rollback-confirmation.json')) { throw 'GUI 확인 세션 계약 오류' }
    $process = Get-UpdateProcess $PID
    Write-UpdateJson (Join-Path $session $FileName) ([pscustomobject]@{sessionId=$SessionId;version=$Version;pid=$PID;processStartTime=$process.startTime;confirmedAt=(Get-Date).ToUniversalTime().ToString('o')})
}

function Invoke-UpdateRollback([string]$AppRoot, [string]$SessionPath, $State, [int]$TimeoutSeconds) {
    Set-UpdateState $SessionPath $State 'rolling_back'
    Stop-UpdateGui $State
    Assert-NoAppProcesses $AppRoot -IncludeGui
    $app = Join-Path $AppRoot 'App'; $backup = Join-Path $SessionPath 'backup\App'
    if (Test-Path $backup) {
        Assert-AppSnapshot $backup $State.sourceFiles $AppRoot
        if (Test-Path $app) { Move-UpdateDirectory $app (Join-Path $SessionPath ('failed-App-'+[guid]::NewGuid().ToString('N'))) $AppRoot }
        # 백업은 롤백 재실행 실패에도 남긴다. 검증한 복원 사본을 디렉터리 이동한다.
        $restore = Join-Path $SessionPath ('restore-'+[guid]::NewGuid().ToString('N'))
        [void](Assert-UpdateDiskPath $restore $AppRoot)
        New-Item -ItemType Directory -Path $restore | Out-Null
        $restoreApp = Join-Path $restore 'App'
        Copy-Item -LiteralPath $backup -Destination $restoreApp -Recurse
        Assert-AppSnapshot $restoreApp $State.sourceFiles $AppRoot
        Move-UpdateDirectory $restoreApp $app $AppRoot
    }
    elseif ($State.sourceHadApp) { Assert-AppSnapshot $app $State.sourceFiles $AppRoot }
    elseif (Test-Path $app) { Move-UpdateDirectory $app (Join-Path $SessionPath ('failed-App-'+[guid]::NewGuid().ToString('N'))) $AppRoot }
    if ($State.sourceHadApp) {
        Assert-AppSnapshot $app $State.sourceFiles $AppRoot
        $old = Start-UpdateGui $AppRoot $SessionPath $State.sourceVersion -Rollback
        $State.rollbackGuiPid=$old.pid; $State.rollbackGuiStartTime=$old.startTime
        if ($old.confirmation) { Wait-GuiConfirmation $SessionPath $old $State.sourceVersion 'rollback-confirmation.json' $TimeoutSeconds }
        else {
            Start-Sleep -Milliseconds 250
            if (-not (Get-UpdateProcess $old.pid)) { throw '이전 GUI 재실행 실패' }
            Write-UpdateLog $SessionPath '이전 v1.4.7/1차 GUI: 원본 파일 복원 및 실행 프로세스 확인(시작 확인 기능 없음)'
        }
    }
    Set-UpdateState $SessionPath $State 'failed'
}

function Invoke-UpdateTransaction([string]$AppRoot, [string]$SessionPath, [int]$TimeoutSeconds = 30, [int]$OperationTimeoutMilliseconds = 0) {
    $root = Assert-UpdateDiskPath $AppRoot $AppRoot
    $session = Assert-UpdateSessionPath $SessionPath $root
    $sessionLock = Enter-AppMutex $root ('session-'+(Split-Path $session -Leaf))
    $operation = $null; $state = $null; $mutated = $false; $rollbackAttempted = $false; $sourceReady = $false
    try {
        $operation = Enter-AppMutex $root 'operation' $OperationTimeoutMilliseconds
        if (Get-PendingUpdate $root $session) { throw '다른 업데이트 세션 복구가 필요합니다.' }
        $state = Read-UpdateJson (Join-Path $session 'state.json')
        if ($state.schemaVersion -ne 1 -or $state.sessionId -cne (Split-Path $session -Leaf) -or $state.state -notin @('verified','waiting_for_gui_exit','backing_up','replacing','launching','completed','rolling_back','failed','rollback_failed')) { throw '업데이트 상태 계약 오류' }
        $app=Join-Path $root 'App'; $backup=Join-Path $session 'backup\App'; $stage=Join-Path $session 'staged\App'
        if ($state.state -in @('completed','failed')) { return $state }
        $process = Get-UpdateProcess $PID; $state.workerPid=$PID; $state.workerStartTime=$process.startTime
        if ($state.state -in @('backing_up','replacing','launching','rolling_back','rollback_failed')) {
            $mutated=$true
            if (-not $state.originalError) { $state.originalError='중단된 업데이트를 재실행하여 롤백합니다.' }
            $rollbackAttempted=$true
            Invoke-UpdateRollback $root $session $state $TimeoutSeconds
            return $state
        }
        $required = @(Get-PackageFiles | Where-Object { $_.StartsWith('App/') } | ForEach-Object { $_.Substring(4) })
        if (@(Compare-Object $required @($state.targetFiles | ForEach-Object path) -CaseSensitive).Count) { throw 'staged 필수 파일 계약 불일치' }
        Assert-AppSnapshot $stage $state.targetFiles $root
        if ((Get-AppVersion (Join-Path $stage 'version.json')).version -cne $state.targetVersion) { throw 'staged 대상 버전 불일치' }
        Set-UpdateState $session $state 'waiting_for_gui_exit'
        Write-UpdateJson (Join-Path $session 'worker-ready.json') @{sessionId=$state.sessionId;workerPid=$PID;workerStartTime=$state.workerStartTime}
        Wait-UpdateGuiExit $state $TimeoutSeconds
        Assert-NoAppProcesses $root -IncludeGui
        $state.sourceFiles = $(if ($state.sourceHadApp) { @(Get-AppSnapshot $app $root) } else { @() })
        if ((Get-InstalledAppVersion $app) -cne $state.sourceVersion) { throw '원본 App 버전이 변경되었습니다.' }
        $sourceReady=$true
        Set-UpdateState $session $state 'backing_up'
        if ($state.sourceHadApp) { Move-UpdateDirectory $app $backup $root; $mutated=$true }
        Set-UpdateState $session $state 'replacing'
        Move-UpdateDirectory $stage $app $root; $mutated=$true
        Assert-AppSnapshot $app $state.targetFiles $root
        if ((Get-AppVersion (Join-Path $app 'version.json')).version -cne $state.targetVersion) { throw '교체 후 대상 버전 불일치' }
        Set-UpdateState $session $state 'launching'
        $new = Start-UpdateGui $root $session $state.targetVersion
        $state.newGuiPid=$new.pid; $state.newGuiStartTime=$new.startTime
        Write-UpdateJson (Join-Path $session 'state.json') $state
        Wait-GuiConfirmation $session $new $state.targetVersion 'startup-confirmation.json' $TimeoutSeconds
        Set-UpdateState $session $state 'completed'
        return $state
    }
    catch {
        $original = $_
        if (-not $state) { throw }
        if (-not $state.originalError) { $state.originalError=$original.Exception.Message }
        try { Write-UpdateLog $session ('ORIGINAL ERROR: '+$state.originalError) } catch {}
        if ($mutated -or (Test-Path (Join-Path $session 'backup\App')) -or ($sourceReady -and $state.sourceHadApp)) {
            try {
                if ($rollbackAttempted) { throw $original }
                $rollbackAttempted=$true
                Invoke-UpdateRollback $root $session $state $TimeoutSeconds
            }
            catch {
                $state.rollbackError=$_.Exception.Message
                try { Set-UpdateState $session $state 'rollback_failed' } catch {}
                try { Write-UpdateLog $session ('ROLLBACK ERROR: '+$state.rollbackError) } catch {}
            }
        }
        else { Set-UpdateState $session $state 'failed' }
        return $state
    }
    finally { Exit-AppMutex $operation; Exit-AppMutex $sessionLock }
}
