param([string]$GitPath)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$PackageVersion=(Get-Content (Join-Path $repo 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json).version
$PackageTag='v'+$PackageVersion
$PackageName='ESDE-Sync-'+$PackageTag+'.zip'
if(-not$GitPath){
    $command=Get-Command git -ErrorAction SilentlyContinue
    if($command){$GitPath=$command.Source}
    else{
        $GitPath=@(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'esde-baseline-git-*'|ForEach-Object {Join-Path $_.FullName 'git/cmd/git.exe'}|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
    }
}
if(-not$GitPath){throw 'v1.4.8 tag 검증에 Git 경로가 필요합니다.'}
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('ESDE-v148-compat-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $sandbox)
# 패키징은 별도 프로세스에서 수행한다. 아래 validator scope에 최신 구현을 로드하지 않는다.
$output=& powershell.exe -NoProfile -File (Join-Path $repo 'scripts/package-release.ps1') -Version $PackageVersion -GitPath $GitPath -OutputDirectory $sandbox 2>&1
if($LASTEXITCODE-ne0){throw ($output|Out-String)}
$output|Write-Output
foreach($file in @('update-common.ps1','version.json')){
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$GitPath;$psi.Arguments='-C "'+$repo+'" show v1.4.8:'+$file
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$psi
    $destination=[IO.File]::Create((Join-Path $sandbox ('v148-'+$file)))
    try{
        [void]$process.Start();$process.StandardOutput.BaseStream.CopyTo($destination);$process.WaitForExit()
        if($process.ExitCode-ne0){throw 'v1.4.8 tag 파일 읽기 실패'}
    }finally{$destination.Dispose();$process.Dispose()}
    $tagBlob=& $GitPath -C $repo rev-parse ('v1.4.8:'+$file)
    $actualBlob=& $GitPath hash-object --no-filters (Join-Path $sandbox ('v148-'+$file))
    if($actualBlob-cne$tagBlob){throw '태그 validator bytes 불일치'}
}
. (Join-Path $sandbox 'v148-update-common.ps1')
$oldVersion=Get-AppVersion (Join-Path $sandbox 'v148-version.json')
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
Check ($oldVersion.version-ceq'1.4.8') '실제 tag v1.4.8 validator 로드'
$zipPath=Join-Path $sandbox $PackageName
$checksum=[IO.File]::ReadAllText($zipPath+'.sha256')
$hash=(Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$name=$PackageName
$release=[pscustomobject]@{id=1;draft=$false;prerelease=$false;tag_name=$PackageTag;assets=@(
    [pscustomobject]@{id=2;name=$name;state='uploaded';size=(Get-Item $zipPath).Length;digest=('sha256:'+$hash);browser_download_url=(('https://github.com/dhlim89/ESDE-Sync-for-Windows/releases/download/'+$PackageTag+'/')+$name)},
    [pscustomobject]@{id=3;name=($name+'.sha256');state='uploaded';browser_download_url=(('https://github.com/dhlim89/ESDE-Sync-for-Windows/releases/download/'+$PackageTag+'/')+$name+'.sha256')})}
$candidate=ConvertTo-ReleaseCandidate $release $oldVersion
Check ($candidate.Available -and $candidate.Version-ceq$PackageVersion) 'v1.4.8 asset/tag/digest 계약'
Check ((Assert-UpdateHashes $zipPath $checksum $candidate.Zip.digest $name)-ieq$hash) 'v1.4.8 SHA/checksum/digest 검증'
$verified=Test-UpdatePackage $zipPath $PackageVersion $oldVersion
Check $verified.Verified 'v1.4.8 manifest/ZIP 전체 검증'
$script:CompatZip=$zipPath;$script:CompatChecksum=$checksum
function Receive-UpdateResource([string]$Uri,[long]$MaxBytes,[string]$Destination){
    if($Destination){Copy-Item -LiteralPath $script:CompatZip -Destination $Destination;return}
    return ,[Text.Encoding]::UTF8.GetBytes($script:CompatChecksum)
}
$download=Save-VerifiedUpdate $candidate $oldVersion (Join-Path $sandbox 'mock-download')
Check ($download.Verified -and $download.Version-ceq$PackageVersion -and $download.Sha256-ieq$hash) '실제 v1.4.8 다운로드/검증 파이프라인 (네트워크만 모의)'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
try{
    $appFiles=@($zip.Entries|Where-Object {$_.FullName.StartsWith('App/') -and -not $_.FullName.EndsWith('/')}|ForEach-Object FullName|Sort-Object)
    $required=@(Get-PackageFiles|Where-Object {$_-like'App/*'}|Sort-Object)
    Check (-not@($appFiles|Where-Object {$required-cnotcontains$_}).Count) 'unknown App 파일 없음'
    Check (-not@($required|Where-Object {$appFiles-cnotcontains$_}).Count) 'required App 파일 누락 없음'
    Check ($appFiles-cnotcontains'App/gamelist-common.ps1') '별도 gamelist runtime 파일 없음'
    $reader=New-Object IO.StreamReader($zip.GetEntry('App/version.json').Open())
    try{$version=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    Check ($version.version-ceq$PackageVersion -and $version.releaseTag-ceq$PackageTag) '패키지 버전/releaseTag 일치'
    Check ((Assert-VersionContract $version) -and (Compare-UpdateVersion $oldVersion.updaterVersion $version.minimumUpdaterVersion)-ge0) 'updater/minimumUpdaterVersion 계약'
    $reader=New-Object IO.StreamReader($zip.GetEntry('App/sync-worker.ps1').Open())
    try{$worker=$reader.ReadToEnd()}finally{$reader.Dispose()}
    $ast=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$null,[ref]$null)
    $functions=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)|ForEach-Object Name)
    Check ($functions-contains'Merge-EsdeGamelist' -and $functions-contains'Sync-GamelistSystem' -and $functions-contains'Read-EsdeGamelist') 'worker 내 병합/연결 runtime 존재'
    Write-Output ('APP FILES: '+($appFiles-join', '))
}finally{$zip.Dispose()}
$badZip=Join-Path $sandbox 'unknown-runtime.zip'
Copy-Item -LiteralPath $zipPath -Destination $badZip
$archive=[IO.Compression.ZipFile]::Open($badZip,[IO.Compression.ZipArchiveMode]::Update)
try{
    $entry=$archive.CreateEntry('App/gamelist-common.ps1');$stream=$entry.Open()
    try{$stream.WriteByte(35)}finally{$stream.Dispose()}
}finally{$archive.Dispose()}
$rejected=$false
try{Test-UpdatePackage $badZip $PackageVersion $oldVersion|Out-Null}catch{$rejected=$true}
Check $rejected 'v1.4.8은 별도 gamelist runtime 추가 패키지를 여전히 거부'
Write-Output ('v1.4.8 호환 검증 완료: '+$script:Passed+' 항목 / PowerShell '+$PSVersionTable.PSVersion)
Write-Output ('패키지/원본 validator 위치: '+$sandbox)
