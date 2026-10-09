$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$null,[ref]$null)
$f=$ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq'Format-SyncCompletionMessage'},$false)[0]
. ([scriptblock]::Create($f.Extent.Text))
$n=0
function Check($v,$name){if(-not$v){throw $name};$script:n++;'PASS: '+$name}
$s=[pscustomobject]@{ManagedCount=97;UnmanagedMoveCount=1;LocalOnlyCount=2;ReviewCount=0;Items=@()}
$t=Format-SyncCompletionMessage $s
Check ($t.Contains('관리 ROM: 97') -and $t.Contains('비관리 ROM 이동: 1') -and $t.Contains('로컬 전용: 2')) 'normal counts'
Check (-not$t.Contains('확인 필요 항목')) 'zero review hidden'
$s.ReviewCount=2;$s.Items=@([pscustomobject]@{System='gb';RelativePath='Foo.gb';Classification='MANAGED_CONFLICT';AndroidSha256=('a'*64)},[pscustomobject]@{System='gbc';RelativePath='Bar.gbc';Classification='MANAGED_PATH_MISMATCH';AndroidSha256=('b'*64)})
$t=Format-SyncCompletionMessage $s
Check ($t.Contains('확인 필요: 2') -and $t.Contains('gb/Foo.gb') -and $t.Contains('gbc/Bar.gbc')) 'review details'
Check ($t.Contains('세이브 보호') -and $t.Contains('리비전')) 'plain Korean reasons'
Check ($t-notmatch'MANAGED_|REVIEW|PRESERVE|[ab]{64}') 'no enum or SHA'
Check ($t-notmatch'동기화 실패') 'conflict is not failure'
Check ((Format-SyncCompletionMessage $null)-ceq'Android 동기화가 완료되었습니다.') 'old status compatibility'
$s.ReviewCount=8;$s.Items=@(1..8|ForEach-Object {[pscustomobject]@{System='gb';RelativePath=($_.ToString()+'.gb');Classification='AMBIGUOUS'}})
$t=Format-SyncCompletionMessage $s
Check ($t.Contains('그 외 3개') -and -not$t.Contains('gb/8.gb')) 'bounded dialog details'
$source=[IO.File]::ReadAllText((Join-Path $repo 'ESDE-Sync.ps1'))
Check ($source.Contains('Format-SyncCompletionMessage $completionSummary') -and $source.Contains('동기화에 실패했습니다. 로그를 확인하세요.')) 'existing success/error separation'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
$f=$ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq'Write-Status'},$false)[0];. ([scriptblock]::Create($f.Extent.Text))
$StatusFile=Join-Path $env:TEMP ('gui-summary-'+[guid]::NewGuid().ToString('N')+'.json')
Write-Status done '동기화 완료' 1 1 $s
$r=Get-Content $StatusFile -Raw|ConvertFrom-Json
Check ($r.summary.ReviewCount-eq8 -and $r.state-ceq'done') 'worker status summary serialization'
Write-Status error '차단됨' 0 1
$r=Get-Content $StatusFile -Raw|ConvertFrom-Json
Check ($null-eq$r.summary -and $r.state-ceq'error') 'BLOCK error no stale summary'
Write-Output ('GUI summary 검증 완료: '+$n)