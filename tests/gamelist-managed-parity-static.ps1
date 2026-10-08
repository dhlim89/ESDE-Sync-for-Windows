$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Write-Log($Message){}
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
# 공백 서식을 제외하고 element/attribute/comment/text와 계층을 비교.
function Semantic($node){
    if($node.NodeType-in@([Xml.XmlNodeType]::Whitespace,[Xml.XmlNodeType]::SignificantWhitespace)){return ''}
    if($node.NodeType-eq[Xml.XmlNodeType]::Element){
        $attrs=@($node.Attributes|Sort-Object Name|ForEach-Object { $_.Name+'='+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Value)) })-join';'
        $children=@($node.ChildNodes|ForEach-Object {Semantic $_})-join''
        return '['+$node.Name+'{'+$attrs+'}'+$children+']'
    }
    return '['+$node.NodeType+':'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($node.Value))+']'
}
$folder=Join-Path $PSScriptRoot 'gamelist-policy'
$master=Read-EsdeGamelist (Join-Path $folder 'managed-master.xml')
$local=Read-EsdeGamelist (Join-Path $folder 'android-existing.xml')
$expected=Read-EsdeGamelist (Join-Path $folder 'expected-managed-android.xml')
$result=Get-AndroidBoundGamelist $master $local 'gb'
Check ((Semantic $result.Document.DocumentElement)-ceq(Semantic $expected.Document.DocumentElement)) '공통 managed parity fixture semantic 일치'
Check ($result.Document.DocumentElement.SelectNodes('gameList/game').Count-eq2) 'Android-only managed node 생성 없음'
$empty=ConvertFrom-EsdeGamelistBytes ([Text.Encoding]::UTF8.GetBytes('<alternativeEmulator empty="yes"/><gameList/>'))
$out=Get-AndroidBoundGamelist $master $empty 'gb'
Check ($out.Document.DocumentElement.SelectSingleNode('alternativeEmulator').OuterXml-ceq'<alternativeEmulator empty="yes" />') '명시적 empty alternativeEmulator 전체 보존'
$unmanaged=Merge-EsdeGamelist $master $local -PreservedUnmanagedPaths @('./ghost.gb')
Check ($unmanaged.Document.DocumentElement.SelectSingleNode('gameList/game[path="./ghost.gb"]').OuterXml-ceq$local.Document.DocumentElement.SelectSingleNode('gameList/game[path="./ghost.gb"]').OuterXml) '실제 unmanaged 경로 whole-node 보존'
Check ([Convert]::ToBase64String($master.Bytes)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $folder 'managed-master.xml')))) 'master 불변'
$ghost=$local.Document.DocumentElement.SelectSingleNode('gameList/game[path="./ghost.gb"]')
$alt=$local.Document.CreateElement('altemulator');$alt.InnerText='Mystery (Standalone)';[void]$ghost.AppendChild($alt)
$local.Bytes=ConvertTo-EsdeGamelistBytes $local
$preserved=Get-AndroidBoundGamelist $master $local 'gb' @('./ghost.gb')
Check ($preserved.Document.DocumentElement.SelectSingleNode('gameList/game[path="./ghost.gb"]').OuterXml-ceq$ghost.OuterXml) 'unmanaged whole-node emulator 변환도 제외'
$arcade=Get-AndroidBoundGamelist $master $null 'arcade'
Check ($arcade.Document.DocumentElement.SelectSingleNode('gameList/game[path="./a.gb"]/altemulator').InnerText-ceq'SameBoy (Standalone)') 'worker arcade game-level 그대로 유지'
$neo=Get-AndroidBoundGamelist $master $null 'neogeo'
Check ($neo.Document.DocumentElement.SelectSingleNode('gameList/game[path="./a.gb"]/altemulator').InnerText-ceq'SameBoy (Standalone)') '미확정 neogeo 변환 생략'
Write-Output ('managed parity 검증 완료: '+$script:Passed)