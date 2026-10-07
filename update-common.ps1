# Windows PowerShell 5.1용 업데이트 계약. 설치 폴더 교체 기능은 포함하지 않는다.
function ConvertTo-UpdateVersion([string]$Value) {
    if ($Value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "잘못된 버전: $Value" }
    return [version]$Value
}

function Assert-VersionContract($Info) {
    if ($null -eq $Info -or -not ($Info.schemaVersion -is [int] -or $Info.schemaVersion -is [long]) -or $Info.schemaVersion -ne 1) { throw '지원하지 않는 버전 schemaVersion' }
    foreach ($field in @('version','updaterVersion','minimumUpdaterVersion')) { [void](ConvertTo-UpdateVersion $Info.$field) }
    if ($Info.channel -cne 'stable' -or $Info.releaseTag -cne ('v' + $Info.version)) { throw '버전 channel/releaseTag 계약 불일치' }
    return $Info
}

function Get-AppVersion([string]$Path = (Join-Path $PSScriptRoot 'version.json')) {
    return Assert-VersionContract (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Compare-UpdateVersion([string]$Left, [string]$Right) {
    return (ConvertTo-UpdateVersion $Left).CompareTo((ConvertTo-UpdateVersion $Right))
}

function Get-PackageFiles {
    return @('App/ESDE-Sync.ps1','App/sync-worker.ps1','App/update-common.ps1','App/version.json',
        'App/esde-sync-icon-v141.ico','App/esde-sync-icon-v141.png',
        'install.ps1','install.cmd','uninstall.ps1','uninstall.cmd','README.txt')
}

function Assert-PackagePath([string]$Path, [bool]$Directory = $false) {
    if ($Directory) { $Path = $Path.TrimEnd('/') }
    if (-not $Path -or $Path -match '[\\:\x00-\x1f\x7f]|^/|//') { throw "잘못된 ZIP 경로: $Path" }
    foreach ($part in ($Path -split '/')) {
        if ($part -in @('','.','..') -or $part -match '[<>"|?*]|[ .]$' -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') { throw "안전하지 않은 ZIP 이름: $Path" }
    }
    return $Path
}

function Receive-UpdateResource([string]$Uri, [long]$MaxBytes, [string]$Destination) {
    $allowedHosts = @('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')
    $url = [uri]$Uri
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $response = $null; $inputStream = $null; $outputStream = $null
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            if ($url.Scheme -cne 'https' -or $url.UserInfo -or $url.Port -ne 443 -or $allowedHosts -notcontains $url.DnsSafeHost) { throw '허용되지 않은 다운로드 URL' }
            $request = [Net.HttpWebRequest]::Create($url)
            $request.UserAgent = 'ESDE-Sync-Updater'
            $request.Accept = 'application/vnd.github+json'
            $request.AllowAutoRedirect = $false
            $request.Timeout = 20000; $request.ReadWriteTimeout = 30000
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {
                $next = $response.Headers['Location']; $response.Dispose(); $response = $null
                if (-not $next -or $redirect -eq 5) { throw '다운로드 redirect 오류' }
                $url = New-Object Uri($url, $next)
                continue
            }
            if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt $MaxBytes) { throw 'HTTP 응답 또는 크기 제한 오류' }
            break
        }
        $inputStream = $response.GetResponseStream()
        if ($Destination) { $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        else { $outputStream = New-Object IO.MemoryStream }
        $buffer = New-Object byte[] 65536; $total = 0L
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) { throw '다운로드 크기 제한 초과' }
            $outputStream.Write($buffer, 0, $read)
        }
        if ($response.ContentLength -ge 0 -and $total -ne $response.ContentLength) { throw '다운로드 길이 불일치' }
        if (-not $Destination) { return ,$outputStream.ToArray() }
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function ConvertTo-ReleaseCandidate($Release, $CurrentVersion) {
    [void](Assert-VersionContract $CurrentVersion)
    if ($Release.draft -ne $false -or $Release.prerelease -ne $false -or $Release.tag_name -notmatch '^v(.+)$') { throw 'stable Release 계약 오류' }
    $target = $Matches[1]; [void](ConvertTo-UpdateVersion $target)
    $name = 'ESDE-Sync-v' + $target + '.zip'
    $zip = @($Release.assets | Where-Object { $_.name -ceq $name })
    $checksum = @($Release.assets | Where-Object { $_.name -ceq ($name + '.sha256') })
    if ($zip.Count -ne 1 -or $checksum.Count -ne 1 -or $zip[0].state -ne 'uploaded' -or $checksum[0].state -ne 'uploaded') { throw 'Release asset 누락/중복/미완료' }
    if ($zip[0].digest -cnotmatch '^sha256:[a-fA-F0-9]{64}$' -or $zip[0].size -le 0 -or $zip[0].size -gt 50MB) { throw 'Release digest/크기 오류' }
    foreach ($asset in @($zip[0], $checksum[0])) {
        $expected = 'https://github.com/dhlim89/ESDE-Sync-for-Windows/releases/download/' + $Release.tag_name + '/' + $asset.name
        if ($asset.browser_download_url -cne $expected) { throw 'Release asset URL 계약 오류' }
    }
    return [pscustomobject]@{Version=$target;ReleaseTag=$Release.tag_name;ReleaseId=$Release.id;Zip=$zip[0];Checksum=$checksum[0];Available=((Compare-UpdateVersion $target $CurrentVersion.version) -gt 0)}
}

function Get-LatestStableRelease($CurrentVersion) {
    try {
        $bytes = Receive-UpdateResource 'https://api.github.com/repos/dhlim89/ESDE-Sync-for-Windows/releases/latest' 1MB
    }
    catch [Net.WebException] {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
    $release = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    return ConvertTo-ReleaseCandidate $release $CurrentVersion
}

function Assert-UpdateHashes([string]$ZipPath, [string]$ChecksumText, [string]$Digest, [string]$AssetName) {
    $text = $ChecksumText.TrimEnd("`r","`n")
    if ($text -notmatch '^([a-fA-F0-9]{64})  ([^\r\n]+)$') { throw 'checksum 형식 오류' }
    $expected = $Matches[1]; $name = $Matches[2]
    if ($name -cne $AssetName -or $Digest -cnotmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'checksum/digest 계약 오류' }
    $actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
    if ($actual -ine $expected -or $actual -ine $Digest.Substring(7)) { throw 'SHA-256/checksum/digest 불일치' }
    return $actual
}

function Read-PackageEntry($Entry, [long]$Limit, [bool]$KeepBytes) {
    $stream = $Entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
    $memory = $null; $total = 0L; $buffer = New-Object byte[] 65536
    if ($KeepBytes) { $memory = New-Object IO.MemoryStream }
    try {
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $count
            if ($total -gt $Limit -or $total -gt $Entry.Length) { throw 'ZIP 실제 전개 크기 제한/헤더 불일치' }
            [void]$sha.TransformBlock($buffer, 0, $count, $buffer, 0)
            if ($memory) { $memory.Write($buffer, 0, $count) }
        }
        if ($total -ne $Entry.Length) { throw 'ZIP 실제 파일 크기 불일치' }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return [pscustomobject]@{Hash=[BitConverter]::ToString($sha.Hash).Replace('-','');Bytes=$(if ($memory) { $memory.ToArray() } else { $null })}
    }
    finally { $stream.Dispose(); $sha.Dispose(); if ($memory) { $memory.Dispose() } }
}

function Test-UpdatePackage([string]$ZipPath, [string]$ExpectedVersion, $CurrentVersion,
    [long]$MaxZipBytes = 50MB, [long]$MaxExpandedBytes = 200MB, [int]$MaxEntries = 100) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ((Get-Item -LiteralPath $ZipPath).Length -gt $MaxZipBytes) { throw 'ZIP 크기 제한 초과' }
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($zip.Entries.Count -gt $MaxEntries) { throw 'ZIP 파일 수 제한 초과' }
        $seen = @{}; $files = @{}; $expanded = 0L
        $allowed = @(Get-PackageFiles) + @('package-manifest.json')
        foreach ($entry in $zip.Entries) {
            $directory = $entry.FullName.EndsWith('/')
            $path = Assert-PackagePath $entry.FullName $directory
            if ($seen.ContainsKey($path)) { throw "중복/대소문자 충돌: $path" }
            $seen[$path] = $true
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400)) { throw 'ZIP 링크 금지' }
            $expanded += $entry.Length
            if ($expanded -gt $MaxExpandedBytes) { throw 'ZIP 전개 크기 제한 초과' }
            if ($directory) {
                if ($path -cne 'App' -or $entry.Length -ne 0) { throw '허용되지 않은 ZIP 폴더' }
                continue
            }
            if ($allowed -cnotcontains $path) { throw "허용되지 않은 ZIP 파일: $path" }
            $files[$path] = $entry
        }
        foreach ($path in $allowed) { if (-not $files.ContainsKey($path)) { throw "필수 파일 누락: $path" } }
        $json = @{}; $entryData = @{}
        foreach ($path in $allowed) {
            $keep = $path -in @('package-manifest.json','App/version.json','README.txt')
            $limit = if ($keep) { [math]::Min(1MB, $MaxExpandedBytes) } else { $MaxExpandedBytes }
            $entryData[$path] = Read-PackageEntry $files[$path] $limit $keep
        }
        foreach ($path in @('package-manifest.json','App/version.json')) {
            $json[$path] = [Text.Encoding]::UTF8.GetString([byte[]]$entryData[$path].Bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
        }
        $version = Assert-VersionContract $json['App/version.json']
        if ($version.version -cne $ExpectedVersion) { throw 'Release/package 버전 불일치' }
        if ($CurrentVersion -and (Compare-UpdateVersion $CurrentVersion.updaterVersion $version.minimumUpdaterVersion) -lt 0) { throw '수동 설치가 필요한 updater 버전' }
        $manifest = $json['package-manifest.json']
        if (-not ($manifest.schemaVersion -is [int] -or $manifest.schemaVersion -is [long]) -or $manifest.schemaVersion -ne 1 -or $manifest.version -cne $ExpectedVersion -or $manifest.files -isnot [array]) { throw 'manifest 계약 오류' }
        $listed = @{}
        foreach ($record in @($manifest.files)) {
            $path = Assert-PackagePath $record.path
            if ($listed.ContainsKey($path) -or (Get-PackageFiles) -cnotcontains $path -or -not $files.ContainsKey($path)) { throw 'manifest 파일 목록 오류' }
            if (-not ($record.size -is [int] -or $record.size -is [long]) -or $record.size -ne $files[$path].Length -or $record.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'manifest 크기/해시 계약 오류' }
            $actual = $entryData[$path].Hash
            if ($actual -ine $record.sha256) { throw "manifest SHA-256 불일치: $path" }
            $listed[$path] = $true
        }
        if ($listed.Count -ne (Get-PackageFiles).Count) { throw 'manifest 파일 목록 불일치' }
        $readmeLine = ([Text.Encoding]::UTF8.GetString([byte[]]$entryData['README.txt'].Bytes).TrimStart([char]0xFEFF) -split '\r?\n')[0]
        if ($readmeLine -cne ('ES-DE Sync for Android v' + $version.version + ' Development')) { throw 'README 버전 불일치' }
        return [pscustomobject]@{Verified=$true;Version=$version.version;FileCount=$listed.Count;ExpandedBytes=$expanded}
    }
    finally { $zip.Dispose() }
}

function Save-VerifiedUpdate($Candidate, $CurrentVersion, [string]$DownloadRoot) {
    # API로 고정한 후보도 다운로드 직전에 계약을 재검증한다.
    $release = [pscustomobject]@{id=$Candidate.ReleaseId;tag_name=$Candidate.ReleaseTag;draft=$false;prerelease=$false;assets=@($Candidate.Zip,$Candidate.Checksum)}
    $candidate = ConvertTo-ReleaseCandidate $release $CurrentVersion
    if (-not $candidate.Available) { throw '현재 버전보다 새로운 Release가 아님' }
    $session = Join-Path $DownloadRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $session -Force | Out-Null
    $zipPath = Join-Path $session $candidate.Zip.name
    $partial = $zipPath + '.part'
    try {
        Receive-UpdateResource $candidate.Zip.browser_download_url 50MB $partial
        if ((Get-Item -LiteralPath $partial).Length -ne $candidate.Zip.size) { throw 'Release asset 크기 불일치' }
        $bytes = Receive-UpdateResource $candidate.Checksum.browser_download_url 4096
        $checksum = [Text.Encoding]::UTF8.GetString($bytes)
        [void](Assert-UpdateHashes $partial $checksum $candidate.Zip.digest $candidate.Zip.name)
        $result = Test-UpdatePackage $partial $candidate.Version $CurrentVersion
        Move-Item -LiteralPath $partial -Destination $zipPath
        return [pscustomobject]@{Verified=$true;Version=$result.Version;ZipPath=$zipPath}
    }
    finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
}
