$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$worker=Join-Path $repo 'sync-worker.ps1';$gui=Join-Path $repo 'ESDE-Sync.ps1'
$wa=[Management.Automation.Language.Parser]::ParseFile($worker,[ref]$null,[ref]$null)
foreach($path in @($worker,$gui)){$a=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null);foreach($f in $a.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}}
$script:Passed=0;function Check($ok,$name){if(-not$ok){throw $name};$script:Passed++;'PASS: '+$name}
function Reject($body,$name){$hit=$false;try{& $body|Out-Null}catch{$hit=$true};Check $hit $name}
$root=Join-Path $env:TEMP ('duplicate CLI 한글 '+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$probe=Join-Path $root 'worker binding probe.ps1'
[IO.File]::WriteAllText($probe,($wa.ParamBlock.Extent.Text+"`n"+'[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{Operation=$Operation;SelectionFile=$SelectionFile;DuplicateRequestId=$DuplicateRequestId;SourceRoot=$SourceRoot;Serial=$Serial;AdbPath=$AdbPath;StateDir=$StateDir;AppRoot=$AppRoot}|ConvertTo-Json -Compress)))'),(New-Object Text.UTF8Encoding($true)))
$Worker=$probe;$StateDir=$root;$AppRoot=$root;$sourceBox=[pscustomobject]@{Text=$root};$deviceCombo=[pscustomobject]@{SelectedIndex=0};$script:Adb=Join-Path $root 'fake adb.exe';$script:Devices=@([pscustomobject]@{State='device';Serial='MOCK'});$syncBtn=[pscustomobject]@{Enabled=$true};$duplicateBtn=[pscustomobject]@{Enabled=$true};$updateBtn=[pscustomobject]@{Enabled=$true};$installUpdateBtn=[pscustomobject]@{Enabled=$true};$statusLabel=[pscustomobject]@{Text=''}
function Start-Process {param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)$script:Captured=$ArgumentList;[pscustomobject]@{Id=1}}
$names=@($wa.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})
Check (($names[0..4]-join',')-ceq'SourceRoot,Serial,AdbPath,StateDir,AppRoot') 'existing positional order unchanged'
foreach($mode in @('DuplicateScan','DuplicateCleanup')){
 $script:DuplicateProcess=$null;$script:WorkerProcess=$null
 $scan=[pscustomobject]@{serial='MOCK';sourceRoot=$root;scanId='scan';identity='identity'}
 Start-DuplicateTask $mode $scan @('gb:_UNREGISTERED/Old.gb')
 $emitted=@([regex]::Matches($script:Captured,'-(SourceRoot|Serial|AdbPath|StateDir|AppRoot|Operation|SelectionFile|DuplicateRequestId)\b')|ForEach-Object {$_.Groups[1].Value})
 Check (-not@($emitted|Where-Object {$_-cnotin$names}).Count) ($mode+' GUI parameters all declared')
 Check ('Operation'-cin$emitted-and'DuplicateRequestId'-cin$emitted) ($mode+' required GUI names present')
 Check (($mode-ceq'DuplicateScan'-and'SelectionFile'-cnotin$emitted)-or($mode-ceq'DuplicateCleanup'-and'SelectionFile'-cin$emitted)) ($mode+' selection contract')
 $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName='powershell.exe';$psi.Arguments=$script:Captured;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$out=$p.StandardOutput.ReadToEnd();$errorText=$p.StandardError.ReadToEnd();$p.WaitForExit();Check ($p.ExitCode-eq0) ($mode+' actual GUI CLI argument binding');$bound=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($out.Trim()))|ConvertFrom-Json;$p.Dispose()
 Check ($bound.Operation-ceq$mode-and$bound.DuplicateRequestId-ceq$script:DuplicateRequestId-and$bound.SourceRoot-ceq$root-and$bound.AdbPath-ceq$script:Adb) ($mode+' spaces Korean path request binding')
}
$encoded=& powershell.exe -NoProfile -File $probe $root MOCK $script:Adb $root $root; $bound=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.Trim()))|ConvertFrom-Json
Check ($LASTEXITCODE-eq0-and$bound.Operation-ceq'Sync') 'legacy positional CLI defaults Sync no new mandatory prompt'
$ErrorActionPreference='Continue'; $bad=& powershell.exe -NoProfile -File $probe -SourceRoot $root -Serial MOCK -AdbPath $script:Adb -StateDir $root -AppRoot $root -Operation Invalid 2>&1
$ErrorActionPreference='Stop'; Check ($LASTEXITCODE-ne0) 'unknown operation binding fail closed'
function Write-Log($m){}
function Invoke-EsdeSync {throw 'TEST: lifecycle/mutation must not start'}
$SourceRoot=$root;$Serial='MOCK';$Operation='DuplicateCleanup';$DuplicateRequestId='bad';$SelectionFile=$null
Reject {Invoke-DuplicateWorkerOperation} 'invalid duplicate request rejected'
$DuplicateRequestId='';Reject {Invoke-DuplicateWorkerOperation} 'empty duplicate request rejected'
$DuplicateRequestId=[guid]::NewGuid().ToString('N')
Reject {Invoke-DuplicateWorkerOperation} 'cleanup without selection fail closed'
$SelectionFile=Join-Path $root 'selection.json';[IO.File]::WriteAllText($SelectionFile,'{bad')
Reject {Invoke-DuplicateWorkerOperation} 'malformed selection fail closed'
$identity=Get-DuplicateIdentity $root MOCK
$scan=[pscustomobject]@{schemaVersion=1;scanId='current';identity=$identity;serial='MOCK';rows=@([pscustomobject]@{Id='test';System='gb';SourceRelativePath='_TEST/Old.gb';CanonicalRelativePath='New.gb';Grade='SAFE_DELETE';CheckboxEnabled=$true})}
$scan|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root 'duplicate-scan.json') -Encoding UTF8
@{schemaVersion=1;scanId='stale';identity=$identity;ids=@('test')}|ConvertTo-Json|Set-Content $SelectionFile -Encoding UTF8
Reject {Invoke-DuplicateWorkerOperation} 'stale scan selection identity rejected'
@{schemaVersion=1;scanId='current';identity=$identity;ids=@('test')}|ConvertTo-Json|Set-Content $SelectionFile -Encoding UTF8
Reject {Invoke-DuplicateWorkerOperation} 'TEST injected selection rejected before lifecycle'
Reject {Assert-DuplicateDeleteScope ([pscustomobject]@{System='gb';SourceRelativePath='_UNREGISTERED/../Old.gb';CanonicalRelativePath='New.gb';ExpectedSha256=('a'*64)})} 'traversal selection scope rejected'
$text=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'));Check ($text.Contains("if(`$Operation-cne'Sync'){Invoke-DuplicateWorkerOperation;exit 0}")) 'dispatch duplicate operations separate normal path'
$text=[IO.File]::ReadAllText($gui);Check ($text.Contains('$scan.requestId-cne$script:DuplicateRequestId')) 'GUI stale request response rejected'
Check (-not(Test-Path -LiteralPath (Join-Path $root 'duplicate-cleanup'))) 'invalid contract creates no cleanup journal'
'EVIDENCE: '+$root
'PASS TOTAL: '+$script:Passed
