$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$script:Passed=0;function Check($ok,$name){if(-not$ok){throw $name};$script:Passed++;Write-Host ('PASS: '+$name)}
function Write-Log($m){}
function Write-Status($a,$b,$c,$d){}
function Invoke-Adb {throw 'actual Android prohibited'}
$root=Join-Path $env:TEMP ('duplicate binding 한글 (test) '+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
function Lifecycle($Work){& $Work}
function OldReproduction {
 $session=$root
 Lifecycle {$refresh={param($row)Get-DuplicateProductionSnapshot $session}.GetNewClosure();& $refresh $null}
}
function Get-DuplicateProductionSnapshot([string]$Session){
 if([string]::IsNullOrWhiteSpace($Session)){Join-Path $Session 'exact-empty-session-reproduction'|Out-Null}
 $global:BindingObservedSession=$Session
 return $global:BindingRows
}
function New-DuplicateProductionRows($snapshot){return $snapshot}
function New-DuplicateAdbAdapter($p,[string]$Session){
 if([string]::IsNullOrWhiteSpace($Session)){throw 'adapter session missing'}
 [pscustomobject]@{Session=$Session;SourcePath=('/storage/emulated/0/ROMs/'+$p.System+'/'+$p.SourceRelativePath);CanonicalPath=('/storage/emulated/0/ROMs/'+$p.System+'/'+$p.CanonicalRelativePath)}
}
function Invoke-EsdeSync($Work){& $Work}
function Invoke-DuplicateCleanupBatch($Selections,$Refresh,$Adapter,$Root,$Identity,$Device){
 foreach($row in $Selections){$p=& $Refresh $row;Assert-DuplicateDeleteScope $p;$io=& $Adapter $p
  Check (-not[string]::IsNullOrWhiteSpace($io.SourcePath)-and-not[string]::IsNullOrWhiteSpace($io.CanonicalPath)) 'bound adapter source canonical paths nonempty'
  Check ($p.SourceRelativePath-ceq$row.SourceRelativePath-and$p.CanonicalRelativePath-ceq$row.CanonicalRelativePath) 'selection lookup retains authoritative relative paths'
  Check ($io.Session-ceq$global:BindingObservedSession-and$io.Session.StartsWith($StateDir+'\')) 'refresh adapter evidence session same authorized State'
  Check ($p.Grade-cin@('SAFE_DELETE','SAFE_MERGE_DELETE')) 'grade unchanged before prepared'
 }
 return [pscustomobject]@{SafeDelete=0;SafeMergeDelete=0;Review=0;Failed=0;Unprocessed=0;Items=@()}
}
$caught=$null;try{OldReproduction}catch{$caught=$_}
Check ($null-ne$caught-and$caught.Exception.Message-match'Path') 'exact inherited session closure failure reproduced'
[IO.File]::WriteAllText((Join-Path $root 'old-stack.txt'),$caught.ScriptStackTrace,(New-Object Text.UTF8Encoding($true)))
$Operation='DuplicateCleanup';$SourceRoot=$root;$Serial='MOCK';$DuplicateRequestId=[guid]::NewGuid().ToString('N')
foreach($names in @(@('V180_SAFE_DELETE_TEST.gb|V180_SAFE_CANON.gb'),@('Old 1.gb|New 1.gb','옛 이름 (2).gb|새 이름 (2).gb'))){
 $StateDir=Join-Path $root ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($StateDir);$SelectionFile=Join-Path $StateDir '선택 파일 (1).json'
 $global:BindingRows=@();$ids=@();$index=0
 foreach($pair in $names){$parts=$pair.Split('|');$source='_UNREGISTERED/'+$parts[0];$id='gb:'+$source;$ids+=@($id)
  $global:BindingRows+=@([pscustomobject]@{Id=$id;System='gb';SourceRelativePath=$source;CanonicalRelativePath=$parts[1];ExpectedSha256=('a'*64);Grade=if($index-eq0){'SAFE_DELETE'}else{'SAFE_MERGE_DELETE'};CheckboxEnabled=$true;SelectionBinding='FIXTURE';Selected=$false});$index++
 }
 $identity=Get-DuplicateIdentity $SourceRoot $Serial
 @{schemaVersion=1;scanId='current';identity=$identity;serial=$Serial;rows=$global:BindingRows}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $StateDir 'duplicate-scan.json') -Encoding UTF8
 @{schemaVersion=1;scanId='current';identity=$identity;ids=$ids}|ConvertTo-Json -Depth 8|Set-Content $SelectionFile -Encoding UTF8
 $parsed=Get-Content -LiteralPath $SelectionFile -Raw -Encoding UTF8|ConvertFrom-Json
 Check (@($parsed.ids).Count-eq$names.Count) 'single multi selection JSON count retained'
 Invoke-DuplicateWorkerOperation
 Check (-not(Test-Path -LiteralPath (Join-Path $StateDir 'duplicate-cleanup'))) 'dry binding never enters prepared journal'
 Check ((Get-Content -LiteralPath (Join-Path $StateDir 'duplicate-result.json') -Raw|ConvertFrom-Json).requestId-ceq$DuplicateRequestId) 'worker request response correlation retained'
}
foreach($field in @('SourceRelativePath','CanonicalRelativePath')){$p=$global:BindingRows[0].PSObject.Copy();$p.$field='';$err=$null;try{Assert-DuplicateDeleteScope $p}catch{$err=$_};Check ($err.Exception.Message-match'selection .* path missing') ($field+' explicit missing diagnostic')}
'EVIDENCE: '+$root
'PASS TOTAL: '+$script:Passed
