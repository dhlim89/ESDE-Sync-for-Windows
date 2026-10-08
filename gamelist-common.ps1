# 독립 metadata 병합 기반. ADB/ROM 탐색/원본 덮어쓰기 없이 사용한다.
function Get-EsdeGamePathInfo([string]$Path) {
    $invalid=[pscustomobject]@{Class='Invalid';Key=''}
    if([string]::IsNullOrEmpty($Path) -or $Path -match '[\x00-\x1f\x7f]'){return $invalid}
    $relative=$Path.Replace('\','/')
    if($relative.StartsWith('/') -or $relative.Contains(':')){return $invalid}
    if($relative.StartsWith('./')){$relative=$relative.Substring(2)}
    $parts=$relative.Split('/')
    if(@($parts|Where-Object {$_ -in @('','.', '..')}).Count){return $invalid}
    $class='Managed'
    foreach($part in $parts){
        # worker Is-ExcludedRelativePath와 동일하게 모든 구성요소를 대소문자 무시 비교한다.
        if($part -ieq '_TEST'){$class='LocalTest';break}
        if($part -ieq '_UNREGISTERED'){$class='LocalUnregistered';break}
    }
    return [pscustomobject]@{Class=$class;Key=('./'+($parts-join'/'))}
}

function Get-EsdeGamePathClass([string]$Path) { return (Get-EsdeGamePathInfo $Path).Class }

function ConvertFrom-EsdeGamelistBytes([byte[]]$Bytes,[string]$Source='memory') {
    if($Bytes.Length -gt 33554432){throw 'gamelist 크기 제한 초과'}
    $offset=0;$bom=$false
    $encoding=New-Object Text.UTF8Encoding($false,$true)
    if($Bytes.Length-ge3 -and $Bytes[0]-eq239 -and $Bytes[1]-eq187 -and $Bytes[2]-eq191){$offset=3;$bom=$true}
    elseif($Bytes.Length-ge2 -and $Bytes[0]-eq255 -and $Bytes[1]-eq254){$encoding=New-Object Text.UnicodeEncoding($false,$false,$true);$offset=2;$bom=$true}
    elseif($Bytes.Length-ge2 -and $Bytes[0]-eq254 -and $Bytes[1]-eq255){$encoding=New-Object Text.UnicodeEncoding($true,$false,$true);$offset=2;$bom=$true}
    $text=$encoding.GetString($Bytes,$offset,$Bytes.Length-$offset)
    $declaration=''
    # XML declaration만 분리한다. game 블록은 문자열/정규식으로 편집하지 않는다.
    $match=[regex]::Match($text,'\A<\?xml\s+[^?]*\?>')
    if($match.Success){$declaration=$match.Value;$text=$text.Substring($match.Length)}
    $settings=New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $settings.MaxCharactersInDocument=33554464
    $document=New-Object Xml.XmlDocument
    $document.PreserveWhitespace=$true;$document.XmlResolver=$null
    $stringReader=New-Object IO.StringReader ('<esdeWrapper>'+$text+'</esdeWrapper>')
    $reader=$null
    try{
        # declaration 자체도 XML parser로 검증한다.
        if($declaration){
            $probe=New-Object Xml.XmlDocument;$probe.XmlResolver=$null
            $probe.LoadXml($declaration+'<declarationCheck/>')
            $declEncoding=$probe.FirstChild.Encoding
            if($declEncoding -and $declEncoding -notmatch '^(utf-8|utf-16|utf-16le|utf-16be)$'){throw '지원하지 않는 XML encoding'}
            if($declEncoding -match '^utf-8$' -and $encoding.CodePage-ne65001){throw 'XML encoding/BOM 불일치'}
            if($declEncoding -match '^utf-16' -and $encoding.CodePage-notin@(1200,1201)){throw 'XML encoding/BOM 불일치'}
        }
        $reader=[Xml.XmlReader]::Create($stringReader,$settings);$document.Load($reader)
    }catch{throw ('gamelist XML 읽기 실패 ['+$Source+']: '+$_.Exception.Message)}
    finally{if($reader){$reader.Dispose()};$stringReader.Dispose()}
    $lists=@($document.DocumentElement.SelectNodes('gameList'))
    if($lists.Count-gt1){throw ('여러 gameList 요소: '+$Source)}
    $newline=if($text.Contains("`r`n")){"`r`n"}else{"`n"}
    return [pscustomobject]@{Document=$document;Bytes=$Bytes;Declaration=$declaration;Encoding=$encoding;Bom=$bom;Newline=$newline;Source=$Source}
}

function Read-EsdeGamelist([string]$Path) {
    if([string]::IsNullOrEmpty($Path)){return $null}
    if(-not[IO.File]::Exists($Path)){throw ('명시한 gamelist 파일이 없거나 읽을 수 없음: '+$Path)}
    if((New-Object IO.FileInfo $Path).Length-gt33554432){throw 'gamelist 크기 제한 초과'}
    return ConvertFrom-EsdeGamelistBytes ([IO.File]::ReadAllBytes($Path)) ([IO.Path]::GetFullPath($Path))
}

function Get-EsdeGameEntries($Gamelist,[scriptblock]$Warning) {
    if($null-eq$Gamelist){return}
    foreach($node in $Gamelist.Document.DocumentElement.SelectNodes('gameList/game')){
        $paths=@($node.SelectNodes('path'))
        if($paths.Count-ne1 -or @($paths[0].SelectNodes('*')).Count){
            if($Warning){& $Warning ('Invalid game path 구조: '+$Gamelist.Source)|Out-Null}
            throw 'game에 단일 텍스트 path가 필요합니다.'
        }
        $info=Get-EsdeGamePathInfo $paths[0].InnerText
        if($info.Class-eq'Invalid'){
            if($Warning){& $Warning ('Invalid game path: '+$paths[0].InnerText)|Out-Null}
            throw ('안전하지 않은 game path: '+$paths[0].InnerText)
        }
        [pscustomobject]@{Node=$node;Key=$info.Key;Class=$info.Class}
    }
}

function Get-LocalOnlyGameEntries($Gamelist,[scriptblock]$Warning) {
    Get-EsdeGameEntries $Gamelist $Warning|Where-Object {$_.Class -in @('LocalTest','LocalUnregistered')}
}

function ConvertTo-EsdeGamelistBytes($Gamelist) {
    $text=$Gamelist.Declaration+$Gamelist.Document.DocumentElement.InnerXml
    $text=$text.Replace("`r`n","`n").Replace("`n",$Gamelist.Newline)
    $bytes=$Gamelist.Encoding.GetBytes($text)
    if($Gamelist.Bom){
        $prefix=if($Gamelist.Encoding.CodePage-eq65001){[byte[]]@(239,187,191)}elseif($Gamelist.Encoding.CodePage-eq1200){[byte[]]@(255,254)}else{[byte[]]@(254,255)}
        $bytes=[byte[]]($prefix+$bytes)
    }
    # 출력 경로에 쓰기 전에 실제 저장할 바이트를 다시 파싱한다.
    [void](ConvertFrom-EsdeGamelistBytes $bytes 'validated output')
    return ,$bytes
}

function Merge-EsdeGamelist($Base,$Local,[scriptblock]$Warning) {
    $warnings=New-Object 'Collections.Generic.List[string]'
    $emit={param($message)$warnings.Add($message);if($Warning){& $Warning $message|Out-Null}}.GetNewClosure()
    $baseEntries=@(Get-EsdeGameEntries $Base $emit)
    $localEntries=@(Get-LocalOnlyGameEntries $Local $emit)
    if($null-eq$Base -and $localEntries.Count-eq0){return $null}
    $template=if($null-ne$Base){$Base}else{$Local}
    $result=ConvertFrom-EsdeGamelistBytes $template.Bytes 'merge copy'
    $result.Document=$template.Document.CloneNode($true)
    $root=$result.Document.DocumentElement
    $list=$root.SelectSingleNode('gameList')
    if(-not$list){$list=$result.Document.CreateElement('gameList');[void]$root.AppendChild($list)}
    $changed=($null-eq$Base)
    # Android 파일만 있을 때는 normal metadata를 승격시키지 않는다.
    if($null-eq$Base){foreach($node in @($list.ChildNodes)){[void]$list.RemoveChild($node)}}
    $keys=New-Object 'Collections.Generic.Dictionary[string,System.Xml.XmlElement]' ([StringComparer]::Ordinal)
    foreach($node in @($list.SelectNodes('game'))){
        $info=Get-EsdeGamePathInfo $node.SelectSingleNode('path').InnerText
        if($info.Class-ne'Managed'){& $emit ('Dropbox local-only 경로 발견: '+$info.Key)}
        if($keys.ContainsKey($info.Key)){
            [void]$list.RemoveChild($node);$changed=$true;& $emit ('Dropbox 중복 path: '+$info.Key)
        }else{$keys.Add($info.Key,$node)}
    }
    $localKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($entry in $localEntries){
        if(-not$localKeys.Add($entry.Key)){& $emit ('Android local-only 중복 path, 첫 항목 보존: '+$entry.Key);continue}
        $imported=$result.Document.ImportNode($entry.Node,$true)
        if($keys.ContainsKey($entry.Key)){
            & $emit ('local-only 충돌: Android 우선 '+$entry.Key)
            [void]$list.ReplaceChild($imported,$keys[$entry.Key]);$keys[$entry.Key]=$imported
        }else{
            [void]$list.AppendChild($result.Document.CreateWhitespace($template.Newline))
            [void]$list.AppendChild($imported);$keys.Add($entry.Key,$imported)
        }
        $changed=$true
    }
    $result.Bytes=if($changed){ConvertTo-EsdeGamelistBytes $result}else{$template.Bytes}
    [void](ConvertFrom-EsdeGamelistBytes $result.Bytes 'merge verification')
    $result|Add-Member -NotePropertyName Warnings -NotePropertyValue @($warnings.ToArray())
    $result|Add-Member -NotePropertyName InputPaths -NotePropertyValue @($Base.Source,$Local.Source|Where-Object {$_})
    return $result
}

function Write-EsdeGamelist($Gamelist,[string]$Path) {
    if($null-eq$Gamelist){return $false}
    if([string]::IsNullOrWhiteSpace($Path)){throw '출력 경로가 필요합니다.'}
    $destination=[IO.Path]::GetFullPath($Path)
    if($Gamelist.InputPaths -icontains $destination -or [IO.File]::Exists($destination)){throw '원본/기존 파일 덮어쓰기 금지'}
    # 새 PC staging 파일만 생성한다. 검증된 bytes를 임시 파일에 쓴 후 이동한다.
    $validated=ConvertFrom-EsdeGamelistBytes $Gamelist.Bytes 'write verification'
    [void]@(Get-EsdeGameEntries $validated)
    $temporary=$destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($Gamelist.Bytes,0,$Gamelist.Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        [void](Read-EsdeGamelist $temporary)
        [IO.File]::Move($temporary,$destination)
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    return $true
}
