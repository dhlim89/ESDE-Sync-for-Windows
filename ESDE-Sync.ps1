param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'update-common.ps1')
$AppVersion = Get-AppVersion (Join-Path $PSScriptRoot 'version.json')
$UpdateCommonPath = Join-Path $PSScriptRoot 'update-common.ps1'
$VersionFile = Join-Path $PSScriptRoot 'version.json'

$AppRoot = Join-Path $env:LOCALAPPDATA "ESDE-Sync"
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
    & $Adb start-server | Out-Null
    $result = @()
    foreach ($line in (& $Adb devices | Select-Object -Skip 1)) {
        if (-not $line.Trim()) { continue }
        $parts = $line -split "\s+"
        if ($parts.Count -lt 2) { continue }
        $serial = $parts[0]
        $state = $parts[1]
        $model = $serial
        if ($state -eq "device") {
            $m = (& $Adb -s $serial shell getprop ro.product.model 2>$null | Out-String).Trim()
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
    try {
        if (Test-Path -LiteralPath $AdbExe) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $AdbExe
            $psi.Arguments = "kill-server"
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true

            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $psi
            [void]$p.Start()
            $null = $p.StandardOutput.ReadToEnd()
            $null = $p.StandardError.ReadToEnd()
            $p.WaitForExit()
            $p.Dispose()
        }
    }
    catch {
        # App shutdown should not be blocked by an ADB cleanup failure.
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = ("ES-DE Sync v" + $AppVersion.version)
$form.Size = New-Object System.Drawing.Size(760, 640)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
if (Test-Path $IconFile) {
    try { $form.Icon = New-Object System.Drawing.Icon($IconFile) } catch {}
}

$title = New-Object System.Windows.Forms.Label
$title.Text = ("ES-DE Sync v" + $AppVersion.version)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 20)
$form.Controls.Add($title)

$desc = New-Object System.Windows.Forms.Label
$desc.Text = "Dropbox의 ES-DE Sync를 USB로 연결한 Android 기기에 안전하게 미러링합니다."
$desc.AutoSize = $true
$desc.Location = New-Object System.Drawing.Point(27, 58)
$form.Controls.Add($desc)

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = "원본 ES-DE Sync 폴더"
$sourceLabel.AutoSize = $true
$sourceLabel.Location = New-Object System.Drawing.Point(27, 90)
$form.Controls.Add($sourceLabel)

$sourceBox = New-Object System.Windows.Forms.TextBox
$sourceBox.Location = New-Object System.Drawing.Point(30, 112)
$sourceBox.Size = New-Object System.Drawing.Size(580, 28)
$form.Controls.Add($sourceBox)

$browseBtn = New-Object System.Windows.Forms.Button
$browseBtn.Text = "찾아보기"
$browseBtn.Location = New-Object System.Drawing.Point(620, 110)
$browseBtn.Size = New-Object System.Drawing.Size(100, 31)
$form.Controls.Add($browseBtn)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = "Android 기기"
$deviceLabel.AutoSize = $true
$deviceLabel.Location = New-Object System.Drawing.Point(27, 150)
$form.Controls.Add($deviceLabel)

$deviceCombo = New-Object System.Windows.Forms.ComboBox
$deviceCombo.DropDownStyle = "DropDownList"
$deviceCombo.Location = New-Object System.Drawing.Point(30, 172)
$deviceCombo.Size = New-Object System.Drawing.Size(580, 30)
$form.Controls.Add($deviceCombo)

$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = "새로고침"
$refreshBtn.Location = New-Object System.Drawing.Point(620, 170)
$refreshBtn.Size = New-Object System.Drawing.Size(100, 31)
$form.Controls.Add($refreshBtn)

$info = New-Object System.Windows.Forms.Label
$info.Text = "대상 경로:`r`nROM: /storage/emulated/0/ROMs`r`ngamelist: /storage/emulated/0/ES-DE/gamelists`r`nmedia: /storage/emulated/0/ES-DE/downloaded_media"
$info.AutoSize = $true
$info.Location = New-Object System.Drawing.Point(30, 220)
$form.Controls.Add($info)

$updateLabel = New-Object System.Windows.Forms.Label
$updateLabel.Text = '업데이트 확인 대기'
$updateLabel.Location = New-Object System.Drawing.Point(30, 282)
$updateLabel.Size = New-Object System.Drawing.Size(565, 30)
$form.Controls.Add($updateLabel)
$updateBtn = New-Object System.Windows.Forms.Button
$updateBtn.Text = '업데이트'
$updateBtn.Location = New-Object System.Drawing.Point(610, 278)
$updateBtn.Size = New-Object System.Drawing.Size(110, 31)
$updateBtn.Enabled = $false
$form.Controls.Add($updateBtn)

$warn = New-Object System.Windows.Forms.Label
$warn.Text = "선택된 시스템은 완전 미러링하되, 각 시스템의 _TEST / _UNREGISTERED 폴더는 항상 보존·제외합니다."
$warn.AutoSize = $true
$warn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$warn.Location = New-Object System.Drawing.Point(30, 315)
$form.Controls.Add($warn)

$syncBtn = New-Object System.Windows.Forms.Button
$syncBtn.Text = "Android 동기화 시작"
$syncBtn.Location = New-Object System.Drawing.Point(30, 348)
$syncBtn.Size = New-Object System.Drawing.Size(690, 44)
$form.Controls.Add($syncBtn)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(30, 408)
$progress.Size = New-Object System.Drawing.Size(690, 22)
$form.Controls.Add($progress)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "대기 중"
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(30, 440)
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(30, 470)
$logBox.Size = New-Object System.Drawing.Size(690, 110)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$form.Controls.Add($logBox)

$script:Adb = Get-AdbPath
$script:Devices = @()
$script:WorkerProcess = $null
$script:UpdateTask = $null
$script:UpdateCandidate = $null
$script:UpdateBusy = $false

function Start-UpdateTask([string]$Kind, $Candidate) {
    if ($script:UpdateTask) { throw '업데이트 작업이 이미 실행 중입니다.' }
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
            $updateLabel.Text = '업데이트 패키지 검증 완료 (설치 기능 미활성)'
            [void][System.Windows.Forms.MessageBox]::Show(('업데이트 패키지 검증 완료. 설치 기능은 다음 단계에서 활성화됩니다.' + "`r`n" + $output[0].ZipPath))
        }
    }
    catch { $updateLabel.Text = '업데이트 확인/검증 실패: ' + $_.Exception.Message }
    finally {
        $task.PowerShell.Dispose()
        $script:UpdateTask = $null
        $script:UpdateBusy = $false
        $syncBtn.Enabled = -not ($script:WorkerProcess -and -not $script:WorkerProcess.HasExited)
        $updateBtn.Enabled = [bool]$script:UpdateCandidate
    }
})
$updateTimer.Start()

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
        if ($script:UpdateBusy) { throw '업데이트 다운로드·검증 중에는 동기화를 시작할 수 없습니다.' }
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
        $syncBtn.Enabled = -not $script:UpdateBusy
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
    Refresh-Devices
    try { Start-UpdateTask 'check' $null } catch { $updateLabel.Text = '업데이트 확인 실패: ' + $_.Exception.Message }
})

$form.Add_FormClosing({
    if ($script:UpdateBusy) {
        $_.Cancel = $true
        [void][System.Windows.Forms.MessageBox]::Show('다운로드·검증이 끝난 뒤 창을 닫아 주세요.')
        return
    }
    $updateTimer.Stop()
    if ($script:UpdateTask) {
        [void]$script:UpdateTask.PowerShell.BeginStop($null, $null)
    }
    Stop-AdbServer
})

[void]$form.ShowDialog()
