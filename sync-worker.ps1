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

function Get-PackageFromComponent([string]$Component) {
    if (-not $Component) { return "" }
    $c = $Component.Trim()
    if ($c -match '^([A-Za-z0-9._-]+)/') { return $matches[1] }
    return ""
}

function Get-ForegroundPackage {
    $r = Invoke-Adb -s $Serial shell "dumpsys activity activities"
    if ($r.Code -eq 0) {
        foreach ($line in $r.Output) {
            $s = [string]$line

            if ($s -match 'topResumedActivity=.*?([A-Za-z0-9._-]+)/[A-Za-z0-9._$-]+') {
                Write-Log "FOREGROUND DETECTION: topResumedActivity"
                return $matches[1]
            }

            if ($s -match 'mResumedActivity=.*?([A-Za-z0-9._-]+)/[A-Za-z0-9._$-]+') {
                Write-Log "FOREGROUND DETECTION: mResumedActivity"
                return $matches[1]
            }
        }
    }

    $w = Invoke-Adb -s $Serial shell "dumpsys window windows"
    if ($w.Code -eq 0) {
        foreach ($line in $w.Output) {
            $s = [string]$line
            if (($s -match 'mCurrentFocus=.*?([A-Za-z0-9._-]+)/[A-Za-z0-9._$-]+') -or
                ($s -match 'mFocusedApp=.*?([A-Za-z0-9._-]+)/[A-Za-z0-9._$-]+')) {
                Write-Log "FOREGROUND DETECTION: window focus"
                return $matches[1]
            }
        }
    }

    Write-Log "FOREGROUND DETECTION: none"
    return ""
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
    Write-Status "preflight" "실행 중인 게임을 확인하는 중..." 0 1

    $foreground = Get-ForegroundPackage
    $homePackage = Get-HomePackage

    if ($homePackage) {
        Write-Log "HOME PACKAGE: $homePackage"
    }

    if (-not $foreground) {
        Write-Log "PREFLIGHT BLOCK: foreground package unknown"
        throw "현재 실행 중인 앱을 확인할 수 없어 안전을 위해 동기화를 중단했습니다."
    }

    Write-Log "FOREGROUND PACKAGE: $foreground"

    $allowed = @(
        "org.es_de.frontend",
        "com.android.systemui",
        "com.android.launcher3"
    )

    if ($homePackage) {
        $allowed += $homePackage
    }

    if ($allowed -contains $foreground) {
        Write-Log "PREFLIGHT OK: foreground is ES-DE/home/system UI"
        return
    }

    Write-Log "PREFLIGHT BLOCK: game/emulator or other app is running"
    throw "게임 또는 다른 앱이 실행 중입니다. 게임을 종료하고 ES-DE 화면으로 돌아온 뒤 다시 동기화해 주세요. 감지된 앱: $foreground"
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
