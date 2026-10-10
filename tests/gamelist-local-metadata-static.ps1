# AST로 production 순수 함수 정의만 로드한다. worker entrypoint/ADB/Dropbox는 실행하지 않는다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$work){$blocked=$false;try{& $work|Out-Null}catch{$blocked=$true};Check $blocked ($name+' 차단')}
function Doc($text){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($text))}
$base=Doc '<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>./a.gb</path><name>NEW</name><desc>새 설명</desc><playcount>2</playcount><lastplayed>20200101T000000</lastplayed><playtime>10</playtime><unknown>base</unknown></game></gameList>'
$local=Doc '<gameList><game><path>a.gb</path><name>OLD</name><desc>old</desc><playcount>39</playcount><lastplayed>20261006T225514</lastplayed><playtime>34755</playtime><favorite>true</favorite></game><game><path>./_TEST/t.gb</path><unknown custom="yes">한글</unknown><playcount>7</playcount></game><game><path>./_UNREGISTERED/u.gb</path><playtime>99</playtime></game></gameList>'
$baseBytes=[Convert]::ToBase64String($base.Bytes);$localBytes=[Convert]::ToBase64String($local.Bytes)
$result=Merge-EsdeGamelist $base $local
$game=$result.Document.DocumentElement.SelectSingleNode('gameList/game[path="./a.gb"]')
foreach($case in @(@('playcount','39'),@('lastplayed','20261006T225514'),@('playtime','34755'),@('name','NEW'),@('desc','새 설명'),@('unknown','base'))){Check ($game.SelectSingleNode($case[0]).InnerText-ceq$case[1]) ('tag-level '+$case[0])}
Check ($null-eq$game.SelectSingleNode('favorite')) '미확정 preference 정책을 임의 Android 우선으로 바꾸지 않음'
Check ($result.Document.DocumentElement.SelectSingleNode('alternativeEmulator/label').InnerText-ceq'SameBoy') 'top-level 보존'
Check ([Convert]::ToBase64String($base.Bytes)-ceq$baseBytes -and [Convert]::ToBase64String($local.Bytes)-ceq$localBytes) '두 입력 bytes 불변'
Check ($local.Document.DocumentElement.SelectSingleNode('gameList/game[path="a.gb"]/name').InnerText-ceq'OLD') '입력 DOM 불변'
foreach($path in @('./_TEST/t.gb','./_UNREGISTERED/u.gb')){Check ($result.Document.DocumentElement.SelectSingleNode('gameList/game[path="'+$path+'"]').OuterXml-ceq$local.Document.DocumentElement.SelectSingleNode('gameList/game[path="'+$path+'"]').OuterXml) ($path+' whole-node 보존')}
$none=Merge-EsdeGamelist $base (Doc '<gameList><game><path>./a.gb</path></game></gameList>')
Check ($none.Document.DocumentElement.SelectSingleNode('gameList/game/playcount').InnerText-ceq'2') 'Android tag 없음 → Dropbox 유지'
$zero=Merge-EsdeGamelist $base (Doc '<gameList><game><path>./a.gb</path><playcount>0</playcount><playtime>0</playtime><lastplayed/></game></gameList>')
Check ($zero.Document.DocumentElement.SelectSingleNode('gameList/game/playcount').InnerText-ceq'0') '0도 Android 우선'
Check ($zero.Document.DocumentElement.SelectSingleNode('gameList/game/lastplayed').InnerText-ceq'') '존재하는 빈 tag 보존'
$again=Merge-EsdeGamelist $base $result
Check ([Convert]::ToBase64String($again.Bytes)-ceq[Convert]::ToBase64String($result.Bytes)) '재병합 idempotency'
Reject '중복 runtime tag' {Merge-EsdeGamelist $base (Doc '<gameList><game><path>./a.gb</path><playcount>1</playcount><playcount>2</playcount></game></gameList>')}
Reject '중복 managed path' {Merge-EsdeGamelist $base (Doc '<gameList><game><path>./a.gb</path></game><game><path>a.gb</path></game></gameList>')}
Write-Output ('local metadata 검증 완료: '+$script:Passed)