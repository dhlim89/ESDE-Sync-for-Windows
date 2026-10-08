# AST로 production 순수 함수 정의만 로드한다. worker entrypoint/ADB/Dropbox는 실행하지 않는다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
function Reject($name,[scriptblock]$work){$blocked=$false;try{& $work|Out-Null}catch{$blocked=$true};Check $blocked ($name+' 차단')}
function Doc($text){ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes($text))}
function AltDoc($value,$path='./a.gb'){Doc ('<alternativeEmulator><label>SameBoy</label></alternativeEmulator><gameList><game><path>'+$path+'</path><altemulator>'+$value+'</altemulator><unknown>keep</unknown></game></gameList>')}
$source=AltDoc 'Sameboy (Standalone)'
$original=[Convert]::ToBase64String($source.Bytes)
foreach($system in @('gb','gbc')){
 $result=Convert-EsdeAndroidAltemulators $source $system $false
 Check ($result.Document.DocumentElement.SelectSingleNode('gameList/game/altemulator').InnerText-ceq'My OldBoy! (Standalone)') ($system+' confirmed mapping')
 Check ($result.Document.DocumentElement.SelectSingleNode('alternativeEmulator/label').InnerText-ceq'SameBoy') 'top-level와 game-level 구분'
 Check ($result.Document.DocumentElement.SelectSingleNode('gameList/game/unknown').InnerText-ceq'keep') 'unknown field 보존'
 $again=Convert-EsdeAndroidAltemulators $result $system $false
 Check ([Convert]::ToBase64String($again.Bytes)-ceq[Convert]::ToBase64String($result.Bytes)) 'Android 변환 재실행 유지'
}
Check ([Convert]::ToBase64String($source.Bytes)-ceq$original) 'Dropbox bytes 불변'
Check ($source.Document.DocumentElement.SelectSingleNode('gameList/game/altemulator').InnerText-ceq'Sameboy (Standalone)') 'Dropbox DOM 불변'
$removed=Convert-EsdeAndroidAltemulators (AltDoc 'SameBoy') 'gb' $false
Check ($null-eq$removed.Document.DocumentElement.SelectSingleNode('gameList/game/altemulator')) 'non-arcade 비Standalone 제거'
foreach($label in @('SameBoy','Mystery (Standalone)')){
 $arcade=AltDoc $label
 $out=Convert-EsdeAndroidAltemulators $arcade 'arcade' $true
 Check ([Convert]::ToBase64String($out.Bytes)-ceq[Convert]::ToBase64String($arcade.Bytes)) 'arcade 그대로 유지'
}
$script:Warnings=@()
Reject '미확정 mapping' {Convert-EsdeAndroidAltemulators (AltDoc 'Mystery (Standalone)') 'gb' $false -Warning {param($m)$script:Warnings+=$m}}
Check ($script:Warnings.Count-eq1) '미확정 mapping warning'
$local=AltDoc 'Unknown (Standalone)' './_TEST/a.gb'
Check ([Convert]::ToBase64String((Convert-EsdeAndroidAltemulators $local 'gb' $false).Bytes)-ceq[Convert]::ToBase64String($local.Bytes)) '예약 node 변환하지 않음'
Reject '중복 altemulator' {Convert-EsdeAndroidAltemulators (Doc '<gameList><game><path>./a.gb</path><altemulator>x</altemulator><altemulator>y</altemulator></game></gameList>') 'gb' $false}
Write-Output ('altemulator 검증 완료: '+$script:Passed)