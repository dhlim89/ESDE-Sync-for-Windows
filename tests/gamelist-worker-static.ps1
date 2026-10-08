# worker 함수만 로드하고 ADB 전체를 메모리 파일시스템으로 모의한다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
# runtime 함수의 단일 원본인 worker AST 정의만 로드한다. 본문은 실행하지 않는다.
$runtimeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($runtimeFunction in $runtimeAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){
    . ([scriptblock]::Create($runtimeFunction.Extent.Text))
}
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('ESDE-gamelist-worker-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $sandbox)
$SourceRoot=$sandbox;$Serial='MOCK';$selectedSystems=@('gb');$ReservedFolders=@('_TEST','_UNREGISTERED')
$Buckets=@(@{Remote='/storage/emulated/0/ROMs'},@{Remote='/storage/emulated/0/ES-DE/gamelists'},@{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
$remoteFile='/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml'
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Write-Log($Message){$script:Logs+=$Message};function Write-Status{}
function Preflight-CheckForeground{$script:Calls+='preflight'}
function Stop-Esde{$script:Stopped=$true;$script:Calls+='stop'}
function Start-Esde{$script:Stopped=$false;$script:Calls+='restart'}
function Invoke-Adb {
    $script:Calls+=(($args-join' ').Replace("`r"," ").Replace("`n"," "))
    $reply=[pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}
    if($args[2]-eq'pull'){
        if(-not$script:Stopped){throw 'ES-DE stop 전 pull'}
        if($script:Fail-eq'pull' -or ($script:Fail-eq'verify-pull' -and $args[3]-match'esde-sync-new')){$reply.Code=1;return $reply}
        [IO.File]::WriteAllText($args[4],$script:Remote[$args[3]],(New-Object Text.UTF8Encoding($false)));return $reply
    }
    if($args[2]-eq'push'){
        $script:Remote[$args[4]]=[IO.File]::ReadAllText($args[3])
        if($script:Fail-eq'corrupt'){$text=$script:Remote[$args[4]];$script:Remote[$args[4]]=$text.Substring(0,$text.Length-1)+'!'}
        if($script:Fail-eq'concurrent'){$script:Remote[$remoteFile]+="`n"}
        if($script:Fail-eq'push'){$reply.Code=1};return $reply
    }
    $cmd=[string]$args[3]
    if($cmd.Contains('printf PRESENT')){
        if($script:Fail-eq'exists'){$reply.Code=1;return $reply}
        if($cmd-match "-f '([^']+)'"){$path=$matches[1]}else{throw '모의 존재 명령 해석 실패'}
        $reply.StdOut=if($script:Remote.ContainsKey($path)){'PRESENT'}else{'ABSENT'};return $reply
    }
    if($cmd-match "^stat -c %s '([^']+)'$"){
        $reply.StdOut=[string][Text.Encoding]::UTF8.GetByteCount($script:Remote[$matches[1]])
        if($script:Fail-eq'stat'){$reply.StdOut='0'};return $reply
    }
    if($cmd-match "^mv -f '([^']+)' '([^']+)'$"){
        if($script:Fail-eq'mv'){$reply.Code=1;return $reply}
        $script:Remote[$matches[2]]=$script:Remote[$matches[1]];$script:Remote.Remove($matches[1]);return $reply
    }
    if($cmd-match "^rm -f '([^']+)'$"){$script:Remote.Remove($matches[1]);return $reply}
    if($cmd-match'^mkdir -p |^rmdir '){return $reply}
    throw ('허용하지 않은 ADB 명령 '+$cmd)
}
$normal='<game><path>./Normal.gb</path><name>Dropbox Normal</name></game>'
$test='<game custom="yes"><path>./_TEST/a.gb</path><favorite>true</favorite><unknown><child>한글</child></unknown><playcount>5</playcount></game>'
$unregistered='<game><path>./_UNREGISTERED/b.gb</path><desc>기존 설명</desc></game>'
$base='<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList>'+$normal+'</gameList><unknownTop keep="yes"/>'
$local='<gameList>'+($normal.Replace('Dropbox','Android'))+$test+$unregistered+'</gameList>'
function Setup($BaseText,$LocalText,$Failure=''){
    $script:Calls=@();$script:Logs=@();$script:Remote=@{};$script:Fail=$Failure;$script:Stopped=$false
    if($null-ne$LocalText){$script:Remote[$remoteFile]=$LocalText}
    $script:Remote['/storage/emulated/0/ES-DE/gamelists/gb/unknown.txt']='사용자 데이터'
    $dir=Join-Path $sandbox ([guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $dir)
    $source=Join-Path $dir 'gamelist.xml'
    if($null-ne$BaseText){[IO.File]::WriteAllText($source,$BaseText,(New-Object Text.UTF8Encoding($false)))}
    $script:Job=[pscustomobject]@{System='gb';LocalPath=$dir;RemotePath='/storage/emulated/0/ES-DE/gamelists/gb';GamelistSource=$null}
    $script:Session=Join-Path $dir 'session';[void](New-Item -ItemType Directory -Path $script:Session)
}
function Run {
    $script:Job.GamelistSource=Get-GamelistSource $script:Job.LocalPath
    Invoke-EsdeSync {$plan=Prepare-GamelistSystem $script:Job $script:Session;Sync-GamelistSystem $plan}
}
function RejectRun($name){$failed=$false;try{Run}catch{$failed=$true};Check $failed ($name+' 차단')}
function RemoteDocument {ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($script:Remote[$remoteFile]))}
Setup $base $local;Run;$doc=RemoteDocument
Check (@(Get-EsdeGameEntries $doc).Count-eq3) '둘 다 있음: 3개 병합 atomic replace'
Check (($script:Calls-join' ')-match'push .*mv -f') 'push 검증 후 mv 순서'
Check ($doc.Document.DocumentElement.SelectSingleNode('unknownTop').GetAttribute('keep')-eq'yes') 'unknown top-level 보존'
Check ($doc.Document.DocumentElement.SelectSingleNode('gameList/game[path="./_TEST/a.gb"]').OuterXml-ceq$test) '_TEST 전체 node 보존'
Check ($doc.Document.DocumentElement.SelectSingleNode('gameList/game[path="./_UNREGISTERED/b.gb"]').OuterXml-ceq$unregistered) '_UNREGISTERED 전체 node 보존'
Check ($doc.Document.DocumentElement.SelectSingleNode('gameList/game[path="./Normal.gb"]/name').InnerText-ceq'Dropbox Normal') '일반 metadata Dropbox 우선'
Check ($script:Remote['/storage/emulated/0/ES-DE/gamelists/gb/unknown.txt']-ceq'사용자 데이터') 'unknown 원격 파일 보존'
Check (-not@($script:Remote.Keys|Where-Object {$_-match'esde-sync-new'}).Count) '성공 후 remote temp 없음'
Check (($script:Calls-join' ')-match'stop.*pull.*push.*restart') 'stop 이후 pull/병합/전송 후 restart'
Setup $base $null;Run;Check ((RemoteDocument).Document.DocumentElement.SelectSingleNode('alternativeEmulator/label').InnerText-eq'SameBoy') 'Dropbox만 있음 전송'
Setup $null $local;Run;Check (@(Get-EsdeGameEntries (RemoteDocument)).Count-eq2) 'Android만 있음 local-only 보존'
Setup $null ('<gameList>'+($normal.Replace('Dropbox','Android'))+'</gameList>');Run
Check (-not$script:Remote.ContainsKey($remoteFile)) 'local-only 없음: gamelist.xml 단일 삭제'
Check (($script:Calls-join' ')-notmatch'rm -rf' -and $script:Remote.Count-eq1) '폴더/unknown 파일 삭제 금지'
Setup $null $null;Run;Check (($script:Calls-join' ')-notmatch'push|rm -f|mv -f|mkdir') '둘 다 없음 no-op'
Setup '<broken>' $local;RejectRun 'malformed Dropbox'
Check (($script:Calls-join' ')-notmatch'stop|push|rm -f|mv -f') 'Dropbox parse 실패는 stop/변경 전'
Setup $base '<broken>';RejectRun 'malformed Android';Check ($script:Remote[$remoteFile]-ceq'<broken>') 'Android XML 오류 원본 유지'
foreach($failure in @('pull','push','mv','stat','exists','verify-pull','corrupt')){
    Setup $base $local $failure;RejectRun $failure
    Check ($script:Remote[$remoteFile]-ceq$local) ($failure+' 실패 원본 유지')
    Check (-not@($script:Remote.Keys|Where-Object {$_-match'esde-sync-new'}).Count) ($failure+' 실패 temp cleanup')
}
Setup $base '<gameList><game><path>../escape.gb</path></game></gameList>';RejectRun 'invalid Android path'
Check (($script:Calls-join' ')-notmatch'push|rm -f|mv -f|mkdir') 'invalid path 원격 변경 전 차단'
Setup $base $local 'concurrent';RejectRun '동시 Android 변경'
Check ($script:Remote[$remoteFile]-ceq($local+"`n")) '동시 변경된 사용자 XML 덮어쓰기 금지'
Check (-not@($script:Remote.Keys|Where-Object {$_-match'esde-sync-new'}).Count) '동시 변경 차단 시 temp 정리'
Setup $base $local;$script:Job.RemotePath='/storage/emulated/0/ES-DE/gamelists/gbc';RejectRun '미선택 시스템'
Check ($script:Calls.Count-eq3) '미선택 시스템 원격 조회 없음 (preflight/stop/restart만)'
# 실행부 AST 순서 검사: 전체 source validation -> lifecycle -> 모든 gamelist 준비 -> 일반 job 변경.
$source=[IO.File]::ReadAllText((Join-Path $repo 'sync-worker.ps1'))
Check ($source.IndexOf('GamelistSource -NotePropertyValue (Get-GamelistSource')-lt$source.LastIndexOf('Invoke-EsdeSync {')) '전체 source 단계에 Dropbox parse 연결'
Check ($source.IndexOf('Prepare-GamelistSystem $job $gamelistSession')-lt$source.LastIndexOf('Sync-PreservedRomSystem $job')) '모든 Android 병합 준비가 ROM 변경보다 먼저'
Check ($source.IndexOf('Prepare-UnregisteredAdoptionSystem $romJob')-lt$source.LastIndexOf('Invoke-UnregisteredAdoptionTransaction $combined')) '모든 adoption 준비가 mutation보다 먼저'
Check ($source.IndexOf('Prepare-MediaPlan $mediaJobs')-lt$source.LastIndexOf('Invoke-UnregisteredAdoptionTransaction $combined')) 'media 검증도 adoption mutation보다 먼저'
Check ($source.Contains('[IO.Directory]::Delete($gamelistSession,$true)')) 'PC staging finally cleanup 연결'
Write-Output ('gamelist worker 검증 완료: '+$script:Passed+' 항목 / PowerShell '+$PSVersionTable.PSVersion)
