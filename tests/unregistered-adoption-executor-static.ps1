$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$root=Join-Path ([IO.Path]::GetTempPath()) ('esa-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$work){$blocked=$false;try{& $work|Out-Null}catch{$blocked=$true;$script:LastError=$_.Exception.Message};Check $blocked ($name+' 차단')}
function Write-Log($m){$script:Logs+=$m}
function TextBytes($s){[Text.Encoding]::UTF8.GetBytes($s)}
function HashBytes($b){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($b)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Put($path,$text){$script:Remote[$path]=TextBytes $text}
function Invoke-Adb{
    $r=[pscustomobject]@{Code=0;StdOut='';StdErr='';Output=@()}
    $script:Calls+=($args-join' ')
    if($args[2]-eq'pull'){
        if($script:Fail-eq'pull'){$r.Code=1;return $r}
        if(-not$script:Remote.ContainsKey($args[3])){$r.Code=1;return $r}
        [IO.File]::WriteAllBytes($args[4],$script:Remote[$args[3]])
        return $r
    }
    if($args[2]-eq'push'){
        if($script:Fail-eq'android-rom' -and $args[4]-match'/ROMs/'){$r.Code=1;return $r}
        if($script:Fail-eq'android-xml' -and $args[4]-match'/gamelists/'){$r.Code=1;return $r}
        $script:Remote[$args[4]]=[IO.File]::ReadAllBytes($args[3])
        if($script:Fail-eq'android-sha' -and $args[4]-match'/ROMs/'){Put $args[4] 'corrupt'}
        return $r
    }
    $cmd=[string]$args[3]
    if($cmd-match"^(?:toybox )?sha256sum '([^']+)'$"){
        if($script:NativeMode-ceq'absent'){$r.Code=127;$r.StdErr='not found';return $r}
        $path=$matches[1]
        $hash=if($script:NativeMode-ceq'bad'){'0'*64}else{HashBytes $script:Remote[$path]}
        $r.StdOut=$hash+'  '+$path
        return $r
    }
    if($cmd-match'find .* -mindepth'){
        $prefix='/storage/emulated/0/ROMs/gb/_UNREGISTERED/'
        $r.StdOut=(@($script:Remote.Keys|Where-Object {$_.StartsWith($prefix)}|Sort-Object)-join[char]0)
        return $r
    }
    if($cmd.Contains('printf PRESENT')){
        $path=([regex]::Matches($cmd,"-f '([^']+)'"))[0].Groups[1].Value
        if($script:Links-ccontains$path){$r.Code=1;return $r}
        $r.StdOut=if($script:Remote.ContainsKey($path)){'PRESENT'}else{'ABSENT'}
        return $r
    }
    if($cmd-match"^stat -c %s '([^']+)'$"){$r.StdOut=[string]$script:Remote[$matches[1]].Length;return $r}
    if($cmd-match"^mv -[nf] '([^']+)' '([^']+)'$"){
        $from=$matches[1];$to=$matches[2]
        if($cmd.StartsWith('mv -n') -and $script:Remote.ContainsKey($to)){return $r}
        $script:Remote[$to]=$script:Remote[$from];$script:Remote.Remove($from);return $r
    }
    if($cmd-match"^rm -f '([^']+)'$"){
        if($script:Fail-eq'delete' -and $matches[1]-match'_UNREGISTERED'){$r.Code=1;return $r}
        $script:Remote.Remove($matches[1]);return $r
    }
    if($cmd-match'^mkdir -p '){return $r}
    throw ('예상 밖 mock ADB: '+$cmd)
}
$Serial='MOCK';$selectedSystems=@('gb');$ReservedFolders=@('_TEST','_UNREGISTERED')
$Buckets=@(@{Remote='/storage/emulated/0/ROMs'},@{Remote='/storage/emulated/0/ES-DE/gamelists'},@{Remote='/storage/emulated/0/ES-DE/downloaded_media'})
function Setup($path='_UNREGISTERED/new.gb',$metadata=$true){
    $case=Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0,8))
    $script:SourceRoot=Join-Path $case 'library'
    $state=Join-Path $case 'State';$session=Join-Path $case 'prepare'
    foreach($dir in @($state,$session,(Join-Path $SourceRoot 'roms/gb'),(Join-Path $SourceRoot 'gamelists/gb'))){[void][IO.Directory]::CreateDirectory($dir)}
    $script:Remote=@{};$script:Calls=@();$script:Logs=@();$script:Links=@();$script:NativeMode='valid';$script:Fail=''
    $script:Inbox='/storage/emulated/0/ROMs/gb/'+$path
    Put $Inbox 'ROM'
    Put '/storage/emulated/0/ROMs/gb/untouched.gb' 'USER ROM'
    $xml='<gameList><game><path>./_TEST/t.gb</path><name>test</name></game>'
    if($metadata){$xml+='<game><path>./'+$path+'</path><name>Adopt</name><desc>keep</desc><playcount>0</playcount><playtime/><lastplayed>20261008T000000</lastplayed></game>'}
    $xml+='</gameList>'
    Put '/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml' $xml
    $script:RomJob=[pscustomobject]@{System='gb';LocalPath=(Join-Path $SourceRoot 'roms/gb');RemotePath='/storage/emulated/0/ROMs/gb'}
    $script:XmlJob=[pscustomobject]@{System='gb';LocalPath=(Join-Path $SourceRoot 'gamelists/gb');RemotePath='/storage/emulated/0/ES-DE/gamelists/gb';GamelistSource=$null}
    $script:Context=New-AdoptionExecutorContext $state $SourceRoot $Serial $selectedSystems
    $script:Session=$session
    $script:XmlPlan=Prepare-GamelistSystem $XmlJob $session
}
function Prepare{Prepare-UnregisteredAdoptionSystem $RomJob $XmlJob $XmlPlan $Context $Session}
function ReadRemoteXml{ConvertFrom-EsdeGamelistBytes $script:Remote['/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml']}
Setup
$plan=Prepare
Check ($script:Remote.ContainsKey($Inbox) -and -not[IO.Directory]::Exists($Context.JournalRoot)) 'prepare mutation 없음'
$journal=Invoke-UnregisteredAdoptionTransaction $plan $Context
Check ($journal.completed -and $journal.state-ceq'completed') '신규 ROM adoption 완료'
Check (-not$script:Remote.ContainsKey($Inbox)) '모든 검증 후에만 inbox 삭제'
Check ($script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/new.gb')) 'Android canonical 배포'
Check ((Get-FileHash -LiteralPath (Join-Path $RomJob.LocalPath 'new.gb')).Hash.ToLowerInvariant()-ceq(HashBytes (TextBytes 'ROM'))) 'Dropbox ROM SHA 검증'
$shared=Read-EsdeGamelist (Join-Path $XmlJob.LocalPath 'gamelist.xml')
Check ($null-eq$shared.Document.DocumentElement.SelectSingleNode('gameList/game/playcount')) '공유본 runtime 복제 없음'
$android=ReadRemoteXml
Check ($android.Document.DocumentElement.SelectSingleNode('gameList/game[path="./new.gb"]/playcount').InnerText-ceq'0') 'Android runtime 0 유지'
Check ($android.Document.DocumentElement.SelectSingleNode('gameList/game[path="./new.gb"]/playtime').InnerText-ceq'') 'Android empty runtime 유지'
Check ($android.Document.DocumentElement.SelectNodes('gameList/game[path="./new.gb"]').Count-eq1) '승격 node 중복 없음'
Check ($script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/untouched.gb')) 'unrelated unmanaged ROM 보존'
Check (@($script:Remote.Keys|Where-Object {$_-match'esde-adoption|esde-sync-new'}).Count-eq0) 'Android temp 정리'
Check ([IO.File]::Exists((Join-Path $Context.JournalRoot ($journal.transactionId+'.json')))) 'journal 보존'
Check ($null-ne(New-AdoptionExecutorContext $Context.StateRoot $SourceRoot $Serial $selectedSystems)) 'completed journal 후 다음 준비 허용'
Setup '_UNREGISTERED/RPG/nested.gb'
$p=Prepare;[void](Invoke-UnregisteredAdoptionTransaction $p $Context)
Check ([IO.File]::Exists((Join-Path $RomJob.LocalPath 'RPG/nested.gb'))) 'nested 상대 구조 유지'
Setup '_UNREGISTERED/new.gb' $false
$p=Prepare;[void](Invoke-UnregisteredAdoptionTransaction $p $Context)
Check (-not[IO.File]::Exists((Join-Path $XmlJob.LocalPath 'gamelist.xml'))) 'existing game 없음 → shared synthetic game 없음'
Setup
[IO.File]::WriteAllText((Join-Path $RomJob.LocalPath 'new.gb'),'ROM')
$p=Prepare
Check ($p.Entries[0].DestinationHash-ceq(HashBytes (TextBytes 'ROM'))) '동일 SHA canonical 재사용 계획'
[void](Invoke-UnregisteredAdoptionTransaction $p $Context)
Check ((Get-FileHash -LiteralPath (Join-Path $RomJob.LocalPath 'new.gb')).Hash.ToLowerInvariant()-ceq(HashBytes (TextBytes 'ROM'))) '동일 SHA 목적지 unchanged'
Setup
[IO.File]::WriteAllText((Join-Path $RomJob.LocalPath 'new.gb'),'different')
Reject '다른 SHA 목적지 충돌' {Prepare}
Check ($script:Remote.ContainsKey($Inbox)) '충돌 inbox 보존'
foreach($unsafe in @('_UNREGISTERED/../escape.gb','_UNREGISTERED/CON.gb','_UNREGISTERED/not.txt')){
 Setup $unsafe $false
 Reject ($unsafe+' path/extension') {Prepare}
}
Setup '_TEST/a.gb' $false
Check ($null-eq(Prepare)) '_TEST inbox discovery 제외'
Setup
$sha=HashBytes (TextBytes 'ROM')
Reject 'case-insensitive 목적지 충돌' {New-UnregisteredAdoptionPlan @([pscustomobject]@{System='gb';RelativePath='_UNREGISTERED/new.gb';AndroidSha256=$sha;StagedSha256=$sha}) @([pscustomobject]@{System='gb';RelativePath='NEW.gb';Sha256=$sha},[pscustomobject]@{System='gb';RelativePath='new.gb';Sha256=$sha}) @('gb')}
Setup
$script:Remote['/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml']=TextBytes '<gameList><game><path>./_UNREGISTERED/new.gb</path><favorite>true</favorite></game></gameList>'
$XmlPlan=Prepare-GamelistSystem $XmlJob $Session
Reject 'preference 공유 미확정' {Prepare}
Setup
$script:Remote['/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml']=TextBytes '<gameList><game><path>./_UNREGISTERED/new.gb</path><image>local.png</image></game></gameList>'
$XmlPlan=Prepare-GamelistSystem $XmlJob $Session
Reject 'media 공유 미확정' {Prepare}
Setup
$script:Fail='pull'
Reject 'pull 실패' {Prepare}
foreach($failure in @('android-rom','android-sha','android-xml','delete')){
 Setup
 $p=Prepare;$script:Fail=$failure
 Reject ($failure+' executor 실패') {Invoke-UnregisteredAdoptionTransaction $p $Context}
 Check ($script:Remote.ContainsKey($Inbox)) ($failure+' inbox 보존')
 Reject ($failure+' 미완료 journal') {New-AdoptionExecutorContext $Context.StateRoot $SourceRoot $Serial $selectedSystems}
 Check (@(Get-ChildItem -LiteralPath $Context.JournalRoot -File -Filter '*.json').Count-eq1) ($failure+' journal 1개')
}
Setup
$p=Prepare
[IO.File]::WriteAllText((Join-Path $XmlJob.LocalPath 'gamelist.xml'),'<gameList/>')
Reject 'concurrent Dropbox XML' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check ($script:Remote.ContainsKey($Inbox)) 'Dropbox CAS 실패 원본 보존'
Setup
$p=Prepare
Put '/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml' '<gameList/>'
Reject 'concurrent Android XML' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check ($script:Remote.ContainsKey($Inbox)) 'Android CAS 실패 원본 보존'
Setup
$p=Prepare
[IO.File]::WriteAllText($p.Entries[0].StagedFile,'corrupt')
Reject 'staged SHA 변경' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check (-not[IO.Directory]::Exists($Context.JournalRoot)) 'stage SHA 실패 journal/mutation 이전 차단'
# PC 실패도 실제 TEMP filesystem 조건으로 유도하며 안전 기준은 약화하지 않는다.
Setup '_UNREGISTERED/RPG/new.gb'
$p=Prepare
[IO.File]::WriteAllText((Join-Path $RomJob.LocalPath 'RPG'),'not a directory')
Reject 'Dropbox ROM staging 실패' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check ($script:Remote.ContainsKey($Inbox)) 'Dropbox staging 실패 inbox 보존'
Setup
$master=Join-Path $XmlJob.LocalPath 'gamelist.xml'
[IO.File]::WriteAllText($master,'<gameList/>')
$XmlJob.GamelistSource=Read-EsdeGamelist $master
$XmlPlan=Prepare-GamelistSystem $XmlJob $Session
$p=Prepare
$lock=New-Object IO.FileStream($master,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try{Reject 'Dropbox gamelist atomic replace 실패' {Invoke-UnregisteredAdoptionTransaction $p $Context}}
finally{$lock.Dispose()}
Check ($script:Remote.ContainsKey($Inbox)) 'Dropbox gamelist 실패 inbox 보존'
Check ([IO.File]::ReadAllText($master)-ceq'<gameList/>') 'Dropbox gamelist 실패 기존 bytes 보존'
Setup
$p=Prepare
$p.Entries[0].System='gbc'
Reject 'selected system 밖 executor' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check ($script:Remote.ContainsKey($Inbox)) 'selected scope 실패 inbox 보존'
Setup
$p=Prepare
$p.Entries[0].AndroidPath='/storage/emulated/0/ROMs/gb/untouched.gb'
Reject 'canonical 경로 변조' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check ((HashBytes $script:Remote['/storage/emulated/0/ROMs/gb/untouched.gb'])-ceq(HashBytes (TextBytes 'USER ROM'))) '변조 plan에서 unrelated SHA 보존'
Setup
$ctxFolder=$Context.JournalRoot
[void][IO.Directory]::CreateDirectory($ctxFolder)
[IO.File]::WriteAllText((Join-Path $ctxFolder ('a'*32+'.json')),'{"schemaVersion":1}')
Reject '손상 journal' {New-AdoptionExecutorContext $Context.StateRoot $SourceRoot $Serial $selectedSystems}
Setup
$p=Prepare
$j=Invoke-UnregisteredAdoptionTransaction $p $Context
$states=@($j.history|ForEach-Object state)
Check (($states-join',')-ceq'staged,source-verified,dropbox-installed,gamelist-prepared,dropbox-gamelist-installed,android-rom-installed,android-gamelist-installed,android-source-removed,completed') '각 journal stage 기록 및 삭제 마지막'
# 기존 mirror는 수정하지 않고 호출 시 remote managed 범위만 제한됨을 검증.
Setup
[IO.File]::WriteAllText((Join-Path $RomJob.LocalPath 'managed.gb'),'MANAGED')
$script:ListedFiles=@('managed.gb','removed.gb','untouched.gb')
$script:ListedDirs=@('unmanaged-folder')
function Get-RemoteFiles($path){$script:ListedFiles}
function Get-RemoteDirs($path){$script:ListedDirs}
$rc=New-RomPreservationContext $Context.StateRoot $SourceRoot $Serial
$rc.Record.entries=@([pscustomobject]@{system='gb';relativePath='removed.gb'})
$rp=Prepare-RomPreservationPlan $RomJob $rc
Check ($rp.Unmanaged.Count-eq1 -and $rp.Unmanaged[0]-ceq'untouched.gb') 'ROM unmanaged 실제 목록 분류'
$productionMirror=(Get-Item Function:Mirror-SystemFolder).ScriptBlock
function Mirror-SystemFolder($local,$remote,$label){
    $script:ScopedFiles=@(Get-RemoteFiles $remote)
    $script:ScopedDirs=@(Get-RemoteDirs $remote)
}
Sync-PreservedRomSystem $RomJob $rp $rc 'mock ROM'
Check ($script:ScopedFiles-ccontains'managed.gb' -and $script:ScopedFiles-ccontains'removed.gb' -and $script:ScopedFiles-cnotcontains'untouched.gb') '기존 managed mirror 범위 유지 / unmanaged 삭제 목록 제외'
Check ($script:ScopedDirs.Count-eq0) 'unmanaged directory 제거 목록 제외'
Check (@(Get-RemoteFiles $RomJob.RemotePath).Count-eq3) 'wrapper 밖 공통 remote listing 불변'
Set-Item Function:Mirror-SystemFolder -Value $productionMirror
# 마지막 journal 저장 실패 시 이미 제거된 inbox만 SHA 검증 후 보상한다.
$productionWriter=(Get-Item Function:Write-MediaJson).ScriptBlock
Setup
$p=Prepare
function Write-MediaJson($path,$value,$stateRoot){
    if($value.state-ceq'completed'){throw 'injected final journal save failure'}
    & $productionWriter $path $value $stateRoot
}
Reject 'completed journal 저장 실패' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check ($script:Remote.ContainsKey($Inbox) -and (HashBytes $script:Remote[$Inbox])-ceq(HashBytes (TextBytes 'ROM'))) '최종 journal 실패 후 inbox SHA 복구'
Check ([IO.File]::Exists((Join-Path $RomJob.LocalPath 'new.gb'))) '실패 후 새 canonical 자동 삭제 없음'
Reject 'journal 저장 실패 다음 mutation' {New-AdoptionExecutorContext $Context.StateRoot $SourceRoot $Serial $selectedSystems}
Set-Item Function:Write-MediaJson -Value $productionWriter
# 다중 inbox의 두 번째 삭제 실패도 첫 번째 원본을 보상한다.
Setup
Put '/storage/emulated/0/ROMs/gb/_UNREGISTERED/second.gb' 'SECOND'
$p=Prepare
$productionDelete=(Get-Item Function:Remove-AdoptionInboxSource).ScriptBlock
$script:DeleteIndex=0
function Remove-AdoptionInboxSource($entry,$context,$session,$allVerified){
    $script:DeleteIndex++
    if($script:DeleteIndex-eq2){throw 'injected second cleanup failure'}
    & $productionDelete $entry $context $session $allVerified
}
Reject '두 번째 inbox 삭제 실패' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check ($script:Remote.ContainsKey($Inbox) -and $script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/_UNREGISTERED/second.gb')) '다중 cleanup 실패 모든 inbox 유지/보상'
Check ((HashBytes $script:Remote[$Inbox])-ceq(HashBytes (TextBytes 'ROM'))) '다중 cleanup 보상 SHA 일치'
Set-Item Function:Remove-AdoptionInboxSource -Value $productionDelete
Setup
[IO.File]::WriteAllText((Join-Path $RomJob.LocalPath 'NEW.gb'),'ROM')
$p=Prepare
$j=Invoke-UnregisteredAdoptionTransaction $p $Context
Check ($j.completed -and $script:Remote.ContainsKey('/storage/emulated/0/ROMs/gb/NEW.gb')) '동일 SHA 재사용 시 관리본 canonical 대소문자 유지'
Check ($null-ne(New-AdoptionExecutorContext $Context.StateRoot $SourceRoot $Serial $selectedSystems)) 'canonical 대소문자 재사용 journal 검증'
Setup
$script:Links=@($Inbox)
Reject 'Android symlink inbox' {Prepare}
Check ($script:Remote.ContainsKey($Inbox)) 'symlink 차단 원본 유지'
Setup
$p=Prepare
$p.Systems[0].SharedOutput | ForEach-Object {[IO.File]::WriteAllText($_,'<gameList/>')}
Reject 'prepared XML staging 변경' {Invoke-UnregisteredAdoptionTransaction $p $Context}
Check (-not[IO.Directory]::Exists($Context.JournalRoot)) 'XML staging 변조 mutation 전 차단'
Setup
$script:Remote['/storage/emulated/0/ES-DE/gamelists/gb/gamelist.xml']=TextBytes '<gameList><game><path>./_UNREGISTERED/new.gb</path><unknown>/storage/emulated/0/private</unknown></game></gameList>'
$XmlPlan=Prepare-GamelistSystem $XmlJob $Session
Reject 'unknown device-local path 공유' {Prepare}
Setup
$p=Prepare
$j=Invoke-UnregisteredAdoptionTransaction $p $Context
$jfile=Join-Path $Context.JournalRoot ($j.transactionId+'.json')
$j.identity='other'
Write-MediaJson $jfile $j $Context.StateRoot
Reject 'journal identity 변조' {New-AdoptionExecutorContext $Context.StateRoot $SourceRoot $Serial $selectedSystems}
Setup
$productionWriter=(Get-Item Function:Write-MediaJson).ScriptBlock
$p=Prepare
function Write-MediaJson($path,$value,$stateRoot){
    if($value.state-ceq'completed'){$script:Fail='android-rom';throw 'injected final save + recovery link loss'}
    & $productionWriter $path $value $stateRoot
}
# 원본 복원 push도 실패시키는 명시적 ADB fault.
$originalAdb=(Get-Item Function:Invoke-Adb).ScriptBlock
function Invoke-Adb{
    if($script:Fail-ceq'android-rom' -and $args[2]-eq'push' -and $args[4]-match'esde-adoption-restore'){
        return [pscustomobject]@{Code=1;StdOut='';StdErr='restore failure';Output=@()}
    }
    & $originalAdb @args
}
Reject 'cleanup 보상 전송도 실패' {Invoke-UnregisteredAdoptionTransaction $p $Context}
$failed=Get-Content (Join-Path $Context.JournalRoot '*.json') -Raw|ConvertFrom-Json
Check (@($failed.sourceRestoreErrors).Count-eq1 -and $failed.state-ceq'failed') '보상 실패 fatal journal 기록'
Check ([IO.File]::Exists($p.Entries[0].StagedFile) -and [IO.File]::Exists($p.Entries[0].DropboxPath)) '보상 불가 시 PC 원본/canonical 보존'
Set-Item Function:Invoke-Adb -Value $originalAdb
Set-Item Function:Write-MediaJson -Value $productionWriter
Setup
$script:NativeMode='bad'
Reject 'Android native/pull SHA 불일치' {Prepare}
Check ($script:Remote.ContainsKey($Inbox)) 'native SHA 불일치 mutation 없음'
Setup
$script:NativeMode='absent'
$p=Prepare
$j=Invoke-UnregisteredAdoptionTransaction $p $Context
Check ($j.completed) 'native/toybox 부재 pull hash fallback 성공'
Write-Output ('adoption executor 검증 완료: '+$script:Passed+' / fixture '+$root)