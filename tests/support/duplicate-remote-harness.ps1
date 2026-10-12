# Test-only filesystem backend. No ADB transport or installed App is loaded.
function Assert-DuplicateStagingPath([string]$Path,[string]$Root) {
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($Path)
    if(-not$full.StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'REMOTE BLOCK: outside staging root'}
    if(-not(Test-Path -LiteralPath (Join-Path $rootPath 'remote-harness.json'))){throw 'REMOTE BLOCK: staging authority missing'}
    $authority=Get-Content -LiteralPath (Join-Path $rootPath 'remote-harness.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($authority.schemaVersion-ne1-or$authority.root-cne$rootPath-or$authority.remoteOnly-ne$true){throw 'REMOTE BLOCK: staging authority invalid'}
    $cursor=$full
    while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'REMOTE BLOCK: link/reparse path'}};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent-ceq$cursor){break};$cursor=$parent}
    return $full
}
function New-DuplicateRemoteStaging([string]$Original,[string]$Root) {
    if(Test-Path -LiteralPath $Root){throw 'REMOTE BLOCK: preserve existing evidence'}
    [void][IO.Directory]::CreateDirectory($Root)
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    [IO.File]::WriteAllText((Join-Path $Root 'remote-harness.json'),(@{schemaVersion=1;root=$rootPath;remoteOnly=$true}|ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
    foreach($dir in @('source','master','android-fixture','evidence')){[void][IO.Directory]::CreateDirectory((Join-Path $Root $dir))}
    $copy=Assert-DuplicateStagingPath (Join-Path $Root 'master/read-only-input.xml') $Root
    $before=(Get-FileHash -LiteralPath $Original).Hash
    Copy-Item -LiteralPath $Original -Destination $copy
    if((Get-FileHash -LiteralPath $copy).Hash-cne$before-or(Get-Item -LiteralPath $copy).Length-ne(Get-Item -LiteralPath $Original).Length){throw 'REMOTE BLOCK: copy verification'}
    [pscustomobject]@{Root=$Root;Original=$Original;OriginalSha256=$before;Input=$copy;Master=$null}
}
function Write-DuplicateStagingMaster($Context,$Xml,[string]$Output) {
    $path=Assert-DuplicateStagingPath $Output $Context.Root
    if($path-ieq$Context.Original-or$path-ieq$Context.Input){throw 'REMOTE BLOCK: input overwrite'}
    # Production writer's no-overwrite contract remains intact; only a fresh output is accepted.
    [void](Write-EsdeGamelist $Xml $path)
    [void](Read-EsdeGamelist $path)
    if((Get-FileHash -LiteralPath $Context.Original).Hash-cne$Context.OriginalSha256){throw 'REMOTE BLOCK: original revision'}
    $Context.Master=$path
    return $path
}
function Resolve-DuplicateFakePath($Context,[string]$AndroidPath) {
    if($AndroidPath-cnotmatch'^/storage/emulated/0/(ROMs|RetroArch|ES-DE)/'-or$AndroidPath-match'[\\\x00-\x1f]' -or @($AndroidPath.Split('/')|Where-Object {$_-in@('.','..','') -and $_-ne''}).Count){throw 'REMOTE BLOCK: Android path'}
    if($AndroidPath.Contains('//')){throw 'REMOTE BLOCK: empty component'}
    Assert-DuplicateStagingPath (Join-Path $Context.Root ('android-fixture/'+$AndroidPath.TrimStart('/'))) $Context.Root
}
function Get-DuplicateFakeFile($Context,[string]$Path) {
    $disk=Resolve-DuplicateFakePath $Context $Path
    if(-not(Test-Path -LiteralPath $disk)){return [pscustomobject]@{Exists=$false;IsLink=$false;Kind='File'}}
    $file=Get-Item -LiteralPath $disk
    [pscustomobject]@{Exists=$true;IsLink=$false;Kind=if($file.PSIsContainer){'Directory'}else{'File'};Size=$file.Length;Sha256=if($file.PSIsContainer){''}else{(Get-FileHash -LiteralPath $disk).Hash.ToLowerInvariant()};Device='fake-device';Inode=$disk}
}
function New-DuplicateDiskAdapter($Context) {
    $ctx=$Context
    $stat={param($p)Get-DuplicateFakeFile $ctx $p}.GetNewClosure()
    $asset=[pscustomobject]@{Mode='Mock';Stat=$stat;Parent={param($r,$p,$create)$disk=Resolve-DuplicateFakePath $ctx $p;if($create-or-not(Test-Path -LiteralPath $disk -PathType Container)){throw 'REMOTE BLOCK: asset parent'};[pscustomobject]@{Safe=$true;Exists=$true;Kind='Directory';CanonicalPath=$p;Device='fake-device'}}.GetNewClosure();MoveNoClobber={param($s,$d,$sha)
        $src=Resolve-DuplicateFakePath $ctx $s;$dst=Resolve-DuplicateFakePath $ctx $d
        if(Test-Path -LiteralPath $dst){throw 'REMOTE BLOCK: destination exists'}
        if((Get-FileHash -LiteralPath $src).Hash.ToLowerInvariant()-cne$sha){throw 'REMOTE BLOCK: asset revision'}
        [IO.File]::Move($src,$dst);$ctx.Actions.Add('asset')
    }.GetNewClosure()}
    [pscustomobject]@{Mode='Fixture';Asset=$asset;Stat=$stat
        AssertSafety={if(-not$ctx.Safe){throw 'REMOTE BLOCK: fake foreground unsafe'}}.GetNewClosure()
        Managed={param($p)$file=Get-Item -LiteralPath $ctx.ManagedFile;[pscustomobject]@{Exists=$true;Kind='File';IsLink=$false;Size=$file.Length;Sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()}}.GetNewClosure()
        Validate={param($p,$completed,$xml)
            if($ctx.Fail-ceq'prepared'-and$ctx.Validations-ge1){throw 'injected after prepared'}
            if($ctx.Fail-ceq'assets_moved'-and$completed.Count-eq@($p.Operations|Where-Object Kind -In @('Save','State')).Count-and$ctx.Validations-ge1){throw 'injected after assets_moved'}
            if($ctx.Fail-ceq'xml_committed'-and$xml){throw 'injected after xml_committed'}
            $ctx.Validations++
            $actual=[IO.File]::ReadAllBytes($ctx.XmlFile);$expected=if($xml){$p.PreparedXml.Bytes}else{$ctx.BeforeXml}
            if([Convert]::ToBase64String($actual)-cne[Convert]::ToBase64String($expected)){throw 'REMOTE BLOCK: XML revision'}
            foreach($op in @($p.Operations|Where-Object Kind -In @('Save','State'))){$moved=@($completed|Where-Object SourceRelativePath -CEQ $op.SourceRelativePath).Count;$path=$op.Root+'/'+$(if($moved){$op.DestinationRelativePath}else{$op.SourceRelativePath});$f=Get-DuplicateFakeFile $ctx $path;if(-not$f.Exists-or$f.Sha256-cne$op.ExpectedSha256-or$f.Size-ne$op.Size){throw 'REMOTE BLOCK: asset evidence'}}
        }.GetNewClosure()
        ReadXmlFingerprint={Get-MediaTextHash ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ctx.XmlFile)))}.GetNewClosure()
        CommitXml={param($p)[void](ConvertFrom-EsdeGamelistBytes $p.PreparedXml.Bytes);[void](Assert-DuplicateStagingPath $ctx.XmlFile $ctx.Root);[IO.File]::WriteAllBytes($ctx.XmlFile,$p.PreparedXml.Bytes);$ctx.Actions.Add('xml')}.GetNewClosure()
        DeleteExact={param($s,$c,$sha,$size)
            $policy=[pscustomobject]@{System='gb';SourceRelativePath=$s.Substring('/storage/emulated/0/ROMs/gb/'.Length);CanonicalRelativePath=$c.Substring('/storage/emulated/0/ROMs/gb/'.Length);ExpectedSha256=$sha};Assert-DuplicateDeleteScope $policy
            foreach($p in @($s,$c)){$f=Get-DuplicateFakeFile $ctx $p;if(-not$f.Exists-or$f.Sha256-cne$sha-or$f.Size-ne$size){throw 'REMOTE BLOCK: delete evidence'}}
            [IO.File]::Delete((Resolve-DuplicateFakePath $ctx $s));$ctx.Actions.Add('delete')
        }.GetNewClosure()
        Verify={param($p,$completed)if($ctx.Fail-ceq'rom_deleted'){throw 'injected after rom_deleted'};$f=Get-DuplicateFakeFile $ctx ('/storage/emulated/0/ROMs/gb/'+$p.CanonicalRelativePath);if($f.Sha256-cne$p.ExpectedSha256){throw 'REMOTE BLOCK: canonical changed'}}.GetNewClosure()
    }
}
