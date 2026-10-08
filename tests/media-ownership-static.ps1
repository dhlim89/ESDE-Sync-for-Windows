# 실제 worker 본문/ADB/설치본 없이 production media 함수와 메모리 Android를 검증한다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
$script:OriginalSave=${function:Save-MediaManifest}
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('esm-'+[guid]::NewGuid().ToString('N').Substring(0,8));[void](New-Item -ItemType Directory -Path $sandbox)
$selectedSystems=@('gb');$ReservedFolders=@('_TEST','_UNREGISTERED');$Serial='MOCK'
$Buckets=@(@{Remote='/storage/emulated/0/ROMs'},@{Remote='/storage/emulated/0/ES-DE/gamelists'},@{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$prefix='/storage/emulated/0/ES-DE/downloaded_media/gb/';$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Write-Log($Message){$script:Logs+=$Message}
function Invoke-Adb {
    $script:Calls+=($args-join' ');$reply=[pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}
    if($args[2]-eq'pull'){
        if($script:HashMode-eq'unknown'){$reply.Code=1;return $reply}
        [IO.File]::WriteAllText($args[4],$script:Remote[$args[3]],(New-Object Text.UTF8Encoding($false)));return $reply
    }
    if($args[2]-eq'push'){
        $script:Pushes++
        if($script:Pushes-eq$script:FailPushAt -or ($script:FailRollback -and $script:Pushes-gt$script:FailPushAt)){$reply.Code=1;return $reply}
        $script:Remote[$args[4]]=[IO.File]::ReadAllText($args[3])
        if($script:ConcurrentCreate){$script:Remote[$prefix+'a.png']=$script:Remote[$args[4]];$script:ConcurrentCreate=$false}
        return $reply
    }
    $cmd=[string]$args[3]
    if($cmd-match "-f '([^']+)'" -and $cmd.Contains('printf PRESENT')){$reply.StdOut=if($script:Remote.ContainsKey($matches[1])){'PRESENT'}else{'ABSENT'};return $reply}
    if($cmd-match "^(toybox )?sha256sum '([^']+)'$"){
        if($script:HashMode-in@('pull','unknown') -or ($script:HashMode-eq'toybox' -and -not$matches[1])){$reply.Code=127;return $reply}
        $path=$matches[2];$reply.StdOut=(Get-MediaTextHash $script:Remote[$path])+'  '+$path+"`n";return $reply
    }
    if($cmd-match "^mv -f '([^']+)' '([^']+)'$"){
        $script:Renames++;$script:Remote[$matches[2]]=$script:Remote[$matches[1]];[void]$script:Remote.Remove($matches[1])
        if($script:Renames-eq$script:FailRenameAfterAt){$reply.Code=1};return $reply
    }
    if($cmd-match "^rm -f '([^']+)'$"){[void]$script:Remote.Remove($matches[1]);return $reply}
    if($cmd.StartsWith('mkdir -p ')){return $reply}
    throw ('모의하지 않은 ADB 명령 '+$cmd)
}
function Get-RemoteFiles($Path){Assert-RemotePath $Path;@($script:Remote.Keys|Where-Object {$_.StartsWith($Path+'/')}|ForEach-Object {$_.Substring($Path.Length+1)}|Where-Object {-not(Is-ExcludedRelativePath $_)})}
function Get-RemoteDirs($Path){Assert-RemotePath $Path;return @()}
function Save-MediaManifest($Context,$Manifest){
    if($script:SaveFailure-eq'before'){$script:SaveFailure='';throw 'SAVE ORIGINAL'}
    & $script:OriginalSave $Context $Manifest
    if($script:SaveFailure-eq'after'){$script:SaveFailure='';throw 'SAVE AFTER COMMIT'}
}
function Setup([hashtable]$Source=@{},[hashtable]$Android=@{},[hashtable]$Managed=@{}){
    $dir=Join-Path $sandbox ([guid]::NewGuid().ToString('N').Substring(0,8));$global:SourceRoot=Join-Path $dir 'source';$script:State=Join-Path $dir 'State'
    $local=Join-Path $SourceRoot 'downloaded_media/gb';[void](New-Item -ItemType Directory -Path $local -Force)
    foreach($key in $Source.Keys){$path=Join-Path $local $key;[void](New-Item -ItemType Directory -Path (Split-Path $path) -Force);[IO.File]::WriteAllText($path,$Source[$key],(New-Object Text.UTF8Encoding($false)))}
    $script:Remote=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach($key in $Android.Keys){$script:Remote.Add($prefix+$key,$Android[$key])}
    $script:Calls=@();$script:Logs=@();$script:Pushes=0;$script:FailPushAt=0;$script:FailRollback=$false;$script:HashMode='native';$script:SaveFailure='';$script:Renames=0;$script:FailRenameAfterAt=0;$script:ConcurrentCreate=$false
    $script:Jobs=@([pscustomobject]@{System='gb';LocalPath=$local;RemotePath=$prefix.TrimEnd('/')})
    $script:Context=New-MediaContext $script:State $SourceRoot $Serial
    if($Managed.Count){
        $now=(Get-Date).ToUniversalTime().ToString('o');$manifest=$script:Context.Manifest
        foreach($key in $Managed.Keys){$hash=Get-MediaTextHash $Managed[$key];$manifest.entries+=[pscustomobject]@{system='gb';relativePath=$key;sourceSha256=$hash;deployedSha256=$hash;sourceSize=[Text.Encoding]::UTF8.GetByteCount($Managed[$key]);deployedAt=$now;lastVerifiedAt=$now}}
        & $script:OriginalSave $script:Context $manifest
        Close-MediaSession $script:Context
        $script:Context=New-MediaContext $script:State $SourceRoot $Serial
    }
    $script:Sources=@(Get-MediaSourceFiles $script:Jobs $script:Context)
}
function Run { $plan=Prepare-MediaPlan $script:Jobs $script:Sources $script:Context;Invoke-MediaTransaction $plan $script:Context;Close-MediaSession $script:Context }
function RejectRun($name){$errorMessage='';try{Run}catch{$errorMessage=$_.Exception.Message};Check ([bool]$errorMessage) ($name+' 차단');return $errorMessage}
function Manifest {Get-Content -LiteralPath $script:Context.ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json}
function Mutations {return @($script:Calls|Where-Object {$_-match' push | shell (mv -f|rm -f|mkdir)'})}
Setup @{} @{'local.png'='LOCAL'};Run
Check ($script:Remote[$prefix+'local.png']-ceq'LOCAL' -and (Manifest).entries.Count-eq0) 'manifest 없음: 기존 Android-only unmanaged 보존'
Setup @{'a.png'='NEW'};Run
Check ($script:Remote[$prefix+'a.png']-ceq'NEW' -and (Manifest).entries.Count-eq1) 'source 신규 배포/managed 등록'
Setup @{'a.png'='SAME'} @{'a.png'='SAME'};Run
Check ((Manifest).entries.Count-eq0 -and (Mutations).Count-eq0) 'unmanaged 동일 SHA no-op/자동 승격 없음'
Setup @{'a.png'='SOURCE'} @{'a.png'='USER'};$null=RejectRun 'unmanaged collision'
Check ($script:Remote[$prefix+'a.png']-ceq'USER' -and (Mutations).Count-eq0) 'unmanaged 충돌 보존'
Setup @{'a.png'='SAME'} @{'a.png'='SAME'} @{'a.png'='SAME'};Run
Check ((Manifest).entries.Count-eq1 -and (Mutations).Count-eq0) 'managed 동일 source no-op'
Setup @{'a.png'='NEW'} @{'a.png'='OLD'} @{'a.png'='OLD'};Run
Check ($script:Remote[$prefix+'a.png']-ceq'NEW' -and (Manifest).entries[0].deployedSha256-ceq(Get-MediaTextHash 'NEW')) 'managed unchanged 안전 update/manifest 갱신'
Setup @{'a.png'='NEW'} @{'a.png'='USER'} @{'a.png'='OLD'};$null=RejectRun 'managedModified'
Check ($script:Remote[$prefix+'a.png']-ceq'USER' -and (Manifest).entries[0].deployedSha256-ceq(Get-MediaTextHash 'OLD')) 'managedModified 덮어쓰기 없음/이전 hash 유지'
Setup @{} @{'a.png'='OLD'} @{'a.png'='OLD'};Run
Check (-not$script:Remote.ContainsKey($prefix+'a.png') -and (Manifest).entries.Count-eq0) 'managed source 삭제/entry 제거'
Setup @{} @{'a.png'='USER'} @{'a.png'='OLD'};$null=RejectRun '삭제 대상 사용자 수정'
Check ($script:Remote[$prefix+'a.png']-ceq'USER') '수정된 managed 삭제 금지'
Setup @{} @{} @{'a.png'='OLD'};Run;Check ((Manifest).entries.Count-eq0) 'Android도 없음: stale entry 정리'
foreach($mode in @('json','identity','sourceIdentity','duplicate','path','schema','missing','size','stamp')){
    Setup @{'a.png'='NEW'} @{'a.png'='OLD'} @{'a.png'='OLD'};Close-MediaSession $script:Context
    $manifest=Manifest
    switch($mode){
        'json' {[IO.File]::WriteAllText($script:Context.ManifestPath,'{broken')}
        'identity' {$manifest.deviceSerial='OTHER'}
        'sourceIdentity' {$manifest.sourceIdentity='0'*64}
        'duplicate' {$manifest.entries+=($manifest.entries[0])}
        'path' {$manifest.entries[0].relativePath='../escape.png'}
        'schema' {$manifest.schemaVersion=99}
        'missing' {$manifest.entries[0].PSObject.Properties.Remove('deployedSha256')}
        'size' {$manifest.entries[0].sourceSize=$true}
        'stamp' {$manifest.entries[0].lastVerifiedAt='invalid'}
    }
    if($mode-ne'json'){[IO.File]::WriteAllText($script:Context.ManifestPath,($manifest|ConvertTo-Json -Depth 6))}
    $blocked=$false;try{New-MediaContext $script:State $SourceRoot $Serial|Out-Null}catch{$blocked=$true}
    Check ($blocked -and (Mutations).Count-eq0) ('manifest '+$mode+' mutation 0')
}
Setup @{'a.png'='NEW'};$script:FailPushAt=1;$null=RejectRun '신규 push 실패'
Check (-not$script:Remote.ContainsKey($prefix+'a.png') -and -not(Test-Path $script:Context.ManifestPath)) '실패 신규 등록 없음'
Setup @{'a.png'='NEW-A';'b.png'='NEW-B'} @{'a.png'='OLD-A';'b.png'='OLD-B'} @{'a.png'='OLD-A';'b.png'='OLD-B'}
$before=(Get-FileHash $script:Context.ManifestPath).Hash;$script:FailPushAt=2;$null=RejectRun '두 번째 update 실패'
Check ($script:Remote[$prefix+'a.png']-ceq'OLD-A' -and $script:Remote[$prefix+'b.png']-ceq'OLD-B' -and (Get-FileHash $script:Context.ManifestPath).Hash-ceq$before) '역순 update rollback/manifest 원본 유지'
Setup @{'b.png'='NEW'} @{'a.png'='OLD'} @{'a.png'='OLD'};$script:FailPushAt=1;$null=RejectRun 'delete 이후 배포 실패'
Check ($script:Remote[$prefix+'a.png']-ceq'OLD') 'managed delete rollback 복원'
Setup @{'a.png'='NEW-A';'b.png'='NEW-B'} @{'a.png'='OLD-A'} @{'a.png'='OLD-A'};$script:FailPushAt=2;$script:FailRollback=$true;$message=RejectRun 'rollback 실패'
Check ($message-match'FATAL' -and (Get-Content (Join-Path $script:Context.Session 'journal.json') -Raw|ConvertFrom-Json).state-eq'rollback_failed') 'rollback 실패 fatal/backup journal 보존'
$blocked=$false;try{New-MediaContext $script:State $SourceRoot $Serial|Out-Null}catch{$blocked=$true};Check $blocked '미복구 transaction 다음 sync 차단'
foreach($mode in @('before','after')){
    Setup @{'a.png'='NEW'} @{'a.png'='OLD'} @{'a.png'='OLD'};$before=(Get-FileHash $script:Context.ManifestPath).Hash;$script:SaveFailure=$mode;$null=RejectRun ('manifest save '+$mode)
    Check ($script:Remote[$prefix+'a.png']-ceq'OLD' -and (Get-FileHash $script:Context.ManifestPath).Hash-ceq$before) ('manifest save '+$mode+' 실패 Android/State rollback')
}
Setup @{} @{'fanart/와리오.jpg'='A';'manuals/와리오.pdf'='B';'marquees/Poketto Hiro.png'='C';'marquees/명탐정.png'='D'};Run
Check ($script:Remote.Count-eq4 -and (Mutations).Count-eq0) 'Android-only 4개 삭제 0'
Setup @{} @{'local.png'='LOCAL'};Remove-Item -LiteralPath $script:Jobs[0].LocalPath;Run
Check ($script:Remote.Count-eq1 -and (Mutations).Count-eq0) 'source 시스템 폴더 부재: unmanaged 전체 보존'
Setup @{};$script:Jobs[0].System='gbc';$script:Jobs[0].RemotePath=$prefix.Replace('/gb/','/gbc/').TrimEnd('/');$null=RejectRun '미선택 시스템'
Check ((Mutations).Count-eq0) '미선택 시스템 변경 0'
Setup @{'covers/_TEST/a.png'='SOURCE';'_UNREGISTERED/a.png'='SOURCE'} @{'covers/_TEST/a.png'='USER';'_UNREGISTERED/a.png'='USER'};Run
Check ($script:Sources.Count-eq0 -and $script:Remote.Count-eq2 -and (Mutations).Count-eq0) '예약 구성요소 source 비교/전송/삭제 제외'
Setup @{'a.png'='NEW'} @{'a.png'='OLD'} @{'a.png'='OLD'};$script:HashMode='unknown';$null=RejectRun 'hash unknown'
Check ((Mutations).Count-eq0 -and $script:Remote[$prefix+'a.png']-ceq'OLD') 'unknown hash는 destructive 근거 아님'
foreach($mode in @('toybox','pull')){Setup @{'a.png'='SAME'} @{'a.png'='SAME'};$script:HashMode=$mode;Run;Check ((Mutations).Count-eq0 -and (Manifest).entries.Count-eq0) ($mode+' SHA fallback')}
Setup @{'a.png'='NEW'} @{'a.png'='OLD'} @{'a.png'='OLD'};$script:FailRenameAfterAt=1;$null=RejectRun 'rename 성공 후 응답 실패'
Check ($script:Remote[$prefix+'a.png']-ceq'OLD') 'rename 응답 불명확 시 검증 후 rollback'
Setup @{'a.png'='NEW';'b.png'='SOURCE'} @{'b.png'='USER'};$null=RejectRun '후반 unmanaged conflict'
Check (-not$script:Remote.ContainsKey($prefix+'a.png') -and (Mutations).Count-eq0) '전체 plan 충돌 검증 후 mutation 시작'
Setup @{'a.png'='SAME'} @{'a.png'='SAME'};$script:Remote.Add($prefix+'A.png','OTHER');Run
Check ($script:Remote.Count-eq2 -and (Manifest).entries.Count-eq0) 'Android case-sensitive key 유지'
Setup @{} @{};Run
Check ((Manifest).entries.Count-eq0 -and (Mutations).Count-eq0) '빈 source/Android migration managed set 비어 있음'
Setup @{'a.png'='OLD'} @{'a.png'='OLD'} @{'a.png'='OLD'};$before=Manifest;$time=$before.entries[0].deployedAt;Run
Check ((Manifest).entries[0].deployedAt-ceq$time) 'verify no-op은 deployedAt 보존'
Setup @{} @{};$ctx2=New-MediaContext $script:State $SourceRoot 'SECOND'
Check ($ctx2.ManifestPath-cne$script:Context.ManifestPath -and $ctx2.Manifest.entries.Count-eq0) '다른 기기의 기존 ownership 재사용 없음'
Close-MediaSession $ctx2
Close-MediaSession $script:Context
Check (-not@(Get-ChildItem -LiteralPath $script:Context.Session -Filter '*.source').Count) '준비 종료 source staging cleanup'
Setup @{} @{'covers/_TEST/a.png'='USER'};$blocked=$false
try{Get-MediaRemoteHash ($prefix+'covers/_TEST/a.png') $script:Context.Session|Out-Null}catch{$blocked=$true}
Check ($blocked -and $script:Calls.Count-eq0) '예약 media primitive hash 접근 차단'
$blocked=$false
try{Set-MediaRemoteFile '/storage/emulated/0/ROMs/gb/a.gb' 'unused' ('0'*64) $script:Context.Session|Out-Null}catch{$blocked=$true}
Check ($blocked -and $script:Calls.Count-eq0) 'media primitive가 ROM bucket에 쓰지 않음'
Setup @{'a.png'='NEW'};$script:ConcurrentCreate=$true;$null=RejectRun '전송 중 같은 SHA 외부 신규 파일 생성'
Check ($script:Remote[$prefix+'a.png']-ceq'NEW' -and -not(Test-Path $script:Context.ManifestPath)) 'rename하지 않은 외부 파일은 rollback 삭제/managed 등록 금지'
Write-Output ('media ownership 검증 완료: '+$script:Passed+' 항목 / PowerShell '+$PSVersionTable.PSVersion)
Write-Output ('fixture 위치: '+$sandbox)
