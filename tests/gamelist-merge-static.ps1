# fixture만 사용한다. 실제 Android/ROM/Dropbox에는 접근하지 않는다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'gamelist-common.ps1')
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('esde-gamelist-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $sandbox)
$script:Passed=0
function Check($value,$name){if(-not$value){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$Work){$failed=$false;try{& $Work|Out-Null}catch{$failed=$true};Check $failed ($name+' 차단')}
function Fixture($name,$text,[bool]$Bom=$false){
    $path=Join-Path $sandbox ($name+'.xml')
    [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($Bom)))
    return Read-EsdeGamelist $path
}
function Game($path,$name){return '<game><path>'+$path+'</path><name>'+$name+'</name></game>'}
function Count($result){return @($result.Document.DocumentElement.SelectNodes('gameList/game')).Count}
function Node($result,$path){return @($result.Document.DocumentElement.SelectNodes('gameList/game')|Where-Object {(Get-EsdeGamePathInfo $_.SelectSingleNode('path').InnerText).Key-ceq$path})[0]}
$normal=(Game './One.gb' 'Dropbox One')+(Game './Folder/Two.gb' 'Dropbox Two')
$localNormal=(Game './One.gb' 'Android One')+(Game './Folder/Two.gb' 'Android Two')
$test=Game './_TEST/Test.gb' 'Local Test'
$unregistered=Game './_UNREGISTERED/Foo.gb' 'Local Unregistered'
$base=Fixture 'base' ('<?xml version="1.0" encoding="UTF-8"?>' + "`r`n"+'<alternativeEmulator><label>SameBoy</label></alternativeEmulator>'+"`r`n"+'<gameList>'+$normal+'</gameList>'+"`r`n"+'<customTop value="keep"/>') $true
$android=Fixture 'android-normal' ('<gameList>'+$localNormal+'</gameList>')
$result=Merge-EsdeGamelist $base $android
Check ((Count $result)-eq2 -and (Node $result './One.gb').SelectSingleNode('name').InnerText-ceq'Dropbox One') '일반 metadata는 Dropbox 우선'
Check ([Convert]::ToBase64String($result.Bytes)-ceq[Convert]::ToBase64String($base.Bytes)) 'local-only 없으면 원본 bytes 그대로'
$android=Fixture 'android-test' ('<gameList>'+$localNormal+$test+'</gameList>')
$result=Merge-EsdeGamelist $base $android
Check ((Count $result)-eq3 -and (Node $result './_TEST/Test.gb')) '_TEST 기존 엔트리 보존'
$android=Fixture 'android-unregistered' ('<gameList>'+$localNormal+$unregistered+'</gameList>')
Check ((Count (Merge-EsdeGamelist $base $android))-eq3) '_UNREGISTERED 기존 엔트리 보존'
$android=Fixture 'android-both' ('<gameList>'+$localNormal+$test+$unregistered+'</gameList>')
$result=Merge-EsdeGamelist $base $android
Check ((Count $result)-eq4) '두 예약 폴더 모두 보존'
$rich='<game id="custom"><path>./_TEST/Rich.gb</path><name>한글 &amp; &lt; &gt; &quot; 게임</name><desc><![CDATA[설명 & < > "내용"]]></desc><image>./media/local.png</image><thumbnail>thumb.png</thumbnail><marquee>marquee.png</marquee><video>clip.mp4</video><rating>0.8</rating><releasedate>20200101T000000</releasedate><developer>개발자</developer><publisher>배급사</publisher><genre>퍼즐</genre><players>1</players><favorite>true</favorite><playcount>8</playcount><lastplayed>20261008T090000</lastplayed><emulator>SameBoy</emulator><unknown a="&quot;">새 필드<child value="yes"/></unknown><!-- 사용자 주석 --></game>'
$richLocal=Fixture 'rich' ('<gameList>'+$rich+'</gameList>')
$result=Merge-EsdeGamelist $base $richLocal
Check ((Node $result './_TEST/Rich.gb').OuterXml-ceq(Node $richLocal './_TEST/Rich.gb').OuterXml) 'metadata/unknown/CDATA/주석/속성 전체 노드 보존'
$destination=Join-Path $sandbox 'roundtrip.xml'
Check (Write-EsdeGamelist $result $destination) '검증 후 새 임시 출력'
$roundtrip=Read-EsdeGamelist $destination
Check ((Node $roundtrip './_TEST/Rich.gb').SelectSingleNode('name').InnerText-ceq'한글 & < > " 게임') '한글/XML 특수문자 roundtrip'
Check ((Node $roundtrip './_TEST/Rich.gb').SelectSingleNode('unknown/child').GetAttribute('value')-ceq'yes') '중첩 사용자 정의 필드 보존'
Check ($roundtrip.Bom -and $roundtrip.Encoding.CodePage-eq65001 -and $roundtrip.Declaration-ceq$base.Declaration) 'UTF-8 BOM/declaration 보존'
Check ($roundtrip.Newline-ceq"`r`n") 'BASE CRLF 보존'
Check (($roundtrip.Document.DocumentElement.SelectNodes('*')|ForEach-Object Name)-join',' -ceq 'alternativeEmulator,gameList,customTop') 'sibling top-level ordering 보존'
Check ($roundtrip.Document.DocumentElement.SelectSingleNode('alternativeEmulator').OuterXml-ceq$base.Document.DocumentElement.SelectSingleNode('alternativeEmulator').OuterXml) 'Dropbox alternativeEmulator 유지'
$only=Merge-EsdeGamelist $null $android
Check ((Count $only)-eq2 -and -not(Node $only './One.gb')) 'BASE 없음: local-only만 보존'
$folderLocal=Fixture 'folder-only-base' ('<alternativeEmulator><label>Android SameBoy</label></alternativeEmulator><gameList><folder><path>./Normal</path><name>일반 폴더</name></folder>'+$test+'</gameList>')
$folderResult=Merge-EsdeGamelist $null $folderLocal
Check (-not$folderResult.Document.DocumentElement.SelectSingleNode('gameList/folder') -and (Count $folderResult)-eq1) 'BASE 없음: 일반 folder metadata도 승격하지 않음'
Check ($folderResult.Document.DocumentElement.SelectSingleNode('alternativeEmulator/label').InnerText-ceq'Android SameBoy') 'BASE 없음: Android top-level 구조 유지'
Check ($null-eq(Merge-EsdeGamelist $null $null)) '둘 다 없음: 출력 없음'
Check ($null-eq(Merge-EsdeGamelist $null (Fixture 'no-local' ('<gameList>'+$localNormal+'</gameList>')))) 'Android 일반 엔트리만 있으면 출력 없음'
$baseOnly=Merge-EsdeGamelist $base $null
Check ([Convert]::ToBase64String($baseOnly.Bytes)-ceq[Convert]::ToBase64String($base.Bytes)) 'Android 없음: Dropbox bytes 그대로'
Check ((Count (Merge-EsdeGamelist $base (Fixture 'empty' '<gameList/>')))-eq2) 'ROM 존재 여부와 무관하게 엔트리 생성 안 함'
$duplicate=Fixture 'duplicate' ('<gameList>'+$test+(Game '.\_TEST\Test.gb' '두 번째')+'</gameList>')
$result=Merge-EsdeGamelist $base $duplicate
Check ((Count $result)-eq3 -and $result.Warnings.Count-eq1) '정규화 key 중복 제거/첫 Android 항목 보존'
$conflict=Fixture 'conflict' ('<gameList>'+$normal+(Game './_TEST/Test.gb' 'Dropbox Local')+'</gameList>')
$script:Warnings=@();$result=Merge-EsdeGamelist $conflict $duplicate {param($message)$script:Warnings+=$message}
Check ((Count $result)-eq3 -and (Node $result './_TEST/Test.gb').SelectSingleNode('name').InnerText-ceq'Local Test') '동일 local-only path Android 우선'
Check (($script:Warnings-join' ')-match'Dropbox local-only.*local-only 충돌') 'Dropbox 예약 경로/충돌 warning'
foreach($path in @('../escape.gb','./a/../escape.gb','C:\foo.gb','/storage/emulated/0/foo.gb','\\server\foo.gb','././foo.gb','./a//foo.gb',"./bad`nname.gb",('./bad'+[char]0+'name.gb'),'./','')){Check ((Get-EsdeGamePathClass $path)-ceq'Invalid') ('Invalid path: '+$path.Replace("`n",'<LF>').Replace([string][char]0,'<NUL>'))}
foreach($case in @(@('./Game.gb','Managed'),@('./Folder/Game.gb','Managed'),@('./_TEST/Test.gb','LocalTest'),@('./_TEST/sub/Test.gb','LocalTest'),@('./_UNREGISTERED/Foo.gb','LocalUnregistered'),@('./_UNREGISTERED/sub/Foo.gb','LocalUnregistered'),@('./folder/_TEST/foo.gb','LocalTest'),@('./folder/_test/foo.gb','LocalTest'),@('Folder\_Unregistered\foo.gb','LocalUnregistered'))){Check ((Get-EsdeGamePathClass $case[0])-ceq$case[1]) ('경로 분류: '+$case[0])}
# worker의 예약 폴더 정책과 실제로 비교한다. worker 본문은 실행하지 않는다.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
$function=$ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq'Is-ExcludedRelativePath'},$false)[0]
. ([scriptblock]::Create($function.Extent.Text));$ReservedFolders=@('_TEST','_UNREGISTERED')
Check ((Is-ExcludedRelativePath 'folder/_test/foo.gb') -and (Get-EsdeGamePathClass './folder/_test/foo.gb')-eq'LocalTest') '기존 예약 정책 일치'
$caseLocal=Fixture 'case-path' ('<gameList>'+(Game './_TEST/foo.gb' 'small')+(Game './_TEST/Foo.gb' 'capital')+'</gameList>')
Check ((Count (Merge-EsdeGamelist $null $caseLocal))-eq2) 'Android 파일 key는 대소문자 구분'
$stale=Fixture 'stale' ('<gameList>'+(Game './_UNREGISTERED/NoRom.gb' 'stale metadata')+'</gameList>')
Check ((Count (Merge-EsdeGamelist $null $stale))-eq1) 'ROM 조회 없이 stale metadata 보존'
$lfBase=Fixture 'lf' ("<gameList>`n"+$normal+"`n</gameList>")
$lfResult=Merge-EsdeGamelist $lfBase $richLocal
Check ($lfResult.Newline-ceq"`n" -and (Node $lfResult './_TEST/Rich.gb').SelectSingleNode('desc').InnerText-ceq'설명 & < > "내용"') 'LF BASE/CRLF 혼합 의미 보존'
$utf16Path=Join-Path $sandbox 'utf16.xml'
[IO.File]::WriteAllText($utf16Path,('<?xml version="1.0" encoding="UTF-16"?><gameList>'+$normal+'</gameList>'),(New-Object Text.UnicodeEncoding($false,$true,$true)))
$utf16=Merge-EsdeGamelist (Read-EsdeGamelist $utf16Path) $richLocal
Check ($utf16.Encoding.CodePage-eq1200 -and $utf16.Bytes[0]-eq255 -and $utf16.Bytes[1]-eq254) 'UTF-16 BOM 보존'
$invalid=Fixture 'invalid-path' '<gameList><game><path>../escape.gb</path></game></gameList>'
Reject 'invalid path 병합' {Merge-EsdeGamelist $base $invalid}
Reject '중복 path 요소' {Merge-EsdeGamelist $base (Fixture 'paths' '<gameList><game><path>./_TEST/a.gb</path><path>./_TEST/b.gb</path></game></gameList>')}
Reject 'DTD/외부 entity' {Fixture 'entity' '<!DOCTYPE gameList [<!ENTITY x SYSTEM "file:///C:/secret">]><gameList>&x;</gameList>'}
Reject '복수 gameList' {Fixture 'many' '<gameList/><gameList/>'}
Reject 'encoding 불일치' {Fixture 'encoding' '<?xml version="1.0" encoding="UTF-16"?><gameList/>'}
$originalHash=(Get-FileHash $base.Source).Hash
Reject '잘못된 XML' {Fixture 'malformed' '<gameList><game></gameList>'}
Reject '원본 출력 덮어쓰기' {Write-EsdeGamelist $result $base.Source}
Check ((Get-FileHash $base.Source).Hash-ceq$originalHash) '오류 후 Dropbox fixture 원본 유지'
$localHash=(Get-FileHash $duplicate.Source).Hash
Reject 'Android fixture 덮어쓰기' {Write-EsdeGamelist $result $duplicate.Source}
Check ((Get-FileHash $duplicate.Source).Hash-ceq$localHash) '오류 후 Android fixture 원본 유지'
$tampered=Merge-EsdeGamelist $base $richLocal;$tampered.Bytes=[Text.Encoding]::UTF8.GetBytes('<broken>')
$badDestination=Join-Path $sandbox 'must-not-exist.xml'
Reject 'write-before-validate 금지' {Write-EsdeGamelist $tampered $badDestination}
Check (-not(Test-Path $badDestination)) '검증 실패 시 출력 파일 없음'
$tampered.Bytes=[Text.Encoding]::UTF8.GetBytes('<gameList><game><path>../escape.gb</path></game></gameList>')
Reject '출력 시 path 재검증' {Write-EsdeGamelist $tampered $badDestination}
Check (-not(Test-Path $badDestination)) '잘못된 경로 출력 없음'
Reject 'managed path라도 invalid Android metadata는 실패' {Merge-EsdeGamelist $base $invalid}
$dupBase=Fixture 'base-duplicate' ('<gameList>'+$normal+(Game 'One.gb' '중복')+'</gameList>')
Check ((Count (Merge-EsdeGamelist $dupBase $null))-eq2) 'Dropbox managed 중복 첫 항목 유지'
Check ((Count $base)-eq2 -and (Node $android './One.gb').SelectSingleNode('name').InnerText-ceq'Android One') '병합 후 양쪽 메모리 DOM 불변'
Check (-not(Write-EsdeGamelist $null (Join-Path $sandbox 'none.xml'))) '출력 없음 케이스 파일 미생성'
Write-Output ('gamelist 병합 검증 완료: '+$script:Passed+' 항목 / PowerShell '+$PSVersionTable.PSVersion)
Write-Output ('fixture 위치: '+$sandbox)
