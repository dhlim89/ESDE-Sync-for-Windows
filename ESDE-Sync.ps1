param([string]$InstallRoot, [string]$UpdateSession, [string]$UpdateSessionId,
    [ValidateSet('startup-confirmation.json','rollback-confirmation.json')][string]$ConfirmationFile = 'startup-confirmation.json')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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

function Format-SyncCompletionMessage($Summary) {
    if($null-eq$Summary){return 'Android 동기화가 완료되었습니다.'}
    $lines=@(
        '동기화 완료'
        ''
        ('관리 ROM: '+[int]$Summary.ManagedCount)
        ('비관리 ROM 이동: '+[int]$Summary.UnmanagedMoveCount)
        ('로컬 전용: '+[int]$Summary.LocalOnlyCount)
        ('확인 필요: '+[int]$Summary.ReviewCount)
    )
    if([int]$Summary.PromotedCount-gt0){$lines=@($lines[0..3])+@(('관리 ROM 승격: '+[int]$Summary.PromotedCount))+@($lines[4..5])}
    if([int]$Summary.ReviewCount-gt0){
        $lines+=@('','확인 필요 항목')
        foreach($item in @($Summary.Items|Select-Object -First 5)){
            $reason=switch($item.Classification){
                'LOCAL_ONLY_MANAGED_MATCH' {'로컬 전용 ROM과 같은 ROM이 관리 라이브러리에 추가되었습니다. 중복 전송을 보류하고 기기의 ROM을 보존했습니다. 세이브/상태 보호를 위해 자동 이름 변경은 하지 않았습니다.'}
                'MANAGED_CONFLICT' {'기기의 ROM 버전이 관리본과 다릅니다. ROM은 보존했습니다. 버전·리비전·패치를 확인해 주세요.'}
                'MANAGED_PATH_MISMATCH' {'같은 ROM이지만 파일 이름 또는 경로가 다릅니다. 세이브 보호를 위해 자동 변경하지 않았습니다.'}
                'AMBIGUOUS' {'관리 ROM 대응 후보가 여러 개이거나 경로가 모호합니다. 자동 변경하지 않았습니다.'}
                default {'상세 로그에서 확인이 필요한 항목을 검토해 주세요.'}
            }
            $lines+=@(('- '+$item.System+'/'+$item.RelativePath),('  '+$reason))
        }
        if([int]$Summary.ReviewCount-gt5){$lines+=('그 외 '+([int]$Summary.ReviewCount-5)+'개 항목은 상세 로그를 확인해 주세요.')}
    }
    return ($lines -join [Environment]::NewLine)
}

function Format-DuplicateResult($Result) {
    @('중복 ROM 정리 결과',('정리 완료: '+[int]$Result.SafeDelete),('병합 후 정리: '+[int]$Result.SafeMergeDelete),('검토 필요: '+[int]$Result.Review),('실패: '+[int]$Result.Failed),('미처리: '+[int]$Result.Unprocessed)) -join [Environment]::NewLine
}
function Get-DuplicateConfirmation([int]$Count) {
    "선택한 미등록 ROM $Count"+'개를 정리합니다.'+"`r`n`r`n관리 ROM은 유지됩니다.`r`n필요한 저장 데이터와 메타데이터는 검증 후 병합됩니다.`r`n_TEST는 변경되지 않습니다."
}
function Format-DuplicateReason([string]$Reason) {
    switch -Regex ($Reason) {
        '^verified triple' {return 'ROM 해시 일치, 지원 데이터 매핑 확인, 충돌 없음'}
        'metadata|runtime' {return '메타데이터를 손실 없이 병합할 수 있는지 검토가 필요합니다.'}
        'media' {return '연결된 로컬 미디어 또는 미확인 미디어 구조가 있습니다.'}
        'slot|state|save|asset|sibling' {return '저장 파일 충돌 또는 지원하지 않는 저장 이름이 있습니다.'}
        'environment|SameBoy|core|inventor' {return 'SameBoy 환경 또는 전체 파일 목록의 안전 근거가 부족합니다.'}
        'case|path|namespace|basename' {return '경로·대소문자·저장 이름의 소유권을 확인해야 합니다.'}
        'SHA|file|candidate|ambiguous|canonical' {return '관리본 대응, 파일 존재 또는 해시 일치를 확인해야 합니다.'}
        default {return '안전 조건을 확인하지 못했습니다. 상세 로그를 확인해 주세요.'}
    }
}
function Set-DuplicateUiSelection($Ui,[bool]$Select) {
    foreach($row in $Ui.Grid.Rows){$row.Cells[0].Value=($Select-and$row.Tag.CheckboxEnabled)}
    Update-DuplicateUiSelection $Ui
}
function Update-DuplicateUiSelection($Ui) {
    $count=@($Ui.Grid.Rows|Where-Object {$_.Tag.CheckboxEnabled-and[bool]$_.Cells[0].Value}).Count
    $Ui.Execute.Enabled=($count-gt0-and-not$Ui.Busy);$Ui.Count.Text=('선택: '+$count+'개')
}
function Invoke-DuplicateUiSelection($Ui) {
    $Ui.Grid.EndEdit()|Out-Null
    $ids=@($Ui.Grid.Rows|Where-Object {$_.Tag.CheckboxEnabled-and[bool]$_.Cells[0].Value}|ForEach-Object {$_.Tag.Id})
    if(-not$ids.Count-or$Ui.Busy){return}
    if(-not(& $Ui.Confirm (Get-DuplicateConfirmation $ids.Count))){return}
    $Ui.Busy=$true;$Ui.Grid.Enabled=$false;$Ui.Execute.Enabled=$false;$Ui.SelectAll.Enabled=$false;$Ui.Clear.Enabled=$false
    try{[void](& $Ui.OnExecute $ids)}catch{$Ui.Busy=$false;$Ui.Grid.Enabled=$true;$Ui.SelectAll.Enabled=$true;$Ui.Clear.Enabled=$true;Update-DuplicateUiSelection $Ui;throw}
}
function New-DuplicateManagerDialog($Scan,[scriptblock]$OnExecute,[scriptblock]$Confirm) {
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='미등록 중복 ROM 관리';$dialog.StartPosition='CenterParent';$dialog.ClientSize=New-Object Drawing.Size(1040,620);$dialog.MinimumSize=New-Object Drawing.Size(900,600);$dialog.Font=New-Object Drawing.Font('Segoe UI',10);$dialog.AutoScaleMode='Dpi';$dialog.AutoScaleDimensions=New-Object Drawing.SizeF(96,96)
    $grid=New-Object Windows.Forms.DataGridView;$grid.Location=New-Object Drawing.Point(16,48);$grid.Size=New-Object Drawing.Size(1008,340);$grid.Anchor='Top,Left,Right,Bottom';$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.AutoSizeColumnsMode='Fill'
    $names=@('선택','시스템','미등록 ROM','관리 ROM','상태','처리 내용','이유')
    foreach($name in $names){$column=if($name-ceq'선택'){New-Object Windows.Forms.DataGridViewCheckBoxColumn}else{New-Object Windows.Forms.DataGridViewTextBoxColumn};$column.Name=$name;$column.HeaderText=$name;$column.ReadOnly=($name-cne'선택');$column.SortMode='NotSortable';[void]$grid.Columns.Add($column)}
    $grid.Columns[0].FillWeight=45;$grid.Columns[0].MinimumWidth=58;$grid.Columns[1].FillWeight=55;$grid.Columns[1].MinimumWidth=70;$grid.Columns[2].FillWeight=150;$grid.Columns[3].FillWeight=140;$grid.Columns[6].FillWeight=170
    foreach($row in @($Scan.rows)){
        if($row.SourceRelativePath-match'(?i)(^|[/\\])_TEST([/\\]|$)'){continue}
        $safe=($row.CheckboxEnabled-and$row.Grade-cin@('SAFE_DELETE','SAFE_MERGE_DELETE'))
        $row.CheckboxEnabled=$safe
        $status=if($row.Grade-ceq'SAFE_DELETE'){'정리 가능'}elseif($row.Grade-ceq'SAFE_MERGE_DELETE'){'병합 후 정리'}else{'검토 필요'}
        $action=if($row.Grade-ceq'SAFE_DELETE'){'ROM 삭제'}elseif($row.Grade-ceq'SAFE_MERGE_DELETE'){'저장/메타데이터 병합 후 삭제'}else{'처리 안 함'}
        $i=$grid.Rows.Add($false,$row.System.ToUpperInvariant(),$row.SourceRelativePath,$row.CanonicalRelativePath,$status,$action,(Format-DuplicateReason $row.Reason));$grid.Rows[$i].Tag=$row;$grid.Rows[$i].Cells[0].ReadOnly=-not$safe
        if(-not$safe){$grid.Rows[$i].DefaultCellStyle.ForeColor=[Drawing.Color]::Gray}
    }
    $detail=New-Object Windows.Forms.TextBox;$detail.Multiline=$true;$detail.ReadOnly=$true;$detail.ScrollBars='Vertical';$detail.SetBounds(16,400,1008,148);$detail.Anchor='Bottom,Left,Right'
    $selectAll=New-Object Windows.Forms.Button;$selectAll.Text='정리 가능한 항목 선택';$selectAll.SetBounds(16,10,195,30)
    $clear=New-Object Windows.Forms.Button;$clear.Text='전체 해제';$clear.SetBounds(220,10,110,30)
    $count=New-Object Windows.Forms.Label;$count.Text='선택: 0개';$count.SetBounds(345,14,180,25)
    $execute=New-Object Windows.Forms.Button;$execute.Text='선택한 미등록 ROM 정리';$execute.SetBounds(16,566,220,36);$execute.Anchor='Bottom,Left';$execute.Enabled=$false
    $close=New-Object Windows.Forms.Button;$close.Text='닫기';$close.SetBounds(904,566,120,36);$close.Anchor='Bottom,Right'
    if(-not$Confirm){$Confirm={param($message)[Windows.Forms.MessageBox]::Show($message,'정리 확인',[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Warning)-eq[Windows.Forms.DialogResult]::OK}}
    $ui=[pscustomobject]@{Dialog=$dialog;Grid=$grid;Detail=$detail;SelectAll=$selectAll;Clear=$clear;Count=$count;Execute=$execute;Close=$close;Busy=$false;OnExecute=$OnExecute;Confirm=$Confirm}
    $dialog.Tag=$ui
    $selectAll.Add_Click({Set-DuplicateUiSelection $ui $true}.GetNewClosure());$clear.Add_Click({Set-DuplicateUiSelection $ui $false}.GetNewClosure())
    $grid.Add_CurrentCellDirtyStateChanged({if($grid.IsCurrentCellDirty){[void]$grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)}}.GetNewClosure())
    $grid.Add_CellValueChanged({Update-DuplicateUiSelection $ui}.GetNewClosure())
    $grid.Add_SelectionChanged({if($grid.SelectedRows.Count){$r=$grid.SelectedRows[0].Tag;if($r){$moves=@($r.AssetMoves|ForEach-Object {$_.SourceRelativePath+' → '+$_.DestinationRelativePath});$detail.Text=@(('미등록: '+$r.SourceRelativePath),('관리 ROM: '+$r.CanonicalRelativePath),('SHA-256: '+$r.Sha256),('저장 migration: '+$(if($moves.Count){$moves-join'; '}else{'없음'})),('metadata: '+$(if($r.Grade-ceq'REVIEW_ONLY'){'처리하지 않음 / 검토 필요'}elseif($r.MetadataMerge){'기존 정책으로 병합'}else{'안전한 local node 정리'})),('media: '+$(if($r.HasLocalMedia){'로컬 미디어 존재 / 처리하지 않음'}else{'로컬 미디어 없음 / HOLD'})),('판정: '+(Format-DuplicateReason $r.Reason))) -join "`r`n"}}}.GetNewClosure())
    $execute.Add_Click({try{Invoke-DuplicateUiSelection $ui}catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'정리 시작 실패')}}.GetNewClosure())
    $close.Add_Click({if(-not$ui.Busy){$dialog.Close()}}.GetNewClosure())
    $dialog.Add_FormClosing({param($sender,$event)if($ui.Busy){$event.Cancel=$true}}.GetNewClosure())
    foreach($control in @($grid,$detail,$selectAll,$clear,$count,$execute,$close)){[void]$dialog.Controls.Add($control)}
    return $ui
}
function New-DuplicateResultDialog($Result) {
    $form=New-Object Windows.Forms.Form;$form.Text='중복 ROM 정리 결과';$form.ClientSize=New-Object Drawing.Size(470,310);$form.StartPosition='CenterParent';$form.Font=New-Object Drawing.Font('Segoe UI',10)
    $text=New-Object Windows.Forms.TextBox;$text.Multiline=$true;$text.ReadOnly=$true;$text.ScrollBars='Vertical';$text.SetBounds(16,16,438,225);$text.Text=Format-DuplicateResult $Result
    $copy=New-Object Windows.Forms.Button;$copy.Text='결과 복사';$copy.SetBounds(16,256,130,34);$copy.Add_Click({[Windows.Forms.Clipboard]::SetText($text.Text)}.GetNewClosure())
    $close=New-Object Windows.Forms.Button;$close.Text='닫기';$close.SetBounds(334,256,120,34);$close.Add_Click({$form.Close()}.GetNewClosure())
    $form.Controls.AddRange(@($text,$copy,$close));$form.Tag=[pscustomobject]@{Text=$text;Copy=$copy;Close=$close};return $form
}
function Read-FinalSyncStatus([string]$Path) {
    # Only consume authoritative terminal status after the worker has exited.
    # The last timer frame may still be restarting and contain no summary.
    $result=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    if($result.state-cne'done'-or[int]$result.percent-ne100-or[int]$result.current-ne[int]$result.total){throw '최종 동기화 상태를 확인할 수 없습니다. status.json과 로그를 확인해 주세요.'}
    return $result
}

function Start-GuiOperationProfile([string]$Mode) {
    $script:GuiOperationProfile=[ordered]@{operation=$Mode;clickedAtUtc=[DateTime]::UtcNow.ToString('o');workerStartedAtUtc=$null;completedAtUtc=$null;elapsedMs=$null}
    $script:GuiOperationClock=[Diagnostics.Stopwatch]::StartNew()
}
function Complete-GuiOperationProfile {
    if(-not$script:GuiOperationProfile){return}
    $script:GuiOperationClock.Stop()
    $script:GuiOperationProfile.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    $script:GuiOperationProfile.elapsedMs=$script:GuiOperationClock.ElapsedMilliseconds
    try{[IO.File]::WriteAllText((Join-Path $StateDir ('gui-performance-'+$script:GuiOperationProfile.operation+'.json')),($script:GuiOperationProfile|ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))}catch{}
}

function Reset-DuplicateProgress($Bar) {
    $Bar.Visible=$true
    $Bar.Value=0
    $Bar.MarqueeAnimationSpeed=30
    $Bar.Style=[Windows.Forms.ProgressBarStyle]::Marquee
}

function Start-DuplicateTask([string]$Mode,$Scan,[string[]]$Ids=@()) {
    Start-GuiOperationProfile $Mode
    if($script:WorkerProcess-or$script:DuplicateProcess-or$script:UpdateBusy-or$script:UpdateInstalling-or$script:StartupPending){throw '다른 작업이 끝난 뒤 중복 관리를 실행해 주세요.'}
    if(-not$script:Adb-or$deviceCombo.SelectedIndex-lt0){throw 'Android 기기를 선택하세요.'}
    $dev=$script:Devices[$deviceCombo.SelectedIndex];if($dev.State-cne'device'){throw 'USB 디버깅 승인이 필요합니다.'}
    $source=$sourceBox.Text.Trim();$selectionPath=$null
    if($Mode-ceq'DuplicateCleanup'){
        if($Scan.serial-cne$dev.Serial-or[IO.Path]::GetFullPath($source)-cne$Scan.sourceRoot){throw '검사 당시 원본/기기와 다릅니다. 다시 검사해 주세요.'}
        $selectionPath=Join-Path $StateDir ('duplicate-selection-'+[guid]::NewGuid().ToString('N')+'.json')
        @{schemaVersion=1;scanId=$Scan.scanId;identity=$Scan.identity;ids=$Ids}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $selectionPath -Encoding UTF8
    }
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Worker+'"'),'-SourceRoot',('"'+$source+'"'),'-Serial',('"'+$dev.Serial+'"'),'-AdbPath',('"'+$script:Adb+'"'),'-StateDir',('"'+$StateDir+'"'),'-AppRoot',('"'+$AppRoot+'"'),'-Operation',$Mode)
    if($selectionPath){$args+=@('-SelectionFile',('"'+$selectionPath+'"'))}
    $script:DuplicateRequestId=[guid]::NewGuid().ToString('N');$args+=@('-DuplicateRequestId',$script:DuplicateRequestId)
    $script:DuplicateMode=$Mode
    if($progress){Reset-DuplicateProgress $progress}
    $script:DuplicateProcess=Start-Process powershell.exe -ArgumentList ($args-join' ') -WindowStyle Hidden -PassThru
    $script:GuiOperationProfile.workerStartedAtUtc=[DateTime]::UtcNow.ToString('o')
    $syncBtn.Enabled=$false;$duplicateBtn.Enabled=$false;$updateBtn.Enabled=$false;$installUpdateBtn.Enabled=$false
    $statusLabel.Text=if($Mode-ceq'DuplicateScan'){'중복 ROM 검사 중...'}else{'선택한 중복 ROM 정리 중...'}
}
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
            warn=@(30,358,690,40);syncBtn=@(30,410,480,44);duplicateBtn=@(520,410,200,44)
            progress=@(30,468,690,22);statusLabel=@(30,498,690,38);logBox=@(30,538,690,110)
        }
    }
}

function Get-WorkerProgressPresentation($Status) {
    $percent=if($null-ne$Status.overallPercent){[int]$Status.overallPercent}else{[int]$Status.percent}
    $text=[string]$Status.message
    if($null-ne$Status.elapsedMs){
        $count=if($Status.phaseTotal-gt0){' '+$Status.phaseCurrent+' / '+$Status.phaseTotal}else{' 확인 중'}
        $text='전체 '+$percent+'% · '+$Status.phaseLabel+$count+' · 경과 '+[TimeSpan]::FromMilliseconds([double]$Status.elapsedMs).ToString('hh\:mm\:ss')
        if($Status.currentItem){$text+="`r`n"+$Status.currentItem}
    }
    [pscustomobject]@{Text=$text;Percent=[math]::Max(0,[math]::Min(100,$percent));Indeterminate=([bool]$Status.indeterminate-and$Status.state-cnotin@('done','error'))}
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
$duplicateBtn=New-Object Windows.Forms.Button;$duplicateBtn.Text='중복 ROM 확인';$form.Controls.Add($duplicateBtn)

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
    syncBtn=$syncBtn;duplicateBtn=$duplicateBtn;progress=$progress;statusLabel=$statusLabel;logBox=$logBox
}

$script:Adb = Get-AdbPath
$script:Devices = @()
$script:WorkerProcess = $null
$script:DuplicateProcess=$null;$script:DuplicateDialog=$null
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
        if ($script:DuplicateProcess -or ($script:WorkerProcess -and -not $script:WorkerProcess.HasExited)) { throw '동기화 중에는 업데이트 다운로드를 시작할 수 없습니다.' }
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
            ($script:DuplicateProcess -or ($script:WorkerProcess -and -not $script:WorkerProcess.HasExited))) { throw '다른 작업이 실행 중입니다.' }
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
$duplicateBtn.Add_Click({try{Start-DuplicateTask 'DuplicateScan' $null}catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'중복 검사 실패')}})

$syncBtn.Add_Click({
    Start-GuiOperationProfile 'Sync'
    try {
        if ($script:DuplicateProcess -or $script:UpdateBusy -or $script:UpdateInstalling -or $script:StartupPending) { throw '업데이트 또는 복구 작업 중에는 동기화를 시작할 수 없습니다.' }
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
        $script:GuiOperationProfile.workerStartedAtUtc=[DateTime]::UtcNow.ToString('o')
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
    if($script:DuplicateProcess){
        if(-not$script:DuplicateProcess.HasExited){
            try{
                $st=Get-Content (Join-Path $StateDir 'duplicate-status.json') -Raw -Encoding UTF8|ConvertFrom-Json
                if($st.requestId-ceq$script:DuplicateRequestId){$presentation=Get-WorkerProgressPresentation $st;$statusLabel.Text=$presentation.Text;$progress.Style=if($presentation.Indeterminate){[Windows.Forms.ProgressBarStyle]::Marquee}else{[Windows.Forms.ProgressBarStyle]::Continuous};$progress.Value=$presentation.Percent}
            }catch{}
            return
        }
        $progress.Style=[Windows.Forms.ProgressBarStyle]::Continuous
        if($script:DuplicateMode-cne'DuplicateScan'){Complete-GuiOperationProfile}
        $code=$script:DuplicateProcess.ExitCode;$script:DuplicateProcess=$null
        $progress.Value=if($code-eq0){100}else{0}
        $syncBtn.Enabled=-not$script:StartupPending-and-not$script:UpdateBusy;$duplicateBtn.Enabled=$syncBtn.Enabled
        $installUpdateBtn.Enabled=[bool]$script:VerifiedPackage;$updateBtn.Enabled=[bool]$script:UpdateCandidate
        if($script:DuplicateMode-ceq'DuplicateScan'){
            if($code-ne0){$statusLabel.Text='중복 검사 중단 / 복구 확인 필요';[void][Windows.Forms.MessageBox]::Show('중복 검사를 완료하지 못했습니다. duplicate.log와 duplicate-recovery-report.json을 확인해 주세요. 미완료 journal이 있으면 신규 정리와 sync가 차단됩니다. 자동 재개나 rollback은 하지 않습니다.');return}
            $scan=Get-Content (Join-Path $StateDir 'duplicate-scan.json') -Raw -Encoding UTF8|ConvertFrom-Json
            if($scan.requestId-cne$script:DuplicateRequestId){$statusLabel.Text='검사 결과 식별 불일치';return}
            $statusLabel.Text=('관리 ROM과 중복된 미등록 ROM '+$scan.DuplicateUnregisteredCount+'개가 있습니다.')
            $execute={param($ids)Start-DuplicateTask 'DuplicateCleanup' $scan $ids}.GetNewClosure()
            $script:DuplicateDialog=New-DuplicateManagerDialog $scan $execute
            Complete-GuiOperationProfile
            [void]$script:DuplicateDialog.Dialog.ShowDialog($form);$script:DuplicateDialog.Dialog.Dispose();$script:DuplicateDialog=$null
        }else{
            if($script:DuplicateDialog){$script:DuplicateDialog.Busy=$false;$script:DuplicateDialog.Dialog.Close()}
            $path=Join-Path $StateDir 'duplicate-result.json'
            if(Test-Path -LiteralPath $path){$result=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;if($result.requestId-ceq$script:DuplicateRequestId){$dialog=New-DuplicateResultDialog $result;[void]$dialog.ShowDialog($form);$dialog.Dispose()}}
            if($code-ne0){[void][Windows.Forms.MessageBox]::Show('정리 작업을 완료하지 못했습니다. journal과 duplicate.log를 확인하고 재실행하지 마세요.','복구 확인 필요')}
            $statusLabel.Text=if($code-eq0){'중복 ROM 정리 완료'}else{'중복 ROM 정리 중단'}
        }
        return
    }
    $duplicateBtn.Enabled=-not$script:WorkerProcess-and-not$script:UpdateBusy-and-not$script:UpdateInstalling-and-not$script:StartupPending
    if ($script:WorkerProcess -eq $null) { return }

    if (Test-Path $StatusFile) {
        try {
            $st = Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $presentation=Get-WorkerProgressPresentation $st
            $statusLabel.Text=$presentation.Text
            $p=$presentation.Percent
            $progress.Style=if($presentation.Indeterminate){[Windows.Forms.ProgressBarStyle]::Marquee}else{[Windows.Forms.ProgressBarStyle]::Continuous}
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
        Complete-GuiOperationProfile
        $code = $script:WorkerProcess.ExitCode
        $script:WorkerProcess = $null
        $syncBtn.Enabled = -not $script:UpdateBusy -and -not $script:UpdateInstalling -and -not $script:StartupPending
        if ($code -eq 0) {
            try{$st=Read-FinalSyncStatus $StatusFile}
            catch{$statusLabel.Text='완료 상태 확인 필요';[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'동기화 결과 확인 필요');return}
            $progress.Style=[Windows.Forms.ProgressBarStyle]::Continuous
            $progress.Value = 100
            $statusLabel.Text = "동기화 완료"
            $completionSummary=$null
            if($st -and $st.state-ceq'done'){$completionSummary=$st.summary}
            $completionText=Format-SyncCompletionMessage $completionSummary
            if([int]$st.DuplicateUnregisteredCount-gt0){$completionText+=[Environment]::NewLine+[Environment]::NewLine+('관리 ROM과 중복된 미등록 ROM '+$st.DuplicateUnregisteredCount+'개가 있습니다. 메인 화면의 중복 ROM 확인을 눌러 주세요.')}
            [System.Windows.Forms.MessageBox]::Show($completionText, '동기화 결과') | Out-Null
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
    if($script:DuplicateProcess-and-not$script:DuplicateProcess.HasExited){$_.Cancel=$true;return}
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
