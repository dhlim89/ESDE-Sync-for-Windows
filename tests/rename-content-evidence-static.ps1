$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'rename-production-static.ps1')
$script:Passed=0
foreach($path in @('.nomedia','systems.txt','readme.txt','gb/.nomedia')){Check ($null-eq(Get-RenameContentPathEvidence $path ('a'*64))) ($path+' ignored')}
foreach($pair in @(@('gb/Game.gb','gb'),@('gbc/Game.gbc','gbc'))){$r=Get-RenameContentPathEvidence $pair[0] ('a'*64);Check ($r.System-ceq$pair[1]-and$r.RelativePath-ceq'Game'+$(if($pair[1]-ceq'gb'){'.gb'}else{'.gbc'})) ($pair[0]+' evidence')}
foreach($path in @('Game.gb','unknown/Game.gb','../readme.txt','gb/../../readme.txt','/gb/Game.gb')){Reject ($path+' fail-safe') {Get-RenameContentPathEvidence $path ('a'*64)}}
$r=Get-RenameContentPathEvidence 'gb/Archive.zip' ('a'*64);Check ($r.System-ceq'gb') 'authoritative extension policy reused including archive'
RenameSetup;Put '/storage/emulated/0/ROMs/.nomedia' 'MARKER';Put '/storage/emulated/0/ROMs/systems.txt' 'ROOT METADATA';Put '/storage/emulated/0/ROMs/readme.txt' 'ROOT README';$p=Prepare;Check ($p.Promotions.Count-eq1-and$p.Promotions[0].Action-ceq'PROMOTE_WITH_RENAME') 'root metadata does not hide valid rename proposal'
RenameSetup '_UNREGISTERED/Same.gb' 'Same.gb';Put '/storage/emulated/0/ROMs/.nomedia' 'MARKER';$p=Prepare;Check ($p.Promotions.Count-eq1-and$p.Promotions[0].Action-ceq'PROMOTE_TO_MANAGED') 'SAME_NAME unchanged'
$rows=@([pscustomobject]@{RelativePath='Managed.gb';Sha256=('a'*64)},[pscustomobject]@{RelativePath='Extra.gb';Sha256=('b'*64)},[pscustomobject]@{RelativePath='_TEST/Test.gb';Sha256=('c'*64)})
$c=@(New-UnregisteredClassificationPlan gb @([pscustomobject]@{RelativePath='Managed.gb';Sha256=('a'*64)}) $rows @() @('gb'))
Check (@($c|Where-Object Classification -CEQ MANAGED).Count-eq1-and@($c|Where-Object Classification -CEQ UNMANAGED).Count-eq1-and@($c|Where-Object Classification -CEQ LOCAL_ONLY).Count-eq1) 'managed unmanaged local-only unchanged'
RenameSetup '_UNREGISTERED/OldName.zip' 'NewName.zip';$p=Prepare;Check ($p.Promotions.Count-eq0-and$p.ReviewRequired) 'broader classification formats do not broaden verified rename scope'
'RENAME CONTENT EVIDENCE PASS: '+$script:Passed