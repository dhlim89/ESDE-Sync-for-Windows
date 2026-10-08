param([string]$InstallRoot, [string]$UpdateSession, [string]$UpdateSessionId,
    [ValidateSet('startup-confirmation.json','rollback-confirmation.json')][string]$ConfirmationFile = 'startup-confirmation.json')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'update-common.ps1')
. (Join-Path $PSScriptRoot 'update-transaction.ps1')
$AppVersion = Get-AppVersion (Join-Path $PSScriptRoot 'version.json')
$UpdateCommonPath = Join-Path $PSScriptRoot 'update-common.ps1'
$VersionFile = Join-Path $PSScriptRoot 'version.json'

$AppRoot = Join-Path $env:LOCALAPPDATA "ESDE-Sync"
if ($InstallRoot) {
    $AppRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if ($PSScriptRoot -ine (Join-Path $AppRoot 'App')) { throw 'GUI 설치 루트 계약 오류' }
}
$GuiMutex = $null
try { $GuiMutex = Enter-AppMutex $AppRoot 'gui' }
catch { [void][System.Windows.Forms.MessageBox]::Show('ES-DE Sync GUI가 이미 실행 중입니다.'); exit 1 }
try {
$InstallDir = Join-Path $AppRoot "App"
$ConfigFile = Join-Path $AppRoot "config.json"
$StateDir = Join-Path $AppRoot "State"
$StatusFile = Join-Path $StateDir "status.json"
$LogFile = Join-Path $StateDir "sync.log"
$BundledAdb = Join-Path $AppRoot "platform-tools\adb.exe"
$Worker = Join-Path $InstallDir "sync-worker.ps1"
$IconFile = Join-Path $InstallDir "esde-sync-icon-v141.ico"

New-Item -ItemType Directory -Force -Path $AppRoot, $StateDir | Out-Null

function Get-AdbPath {
    if (Test-Path $BundledAdb) { return $BundledAdb }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Load-Config {
    if (Test-Path $ConfigFile) {
        try { return (Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{ SourceRoot = "" }
}

function Save-Config([string]$SourceRoot) {
    @{ SourceRoot = $SourceRoot } | ConvertTo-Json | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
}

function Find-DefaultSource {
    $candidates = @(
        (Join-Path $env:USERPROFILE "Dropbox\ES-DE Sync"),
        (Join-Path $env:USERPROFILE "Dropbox\패밀리룸\ES-DE Sync"),
        (Join-Path $env:USERPROFILE "Dropbox\Family Room\ES-DE Sync")
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "roms")) { return $c }
    }
    return ""
}

function Get-Devices([string]$Adb) {
    $log={param($message) Write-AdbLifecycleLog (Join-Path $StateDir 'adb-lifecycle.log') $message}
    $start=Invoke-AppAdb $Adb $AppRoot @('start-server') 10000 $log
    if ($start.Code -ne 0) { throw 'ADB start-server 실패' }
    $devices=Invoke-AppAdb $Adb $AppRoot @('devices') 10000 $log
    if ($devices.Code -ne 0) { throw 'ADB devices 실패' }
    $result = @()
    foreach ($line in ($devices.Out -split "`n" | Select-Object -Skip 1)) {
        if (-not $line.Trim()) { continue }
        $parts = $line -split "\s+"
        if ($parts.Count -lt 2) { continue }
        $serial = $parts[0]
        $state = $parts[1]
        $model = $serial
        if ($state -eq "device") {
            $m = (Invoke-AppAdb $Adb $AppRoot @('-s',$serial,'shell','getprop','ro.product.model') 10000 $log).Out.Trim()
            if ($m) { $model = $m }
        }
        elseif ($state -eq "unauthorized") {
            $model = "USB 디버깅 승인 필요"
        }
        $result += [pscustomobject]@{
            Serial = $serial
            State = $state
            Model = $model
            Display = "$model  [$serial]"
        }
    }
    return $result
}

function Read-SharedTextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }

    $fs = $null
    $sr = $null
    try {
        $fs = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        return $sr.ReadToEnd()
    }
    finally {
        if ($sr) { $sr.Dispose() }
        elseif ($fs) { $fs.Dispose() }
    }
}


function Stop-AdbServer {
    $shutdownAdb=$script:Adb
    if (-not $shutdownAdb) { $shutdownAdb=$BundledAdb }
    $log={param($message) Write-AdbLifecycleLog (Join-Path $StateDir 'adb-lifecycle.log') $message}
    try { Stop-AppAdbServer $shutdownAdb $AppRoot 10000 $log }
    catch { & $log ('ADB 종료 실패: '+$_.Exception.Message) }
}
function Get-EsdeGuiLayout {
    # 96 DPI 기준 client 좌표. Dpi autoscaling은 모든 control에 동일하게 적용한다.
    return @{
        ClientWidth=740;ClientHeight=670
        Bounds=@{
            title=@(24,20,690,36);desc=@(27,60,690,26)
            sourceLabel=@(27,92,690,22);sourceBox=@(30,116,580,28);browseBtn=@(620,114,100,32)
            deviceLabel=@(27,154,690,22);deviceCombo=@(30,178,580,30);refreshBtn=@(620,176,100,32)
            info=@(30,220,690,84)
            updateLabel=@(30,316,565,32);updateBtn=@(610,316,110,32);installUpdateBtn=@(610,316,110,32)
            warn=@(30,358,690,40);syncBtn=@(30,410,690,44)
            progress=@(30,468,690,22);statusLabel=@(30,500,690,26);logBox=@(30,538,690,110)
        }
    }
}

function Set-EsdeGuiLayout($Form,[hashtable]$Controls) {
    $layout=Get-EsdeGuiLayout
    $Form.AutoScaleDimensions=New-Object System.Drawing.SizeF(96,96)
    $Form.AutoScaleMode=[System.Windows.Forms.AutoScaleMode]::Dpi
    $Form.ClientSize=New-Object System.Drawing.Size($layout.ClientWidth,$layout.ClientHeight)
    foreach($name in $layout.Bounds.Keys){
        if(-not$Controls.ContainsKey($name)){throw ('GUI layout control 누락: '+$name)}
        $control=$Controls[$name];$box=$layout.Bounds[$name]
        if($control-is[System.Windows.Forms.Label]){$control.AutoSize=$false}
        $control.Bounds=New-Object System.Drawing.Rectangle($box[0],$box[1],$box[2],$box[3])
    }
    $Form.MinimumSize=$Form.Size
}

$form = New-Object System.Windows.Forms.Form
$form.Text = ("ES-DE Sync v" + $AppVersion.version)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
if (Test-Path $IconFile) {
    try { $form.Icon = New-Object System.Drawing.Icon($IconFile) } catch {}
}

$title = New-Object System.Windows.Forms.Label
$title.Text = ("ES-DE Sync v" + $AppVersion.version)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$form.Controls.Add($title)

$desc = New-Object System.Windows.Forms.Label
$desc.Text = "Dropbox의 ES-DE Sync를 USB로 연결한 Android 기기에 안전하게 미러링합니다."
$desc.AutoSize = $true
$form.Controls.Add($desc)

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = "원본 ES-DE Sync 폴더"
$sourceLabel.AutoSize = $true
$form.Controls.Add($sourceLabel)

$sourceBox = New-Object System.Windows.Forms.TextBox
$form.Controls.Add($sourceBox)

$browseBtn = New-Object System.Windows.Forms.Button
$browseBtn.Text = "찾아보기"
$form.Controls.Add($browseBtn)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = "Android 기기"
$deviceLabel.AutoSize = $true
$form.Controls.Add($deviceLabel)

$deviceCombo = New-Object System.Windows.Forms.ComboBox
$deviceCombo.DropDownStyle = "DropDownList"
$form.Controls.Add($deviceCombo)

$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = "새로고침"
$form.Controls.Add($refreshBtn)

$info = New-Object System.Windows.Forms.Label
$info.Text = "대상 경로:`r`nROM: /storage/emulated/0/ROMs`r`ngamelist: /storage/emulated/0/ES-DE/gamelists`r`nmedia: /storage/emulated/0/ES-DE/downloaded_media"
$info.AutoSize = $true
$form.Controls.Add($info)

$updateLabel = New-Object System.Windows.Forms.Label
$updateLabel.Text = '업데이트 확인 대기'
$form.Controls.Add($updateLabel)
$updateBtn = New-Object System.Windows.Forms.Button
$updateBtn.Text = '업데이트'
$updateBtn.Enabled = $false
$form.Controls.Add($updateBtn)
$installUpdateBtn = New-Object System.Windows.Forms.Button
$installUpdateBtn.Text = '설치'
$installUpdateBtn.Visible = $false
$installUpdateBtn.Enabled = $false
$form.Controls.Add($installUpdateBtn)

$warn = New-Object System.Windows.Forms.Label
$warn.Text = "선택된 시스템은 완전 미러링하되, 각 시스템의 _TEST / _UNREGISTERED 폴더는 항상 보존·제외합니다."
$warn.AutoSize = $true
$warn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($warn)

$syncBtn = New-Object System.Windows.Forms.Button
$syncBtn.Text = "Android 동기화 시작"
$form.Controls.Add($syncBtn)

$progress = New-Object System.Windows.Forms.ProgressBar
$form.Controls.Add($progress)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "대기 중"
$statusLabel.AutoSize = $true
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$form.Controls.Add($logBox)
Set-EsdeGuiLayout $form @{
    title=$title;desc=$desc;sourceLabel=$sourceLabel;sourceBox=$sourceBox;browseBtn=$browseBtn
    deviceLabel=$deviceLabel;deviceCombo=$deviceCombo;refreshBtn=$refreshBtn;info=$info
    updateLabel=$updateLabel;updateBtn=$updateBtn;installUpdateBtn=$installUpdateBtn;warn=$warn
    syncBtn=$syncBtn;progress=$progress;statusLabel=$statusLabel;logBox=$logBox
}

$script:Adb = Get-AdbPath
$script:Devices = @()
$script:WorkerProcess = $null
$script:UpdateTask = $null
$script:UpdateCandidate = $null
$script:UpdateBusy = $false
$script:VerifiedPackage = $null
$script:UpdateInstalling = $false
$script:AllowInstallClose = $false
$script:InstallProcess = $null
$script:InstallSession = $null
$script:StartupPending = [bool]$UpdateSession -or [bool](Get-PendingUpdate $AppRoot)
if ($script:StartupPending) { $syncBtn.Enabled = $false; $updateLabel.Text = '업데이트 완료 또는 복구 확인 중...' }

function Start-UpdateTask([string]$Kind, $Candidate) {
    if ($script:UpdateTask) { throw '업데이트 작업이 이미 실행 중입니다.' }
    if ($script:UpdateInstalling -or ($Kind -eq 'download' -and $script:StartupPending)) { throw '업데이트 설치 또는 복구가 진행 중입니다.' }
    if ($Kind -eq 'download' -and $script:WorkerProcess -and -not $script:WorkerProcess.HasExited) { throw '동기화 중에는 업데이트 다운로드를 시작할 수 없습니다.' }
    $ps = [PowerShell]::Create()
    $jobScript = {
        param($CommonPath, $VersionPath, $Kind, $Candidate, $DownloadRoot)
        $ErrorActionPreference = 'Stop'
        . $CommonPath
        $current = Get-AppVersion $VersionPath
        if ($Kind -eq 'check') { Get-LatestStableRelease $current }
        else { Save-VerifiedUpdate $Candidate $current $DownloadRoot }
    }
    [void]$ps.AddScript($jobScript.ToString()).AddArgument($UpdateCommonPath).AddArgument($VersionFile).AddArgument($Kind).AddArgument($Candidate).AddArgument((Join-Path $AppRoot '.Updates'))
    try {
        $handle = $ps.BeginInvoke()
        $script:UpdateTask = [pscustomobject]@{PowerShell=$ps;Handle=$handle;Kind=$Kind}
        $script:UpdateBusy = $Kind -eq 'download'
        $updateBtn.Enabled = $false
        if ($script:UpdateBusy) { $syncBtn.Enabled = $false; $updateLabel.Text = '업데이트 다운로드·검증 중...' }
        else { $updateLabel.Text = '최신 Release 확인 중...' }
    }
    catch { $ps.Dispose(); throw }
}

$updateBtn.Add_Click({
    try {
        if (-not $script:UpdateCandidate) { return }
        if ($script:WorkerProcess -and -not $script:WorkerProcess.HasExited) { throw '동기화 중에는 업데이트 다운로드를 시작할 수 없습니다.' }
        $answer = [System.Windows.Forms.MessageBox]::Show(('v' + $script:UpdateCandidate.Version + ' 패키지를 다운로드하고 검증할까요? 이번 버전에서는 설치하지 않습니다.'), '업데이트 확인', [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-UpdateTask 'download' $script:UpdateCandidate }
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '업데이트 오류') }
})

$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 300
$updateTimer.Add_Tick({
    if (-not $script:UpdateTask -or -not $script:UpdateTask.Handle.IsCompleted) { return }
    $task = $script:UpdateTask
    try {
        $output = @($task.PowerShell.EndInvoke($task.Handle))
        if ($task.PowerShell.HadErrors) { throw ($task.PowerShell.Streams.Error | Out-String) }
        if ($task.Kind -eq 'check') {
            if ($output.Count -gt 0 -and $output[-1].Available) {
                $script:UpdateCandidate = $output[-1]
                $updateLabel.Text = 'v' + $script:UpdateCandidate.Version + ' 업데이트 가능 (다운로드·검증만)'
            }
            else { $updateLabel.Text = '현재 업데이트 가능한 stable Release가 없습니다.' }
        }
        else {
            if ($output.Count -ne 1 -or -not $output[0].Verified) { throw '패키지 검증 결과 오류' }
            $script:VerifiedPackage = $output[0]
            $updateLabel.Text = '업데이트 패키지 검증 완료. 설치 버튼으로 적용할 수 있습니다.'
            $updateBtn.Visible = $false
            $installUpdateBtn.Visible = $true
            $installUpdateBtn.Enabled = $true
        }
    }
    catch { $updateLabel.Text = '업데이트 확인/검증 실패: ' + $_.Exception.Message }
    finally {
        $task.PowerShell.Dispose()
        $script:UpdateTask = $null
        $script:UpdateBusy = $false
        $syncBtn.Enabled = -not $script:StartupPending -and -not $script:UpdateInstalling -and -not ($script:WorkerProcess -and -not $script:WorkerProcess.HasExited)
        $updateBtn.Enabled = [bool]$script:UpdateCandidate -and -not $script:StartupPending -and -not $script:UpdateInstalling
    }
})
$updateTimer.Start()

$installUpdateBtn.Add_Click({
    $operation = $null
    try {
        if ($script:UpdateTask -or $script:UpdateInstalling -or $script:StartupPending -or
            ($script:WorkerProcess -and -not $script:WorkerProcess.HasExited)) { throw '다른 작업이 실행 중입니다.' }
        if (-not $script:VerifiedPackage) { throw '검증된 업데이트 패키지가 없습니다.' }
        $answer = [System.Windows.Forms.MessageBox]::Show('업데이트를 설치할까요? 현재 창은 종료되고 새 버전이 실행됩니다. 실패하면 이전 App을 복원합니다.', '업데이트 설치', [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:InstallSession=$null; $script:InstallProcess=$null
        $operation = Enter-AppMutex $AppRoot 'operation'
        Assert-NoAppProcesses $AppRoot
        Stop-AppAdbServer $script:Adb $AppRoot 10000 {param($message) Write-AdbLifecycleLog (Join-Path $StateDir 'adb-lifecycle.log') $message}
        $identity = Get-UpdateProcess $PID
        $script:InstallSession = New-PackageUpdateSession $AppRoot $script:VerifiedPackage $AppVersion $PID $identity.startTime
        $script:UpdateInstalling = $true; $syncBtn.Enabled=$false; $installUpdateBtn.Enabled=$false
        $runner = Join-Path $script:InstallSession 'update-worker.ps1'
        $args = '-NoProfile -ExecutionPolicy Bypass -File "'+$runner+'" -AppRoot "'+$AppRoot+'" -SessionPath "'+$script:InstallSession+'"'
        $script:InstallProcess = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
        $updateLabel.Text='업데이트 worker 준비 및 안전한 종료 대기...'
    }
    catch {
        $failure=$_.Exception.Message
        if ($script:InstallSession -and -not $script:InstallProcess) {
            $state = Read-UpdateJson (Join-Path $script:InstallSession 'state.json')
            $state.originalError=$failure
            Set-UpdateState $script:InstallSession $state 'failed'
        }
        $script:UpdateInstalling=$false
        $script:StartupPending=[bool](Get-PendingUpdate $AppRoot)
        $syncBtn.Enabled=-not $script:StartupPending -and -not ($script:WorkerProcess -and -not $script:WorkerProcess.HasExited)
        $installUpdateBtn.Enabled=-not $script:StartupPending
        [void][System.Windows.Forms.MessageBox]::Show($failure, '설치 준비 실패')
    }
    finally { Exit-AppMutex $operation }
})

$installTimer = New-Object System.Windows.Forms.Timer
$installTimer.Interval=200
$installTimer.Add_Tick({
    if ($script:UpdateInstalling -and $script:InstallProcess) {
        $ready = Join-Path $script:InstallSession 'worker-ready.json'
        if (Test-Path $ready) {
            try {
                $value=Read-UpdateJson $ready
                $alive=Get-UpdateProcess $script:InstallProcess.Id
                if ($alive -and $value.sessionId -ceq (Split-Path $script:InstallSession -Leaf) -and
                    $value.workerPid -eq $alive.pid -and $value.workerStartTime -ceq $alive.startTime) {
                    $script:AllowInstallClose=$true
                    $form.Close()
                    return
                }
            } catch { $updateLabel.Text='worker 시작 확인 대기 중...' }
        }
        if ($script:InstallProcess.HasExited) {
            $script:UpdateInstalling=$false
            $script:StartupPending=[bool](Get-PendingUpdate $AppRoot)
            $syncBtn.Enabled=-not $script:StartupPending
            $installUpdateBtn.Enabled=-not $script:StartupPending
            $updateLabel.Text='업데이트 worker 준비 실패. 세션 로그를 확인해 주세요.'
        }
    }
    if ($script:StartupPending -and -not (Get-PendingUpdate $AppRoot)) {
        $script:StartupPending=$false
        $syncBtn.Enabled=-not $script:UpdateBusy
        $updateBtn.Enabled=[bool]$script:UpdateCandidate
    }
})
$installTimer.Start()

function Refresh-Devices {
    if (-not $script:Adb) {
        [System.Windows.Forms.MessageBox]::Show("ADB를 찾을 수 없습니다. install.cmd를 다시 실행해 주세요.") | Out-Null
        return
    }
    $deviceCombo.Items.Clear()
    $script:Devices = @(Get-Devices $script:Adb)
    foreach ($d in $script:Devices) { [void]$deviceCombo.Items.Add($d.Display) }
    if ($deviceCombo.Items.Count -gt 0) { $deviceCombo.SelectedIndex = 0 }
}

$browseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Dropbox의 ES-DE Sync 폴더를 선택하세요."
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sourceBox.Text = $dlg.SelectedPath
        Save-Config $sourceBox.Text
    }
})

$refreshBtn.Add_Click({ Refresh-Devices })

$syncBtn.Add_Click({
    try {
        if ($script:UpdateBusy -or $script:UpdateInstalling -or $script:StartupPending) { throw '업데이트 또는 복구 작업 중에는 동기화를 시작할 수 없습니다.' }
        $source = $sourceBox.Text.Trim()
        foreach ($name in @("roms","gamelists","downloaded_media")) {
            if (-not (Test-Path (Join-Path $source $name))) {
                throw "원본 ES-DE Sync 폴더 구조가 올바르지 않습니다: $name 없음"
            }
        }
        if ($deviceCombo.SelectedIndex -lt 0) { throw "Android 기기를 선택하세요." }
        $dev = $script:Devices[$deviceCombo.SelectedIndex]
        if ($dev.State -ne "device") { throw "USB 디버깅 승인이 필요합니다." }

        Save-Config $source
        Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
        Remove-Item $LogFile -Force -ErrorAction SilentlyContinue

        $args = @(
            "-NoProfile","-ExecutionPolicy","Bypass",
            "-File","`"$Worker`"",
            "-SourceRoot","`"$source`"",
            "-Serial","`"$($dev.Serial)`"",
            "-AdbPath","`"$script:Adb`"",
            "-StateDir","`"$StateDir`"",
            "-AppRoot","`"$AppRoot`""
        ) -join " "

        $script:WorkerProcess = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
        $syncBtn.Enabled = $false
        $progress.Value = 0
        $statusLabel.Text = "동기화 중..."
        $logBox.Clear()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "오류") | Out-Null
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 600
$timer.Add_Tick({
    if ($script:WorkerProcess -eq $null) { return }

    if (Test-Path $StatusFile) {
        try {
            $st = Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $statusLabel.Text = $st.message
            $p = [int]$st.percent
            if ($p -lt 0) { $p = 0 }
            if ($p -gt 100) { $p = 100 }
            $progress.Value = $p
        } catch {}
    }

    if (Test-Path $LogFile) {
        try {
            $text = Read-SharedTextFile $LogFile
            $logBox.Text = $text
            $logBox.SelectionStart = $logBox.Text.Length
            $logBox.ScrollToCaret()
        } catch {}
    }

    if ($script:WorkerProcess.HasExited) {
        $code = $script:WorkerProcess.ExitCode
        $script:WorkerProcess = $null
        $syncBtn.Enabled = -not $script:UpdateBusy -and -not $script:UpdateInstalling -and -not $script:StartupPending
        if ($code -eq 0) {
            $progress.Value = 100
            $statusLabel.Text = "동기화 완료"
            [System.Windows.Forms.MessageBox]::Show("Android 동기화가 완료되었습니다.") | Out-Null
        } else {
            $statusLabel.Text = "동기화 실패"
            [System.Windows.Forms.MessageBox]::Show("동기화에 실패했습니다. 로그를 확인하세요.") | Out-Null
        }
    }
})
$timer.Start()

$config = Load-Config
if ($config.SourceRoot -and (Test-Path $config.SourceRoot)) {
    $sourceBox.Text = $config.SourceRoot
} else {
    $found = Find-DefaultSource
    if ($found) { $sourceBox.Text = $found }
}

$form.Add_Shown({
    # 콘솔과 Forms 창을 구분해 바로가기의 Hidden 옵션에서도 메인 창을 표시한다.
    Initialize-GuiWindowApi
    $console = [EsdeSync.WindowApi]::GetConsoleWindow()
    if ($console -ne [IntPtr]::Zero) { [void][EsdeSync.WindowApi]::ShowWindow($console,0) }
    [void][EsdeSync.WindowApi]::ShowWindow($form.Handle,5)
    Refresh-Devices
    if ($UpdateSession) { Write-GuiConfirmation $UpdateSession $AppRoot $UpdateSessionId $AppVersion.version $ConfirmationFile }
    try { Start-UpdateTask 'check' $null } catch { $updateLabel.Text = '업데이트 확인 실패: ' + $_.Exception.Message }
})

$form.Add_FormClosing({
    if ($script:UpdateInstalling -and -not $script:AllowInstallClose) { $_.Cancel=$true; return }
    if ($script:UpdateBusy) {
        $_.Cancel = $true
        [void][System.Windows.Forms.MessageBox]::Show('다운로드·검증이 끝난 뒤 창을 닫아 주세요.')
        return
    }
    $updateTimer.Stop()
    $installTimer.Stop()
    if ($script:UpdateTask) {
        [void]$script:UpdateTask.PowerShell.BeginStop($null, $null)
    }
    Stop-AdbServer
})

[void]$form.ShowDialog()
}
finally { Exit-AppMutex $GuiMutex }
