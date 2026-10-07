param([string]$Version, [string]$GitPath = 'git', [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'update-common.ps1')
$info = Get-AppVersion (Join-Path $repo 'version.json')
if ($Version) {
    if ($Version -cne $info.version) { throw '지정 version과 version.json 불일치' }
}
else {
    $tag = & $GitPath -C $repo describe --tags --exact-match HEAD
    if ($LASTEXITCODE -ne 0 -or $tag -cne $info.releaseTag) { throw '현재 Git tag 불일치' }
    if (@(& $GitPath -C $repo status --porcelain).Count) { throw 'tag 패키징은 clean 작업 폴더 필요' }
}
if ((Get-Content (Join-Path $repo 'README.txt') -Encoding UTF8 -TotalCount 1) -cne ('ES-DE Sync for Android v' + $info.version + ' Development')) { throw 'README 버전 불일치' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$name = 'ESDE-Sync-v' + $info.version + '.zip'
$destination = Join-Path $OutputDirectory $name
$checksumPath = $destination + '.sha256'
if ((Test-Path $destination) -or (Test-Path $checksumPath)) { throw '기존 패키지는 덮어쓰지 않습니다' }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('esde-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $stage 'App') | Out-Null
$records = @()
foreach ($path in Get-PackageFiles) {
    $sourceName = if ($path.StartsWith('App/')) { $path.Substring(4) } else { $path }
    $source = Join-Path $repo $sourceName
    $target = Join-Path $stage $path
    Copy-Item -LiteralPath $source -Destination $target
    $records += [pscustomobject]@{path=$path;size=(Get-Item $target).Length;sha256=(Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()}
}
@{schemaVersion=1;version=$info.version;files=$records} | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding UTF8
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$partial = $destination + '.partial'
try {
    # .NET Framework의 CreateFromDirectory는 ZIP 이름에 역슬래시를 쓸 수 있다.
    # 계약 경로를 명시해 모든 entry를 '/'로 생성한다.
    $archive = [IO.Compression.ZipFile]::Open($partial, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($path in @(Get-PackageFiles) + @('package-manifest.json')) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $stage $path), $path)
        }
    }
    finally { $archive.Dispose() }
    [void](Test-UpdatePackage $partial $info.version $info)
    $hash = (Get-FileHash $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    Move-Item -LiteralPath $partial -Destination $destination
    [IO.File]::WriteAllText($checksumPath, ($hash + '  ' + $name + "`n"), (New-Object Text.UTF8Encoding($false)))
    [void](Assert-UpdateHashes $destination ([IO.File]::ReadAllText($checksumPath)) ('sha256:' + $hash) $name)
    Write-Output "패키지 검증 완료: $destination"
    Write-Output "SHA-256: $hash"
}
finally {
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
    # 생성한 임시 경로를 검증한 후 같은 PowerShell에서 정리한다.
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedStage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedStage -Leaf) -like 'esde-package-*') { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
}
