$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'update-common.ps1')
$info=Get-AppVersion (Join-Path $repo 'version.json')
$passed=0
function Check($ok,$name){if(-not$ok){throw $name};$script:passed++;Write-Output ('PASS: '+$name)}
Check ($info.version-ceq'1.8.0'-and$info.releaseTag-ceq'v1.8.0') 'production version/tag'
$prior=$info|ConvertTo-Json|ConvertFrom-Json
$prior.version='1.7.0';$prior.releaseTag='v1.7.0'
$name='ESDE-Sync-v1.8.0.zip'
$base='https://github.com/dhlim89/ESDE-Sync-for-Windows/releases/download/v1.8.0/'
$release=[pscustomobject]@{id=180;tag_name='v1.8.0';draft=$false;prerelease=$false;assets=@(
    [pscustomobject]@{name=$name;state='uploaded';size=100;digest=('sha256:'+('a'*64));browser_download_url=($base+$name)},
    [pscustomobject]@{name=($name+'.sha256');state='uploaded';browser_download_url=($base+$name+'.sha256')}
)}
Check ((ConvertTo-ReleaseCandidate $release $prior).Available) '1.7.0 to 1.8.0 update available'
Check (-not(ConvertTo-ReleaseCandidate $release $info).Available) '1.8.0 no update'
$release.prerelease=$true
$blocked=$false;try{ConvertTo-ReleaseCandidate $release $prior|Out-Null}catch{$blocked=$true}
Check $blocked 'invalid stable metadata fail closed'
Write-Output ('release version fixture '+$passed+' PASS')
