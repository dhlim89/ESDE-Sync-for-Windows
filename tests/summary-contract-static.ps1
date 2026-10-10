$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
foreach($pair in @(@{File='sync-worker.ps1';Name='Write-Status'},@{File='ESDE-Sync.ps1';Name='Format-SyncCompletionMessage'})){
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $pair.File),[ref]$null,[ref]$null)
    $name=$pair.Name
    $f=$ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq$name},$false)[0]
    . ([scriptblock]::Create($f.Extent.Text))
}
$n=0
function Check($ok,$name){if(-not$ok){throw $name};$script:n++;'PASS: '+$name}
$StatusFile=Join-Path $env:TEMP ('summary-contract-'+[guid]::NewGuid().ToString('N')+'.json')
foreach($file in @(Get-ChildItem (Join-Path $PSScriptRoot 'gui-summary') -Filter '*-status.json')){
    $fixture=Get-Content $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
    $fields=@($fixture.summary.PSObject.Properties.Name)
    Check (-not@(@('ManagedCount','UnmanagedMoveCount','PromotedCount','LocalOnlyCount','ReviewCount')|Where-Object {$fields-cnotcontains$_}).Count) ($file.Name+' canonical fields')
    Write-Status done '동기화 완료' 1 1 $fixture.summary
    $saved=Get-Content $StatusFile -Raw -Encoding UTF8|ConvertFrom-Json
    $text=Format-SyncCompletionMessage $saved.summary
    Check ($text.Contains('관리 ROM: 97') -and $text.Contains('비관리 ROM 이동: 1') -and $text.Contains('로컬 전용: 2')) ($file.Name+' actual JSON roundtrip')
    Check ($text-notmatch'MANAGED_|AMBIGUOUS|[a-f0-9]{64}|동기화 실패') ($file.Name+' no technical/error text')
    if($fixture.summary.ReviewCount-eq0){Check (-not$text.Contains('확인 필요 항목')) 'normal details hidden'}
    elseif($fixture.summary.ReviewCount-gt5){Check ($text.Contains('그 외 3개') -and $text.Contains('Fixture-5.gb') -and -not$text.Contains('Fixture-6.gb')) 'eight reviews bounded to five'}
    else{Check ($text.Contains('확인 필요: 1') -and $text.Contains('Fixture-1.gb')) ($file.Name+' detail visible')}
}
$alias='Moved'+'ToUnregisteredCount'
foreach($path in @((Join-Path $repo 'sync-worker.ps1'),(Join-Path $repo 'ESDE-Sync.ps1'))){
    Check (-not[IO.File]::ReadAllText($path).Contains($alias)) 'no alias in runtime'
}
'summary contract 검증 완료: '+$n