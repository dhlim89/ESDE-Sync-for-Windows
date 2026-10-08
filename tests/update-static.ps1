$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'update-common.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repositoryInfo = Get-AppVersion (Join-Path $repo 'version.json')
# 기존 updater 회귀 fixture는 1.4.8 -> 1.4.9로 유지한다.
$info = $repositoryInfo | ConvertTo-Json | ConvertFrom-Json
$info.version='1.4.8'; $info.releaseTag='v1.4.8'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('esde-update-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$script:Passed = 0
function Check($value, [string]$name) {
    if (-not $value) { throw "검증 실패: $name" }
    $script:Passed++; Write-Output "PASS: $name"
}
function Reject([string]$name, [scriptblock]$work, [string]$pattern) {
    $message = ''
    try { & $work | Out-Null } catch { $message = $_.Exception.Message }
    Check ($message -and (-not $pattern -or $message -match $pattern)) ($name + ' 차단')
}
function Clone-Info { return ($info | ConvertTo-Json | ConvertFrom-Json) }
function New-Fixture([string]$Name, [string[]]$Removed = @(), [object[]]$Extra = @(), [string]$ManifestMode = '', $TargetInfo = $info, [switch]$MatchReadme) {
    $path = Join-Path $sandbox ($Name + '.zip')
    $records = @(); $payload = @()
    foreach ($file in Get-PackageFiles) {
        $source = if ($file.StartsWith('App/')) { $file.Substring(4) } else { $file }
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $source))
        if ($file -eq 'App/version.json') { $bytes = [Text.Encoding]::UTF8.GetBytes(($TargetInfo | ConvertTo-Json)) }
        if ($file -eq 'README.txt') {
            $readmeVersion = if ($MatchReadme) { $TargetInfo.version } else { $info.version }
            $bytes = [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($bytes).Replace(('v'+$repositoryInfo.version+' Development'), ('v'+$readmeVersion+' Development')))
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') } finally { $sha.Dispose() }
        $records += [pscustomobject]@{path=$file;size=$bytes.Length;sha256=$hash}
        if ($Removed -notcontains $file) { $payload += [pscustomobject]@{path=$file;bytes=$bytes;link=$false} }
    }
    switch ($ManifestMode) {
        'hash' { $records[0].sha256 = '0' * 64 }
        'size' { $records[0].size++ }
        'missing' { $records = @($records | Select-Object -Skip 1) }
        'duplicate' { $records += $records[0] }
        'version' { }
    }
    $manifestVersion = if ($ManifestMode -eq 'version') { '9.9.9' } else { $TargetInfo.version }
    $manifest = @{schemaVersion=1;version=$manifestVersion;files=$records} | ConvertTo-Json -Depth 5
    $payload += [pscustomobject]@{path='package-manifest.json';bytes=[Text.Encoding]::UTF8.GetBytes($manifest);link=$false}
    $payload += $Extra
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in $payload) {
            $entry = $zip.CreateEntry($item.path)
            if ($item.link) { $entry.ExternalAttributes = -1610612736 }
            $stream = $entry.Open()
            try { $stream.Write($item.bytes, 0, $item.bytes.Length) } finally { $stream.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    return $path
}
Check ($info.version -ceq '1.4.8' -and $info.releaseTag -ceq 'v1.4.8') '정상 version.json'
$bad = Clone-Info; $bad.schemaVersion = 2
Reject 'schemaVersion' { Assert-VersionContract $bad } 'schemaVersion'
$bad = Clone-Info; $bad.releaseTag = 'v1.4.9'
Reject 'releaseTag' { Assert-VersionContract $bad } 'releaseTag'
Check ((Compare-UpdateVersion '1.4.10' '1.4.9') -gt 0) '숫자 버전 비교'
Check ((Compare-UpdateVersion '1.4.8' '1.4.8') -eq 0 -and (Compare-UpdateVersion '1.4.7' '1.4.8') -lt 0) '동일/이전 버전 비교'
Reject '비정상 버전' { ConvertTo-UpdateVersion '1.4.8-beta' } '버전'
$normal = New-Fixture 'normal'
$result = Test-UpdatePackage $normal $info.version $info
Check ($result.Verified -and $result.FileCount -eq (Get-PackageFiles).Count) '정상 ZIP/manifest 전체 검증'
$hash = (Get-FileHash $normal).Hash.ToLowerInvariant()
$assetName = 'ESDE-Sync-v1.4.8.zip'
$checksum = $hash + '  ' + $assetName
Check ((Assert-UpdateHashes $normal $checksum ('sha256:'+$hash) $assetName) -ieq $hash) '정상 checksum/digest'
Reject 'checksum 불일치' { Assert-UpdateHashes $normal (('0'*64)+'  '+$assetName) ('sha256:'+$hash) $assetName } '불일치'
Reject 'digest 불일치' { Assert-UpdateHashes $normal $checksum ('sha256:'+('0'*64)) $assetName } '불일치'
Reject 'checksum 이름' { Assert-UpdateHashes $normal ($hash+'  wrong.zip') ('sha256:'+$hash) $assetName } '계약'
$corrupt = Join-Path $sandbox 'corrupt.zip'; [IO.File]::WriteAllText($corrupt, 'not a zip')
Reject '손상 ZIP' { Test-UpdatePackage $corrupt $info.version $info }
foreach ($case in @(@('traversal','../outside.txt'),@('absolute','/outside.txt'),@('drive','C:/outside.txt'),@('reserved','App/CON.txt'),@('trailing','App/name. '),@('unexpected','State/status.json'),@('duplicate','App/version.json'),@('case','app/VERSION.JSON'))) {
    $extra = [pscustomobject]@{path=$case[1];bytes=[byte[]]@(1);link=$false}
    $fixture = New-Fixture $case[0] -Extra @($extra)
    Reject $case[0] { Test-UpdatePackage $fixture $info.version $info }
}
$fixture = New-Fixture 'missing' -Removed @('App/sync-worker.ps1')
Reject '필수 파일 누락' { Test-UpdatePackage $fixture $info.version $info } '필수'
foreach ($mode in @('hash','size','missing','duplicate','version')) {
    $fixture = New-Fixture ('manifest-'+$mode) -ManifestMode $mode
    Reject ('manifest '+$mode) { Test-UpdatePackage $fixture $info.version $info } 'manifest'
}
$bad = Clone-Info; $bad.releaseTag = 'v9.9.9'
$fixture = New-Fixture 'package-tag' -TargetInfo $bad
Reject '패키지 releaseTag' { Test-UpdatePackage $fixture $info.version $info } 'releaseTag'
$bad = Clone-Info; $bad.minimumUpdaterVersion = '2.0.0'
$fixture = New-Fixture 'minimum-updater' -TargetInfo $bad
Reject '최소 updater' { Test-UpdatePackage $fixture $info.version $info } 'updater'
Reject '압축 크기' { Test-UpdatePackage $normal $info.version $info -MaxZipBytes 1 } '크기'
Reject '전개 크기' { Test-UpdatePackage $normal $info.version $info -MaxExpandedBytes 1 } '크기'
Reject '파일 수' { Test-UpdatePackage $normal $info.version $info -MaxEntries 1 } '파일 수'
$fixture = New-Fixture 'link' -Removed @('App/ESDE-Sync.ps1') -Extra @([pscustomobject]@{path='App/ESDE-Sync.ps1';bytes=[byte[]]@(1);link=$true})
Reject 'ZIP 링크' { Test-UpdatePackage $fixture $info.version $info } '링크'

# 실제 네트워크 대신 API/다운로드를 모의한다.
$script:NetworkMode = 'release'; $script:Calls = 0
$candidateHash = $hash
$release = [pscustomobject]@{id=123;draft=$false;prerelease=$false;tag_name='v1.4.9';assets=@(
    [pscustomobject]@{id=1;name='ESDE-Sync-v1.4.9.zip';state='uploaded';size=(Get-Item $normal).Length;digest=('sha256:'+$hash);browser_download_url='https://github.com/dhlim89/ESDE-Sync-for-Windows/releases/download/v1.4.9/ESDE-Sync-v1.4.9.zip'},
    [pscustomobject]@{id=2;name='ESDE-Sync-v1.4.9.zip.sha256';state='uploaded';size=100;browser_download_url='https://github.com/dhlim89/ESDE-Sync-for-Windows/releases/download/v1.4.9/ESDE-Sync-v1.4.9.zip.sha256'})}
function Receive-UpdateResource([string]$Uri, [long]$MaxBytes, [string]$Destination) {
    $script:Calls++
    if ($script:NetworkMode -eq 'fail') { throw '모의 네트워크 실패' }
    if ($Uri.EndsWith('/latest')) { return ,[Text.Encoding]::UTF8.GetBytes(($release|ConvertTo-Json -Depth 5)) }
    if ($Destination) { Copy-Item -LiteralPath $script:DownloadZip -Destination $Destination; return }
    return ,[Text.Encoding]::UTF8.GetBytes($script:DownloadChecksum)
}
$candidate = Get-LatestStableRelease $info
Check ($candidate.Available -and $candidate.Version -eq '1.4.9') '최신 stable 조회(모의)'
$release.prerelease = $true
Reject 'prerelease' { Get-LatestStableRelease $info } 'stable'
$release.prerelease = $false; $release.draft = $true
Reject 'draft' { Get-LatestStableRelease $info } 'stable'
$release.draft = $false; $savedTag = $release.tag_name; $release.tag_name = 'v1.4.9-beta'
Reject 'Release tag' { Get-LatestStableRelease $info } '버전'
$release.tag_name = $savedTag
$savedDigest = $release.assets[0].digest; $release.assets[0].digest = $null
Reject 'Release digest 누락' { Get-LatestStableRelease $info } 'digest'
$release.assets[0].digest = $savedDigest
$script:NetworkMode = 'fail'
Reject '네트워크 실패' { Get-LatestStableRelease $info } '네트워크'
$script:NetworkMode = 'release'
$future = Clone-Info; $future.version='1.4.9'; $future.releaseTag='v1.4.9'
$script:DownloadZip = New-Fixture 'future' -TargetInfo $future
# README도 후보 버전에 맞춰야 하므로 이 fixture는 다운로드 완료 후 계약 실패해야 한다.
$futureHash = (Get-FileHash $script:DownloadZip).Hash.ToLowerInvariant()
$candidate.Zip.size = (Get-Item $script:DownloadZip).Length; $candidate.Zip.digest = 'sha256:'+$futureHash
$script:DownloadChecksum = $futureHash + '  ESDE-Sync-v1.4.9.zip'
Reject '검증만 수행하고 잘못된 README 거부' { Save-VerifiedUpdate $candidate $info (Join-Path $sandbox 'downloads') } 'README'
Check (@(Get-ChildItem (Join-Path $sandbox 'downloads') -Recurse -Filter '*.part').Count -eq 0) '실패한 부분 다운로드 정리'
$script:DownloadZip = New-Fixture 'future-valid' -TargetInfo $future -MatchReadme
$futureHash = (Get-FileHash $script:DownloadZip).Hash.ToLowerInvariant()
$candidate.Zip.size = (Get-Item $script:DownloadZip).Length; $candidate.Zip.digest = 'sha256:'+$futureHash
$script:DownloadChecksum = $futureHash + '  ESDE-Sync-v1.4.9.zip'
$saved = Save-VerifiedUpdate $candidate $info (Join-Path $sandbox 'verified-only')
Check ($saved.Verified -and (Test-Path $saved.ZipPath)) '다운로드부터 ZIP 검증 성공(모의)'
Check (@(Get-ChildItem (Join-Path $sandbox 'verified-only') -Recurse -Directory | Where-Object Name -eq 'App').Count -eq 0) 'App 추출/교체 없음'

# GUI 전체 실행이나 ADB 호출 없이 실제 Start-UpdateTask/runspace 동작을 확인한다.
$tokens=$null; $errors=$null
$guiAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'), [ref]$tokens, [ref]$errors)
$startFn = $guiAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-UpdateTask'}, $false)
. ([scriptblock]::Create($startFn.Extent.Text))
$stub = Join-Path $sandbox 'gui-common.ps1'
$stubText = @'
function Get-AppVersion { [pscustomobject]@{version='1.4.8'} }
function Get-LatestStableRelease { param($v) Start-Sleep -Milliseconds 100; [pscustomobject]@{Version='1.4.9';Available=$true} }
function Save-VerifiedUpdate { param($c,$v,$r) [pscustomobject]@{Verified=$true;Version='1.4.9';ZipPath='mock.zip'} }
'@
[IO.File]::WriteAllText($stub, $stubText, (New-Object Text.UTF8Encoding($true)))
$UpdateCommonPath=$stub; $VersionFile=Join-Path $repo 'version.json'; $AppRoot=$sandbox
$updateBtn=[pscustomobject]@{Enabled=$true}; $syncBtn=[pscustomobject]@{Enabled=$true}; $updateLabel=[pscustomobject]@{Text=''}
$script:UpdateTask=$null; $script:WorkerProcess=$null
Start-UpdateTask 'check' $null
Check ($syncBtn.Enabled -and -not $script:UpdateBusy) '비동기 확인 중 동기화 허용'
$asyncOutput = @($script:UpdateTask.PowerShell.EndInvoke($script:UpdateTask.Handle))
Check ($asyncOutput.Count -eq 1 -and $asyncOutput[0].Available) '비동기 Release 결과'
$script:UpdateTask.PowerShell.Dispose(); $script:UpdateTask=$null
$script:WorkerProcess=[pscustomobject]@{HasExited=$false}
Reject '동기화 중 다운로드' { Start-UpdateTask 'download' $candidate } '동기화'
$script:WorkerProcess=$null
Start-UpdateTask 'download' $candidate
Check (-not $syncBtn.Enabled -and $script:UpdateBusy) '다운로드 중 동기화 차단'
$asyncOutput = @($script:UpdateTask.PowerShell.EndInvoke($script:UpdateTask.Handle))
Check ($asyncOutput.Count -eq 1 -and $asyncOutput[0].Verified) '비동기 검증 결과'
$script:UpdateTask.PowerShell.Dispose(); $script:UpdateTask=$null
Write-Output ("업데이트 정적 검증 완료: $script:Passed 항목 / PowerShell " + $PSVersionTable.PSVersion)
Write-Output "모의 파일: $sandbox"
