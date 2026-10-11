# v1.8 Stage 1: PC-only proposal/model. Never loaded by normal sync or GUI.
function New-UnregisteredDuplicateProposal($System,$Source,$Canonical,[object[]]$Managed,[object[]]$Android,$Local,$Master,$Evidence,[object[]]$Saves,[object[]]$States,[object[]]$Media) {
    # _TEST is completely invisible, including nested/case-insensitive reserved components.
    if(@($Source.RelativePath.Replace('\','/').Split('/')|Where-Object {$_-ieq'_TEST'}).Count){return $null}
    $p=[pscustomobject]@{Id=($System+':'+$Source.RelativePath);System=$System;SourceRelativePath=$Source.RelativePath;CanonicalRelativePath=$Canonical;Classification='UNVERIFIED_DUPLICATE_CANDIDATE';Grade='REVIEW_ONLY';Reason='safety evidence incomplete';Selected=$false;CheckboxEnabled=$false;Operations=@();PreparedXml=$null;XmlEvidence=$null;ExpectedSha256=$Source.Sha256;MediaAction='HOLD';ProductionExecutable=$false}
    $info=Get-EsdeGamePathInfo $Source.RelativePath
    if($info.Class-ceq'Invalid'-or$info.Key.Substring(2)-cne$Source.RelativePath){throw 'DUPLICATE BLOCK: invalid source path'}
    if(-not$Source.RelativePath.StartsWith('_UNREGISTERED/',[StringComparison]::Ordinal)){$p.Reason='source namespace not verified';return $p}
    if($System-cnotin@('gb','gbc')){$p.Reason='unsupported system';return $p}
    try{[void](Get-ClassificationRelativePath $System $Canonical @($System))}catch{$p.Reason='canonical invalid';return $p}
    if([IO.Path]::GetExtension($Source.RelativePath).ToLowerInvariant()-notin@(Get-ClassificationExtensions $System)-or[IO.Path]::GetExtension($Canonical).ToLowerInvariant()-notin@(Get-ClassificationExtensions $System)){$p.Reason='unsupported ROM extension';return $p}
    $candidates=@($Managed|Where-Object {$_.System-ceq$System-and$_.Sha256-ceq$Source.Sha256})
    $masterRom=@($Managed|Where-Object {$_.System-ceq$System-and$_.RelativePath-ceq$Canonical})
    $canonicalRom=@($Android|Where-Object {$_.System-ceq$System-and$_.RelativePath-ieq$Canonical})
    $sourceRom=@($Android|Where-Object {$_.System-ceq$System-and$_.RelativePath-ieq$Source.RelativePath})
    if($candidates.Count-ne1-or$masterRom.Count-ne1-or$canonicalRom.Count-ne1-or$sourceRom.Count-ne1){$p.Reason='missing/ambiguous source canonical or managed candidate';return $p}
    foreach($r in @($Source,$sourceRom[0],$canonicalRom[0],$masterRom[0])){if($r.Kind-cne'File'-or$r.IsLink-ne$false-or$r.Sha256-cnotmatch'^[a-f0-9]{64}$'-or$r.Sha256-cne$Source.Sha256-or$null-eq$r.Size-or$r.Size-ne$Source.Size-or$r.Size-lt0){$p.Reason='file/link/SHA evidence mismatch';return $p}}
    if($canonicalRom[0].RelativePath-cne$Canonical-or$sourceRom[0].RelativePath-cne$Source.RelativePath-or$candidates[0].RelativePath-cne$Canonical){$p.Reason='case/path ambiguity';return $p}
    $p.Classification='UNREGISTERED_MANAGED_DUPLICATE'
    $p|Add-Member FileEvidence (@($sourceRom[0],$canonicalRom[0],$masterRom[0])|Select-Object System,RelativePath,Kind,IsLink,Sha256,Size)
    if(-not$Evidence.Verified-or$Evidence.Core-cne'SameBoy'-or$Evidence.System-cne$System-or-not$Evidence.CompleteSameBoyContentInventory-or-not$Evidence.CompleteAssetInventory-or-not$Evidence.CompleteMediaInventory-or-not$Evidence.PathIndependent-or-not$Evidence.Reference){$p.Reason='unverified SameBoy environment/inventories';return $p}
    $old=[IO.Path]::GetFileNameWithoutExtension($Source.RelativePath);$new=[IO.Path]::GetFileNameWithoutExtension($Canonical)
    if($old-ieq$new-and$old-cne$new){$p.Reason='case-only ambiguity';return $p}
    $others=@($Android+$Managed|Where-Object { -not($_.System-ceq$System-and$_.RelativePath-cin@($Canonical,$Source.RelativePath)) -and [IO.Path]::GetFileNameWithoutExtension($_.RelativePath)-iin@($old,$new) })
    if($others.Count){$p.Reason='shared basename ownership';return $p}
    if($old-ceq$new-and@($Saves+$States|Where-Object {[IO.Path]::GetFileName($_.RelativePath).StartsWith($old+'.',[StringComparison]::OrdinalIgnoreCase)}).Count){$p.Reason='shared save/state namespace requires separate policy';return $p}
    $assets=Get-RenameAssetPlan $old $new $Saves $States
    $mediaPlan=Get-RenameMediaPlan $old $new $Media @()
    if(-not$assets.Safe-or-not$mediaPlan.Safe){$p.Reason=$assets.Reason+'; '+$mediaPlan.Reason;return $p}
    try{
        [void]@(Get-EsdeFolderEntries $Local);[void]@(Get-EsdeFolderEntries $Master)
        $nodes=@(Get-EsdeGameEntries $Local);$localNode=@($nodes|Where-Object Key -IEQ ('./'+$Source.RelativePath));$canonicalNode=@($nodes|Where-Object Key -IEQ ('./'+$Canonical))
        if($localNode.Count-gt1-or$canonicalNode.Count-gt1){throw 'duplicate XML nodes'}
        foreach($n in $localNode+$canonicalNode){if($n.Node.SelectSingleNode('altemulator')-and$n.Node.SelectSingleNode('altemulator').InnerText-cne'SameBoy'){throw 'unverified per-game core'}}
        foreach($n in $localNode+$canonicalNode){if($n.Key-cnotin@(('./'+$Source.RelativePath),('./'+$Canonical))){throw 'XML case collision'}}
        # Inspector projection only: existing canonical is expected here, not a promotion collision.
        $inspect=ConvertFrom-EsdeGamelistBytes $Local.Bytes
        foreach($n in @(Get-EsdeGameEntries $inspect|Where-Object Key -CEQ ('./'+$Canonical))){[void]$n.Node.ParentNode.RemoveChild($n.Node)}
        $inspect.Bytes=ConvertTo-EsdeGamelistBytes $inspect
        $safe=Get-PromotionMetadataSafety $inspect $Master ('./'+$Source.RelativePath) ('./'+$Canonical)
        if(-not$safe.Safe){throw $safe.Reason}
        if($canonicalNode.Count){
            $probe=ConvertFrom-EsdeGamelistBytes $Local.Bytes;$list=$probe.Document.DocumentElement.SelectSingleNode('gameList');foreach($n in @($list.SelectNodes('game'))){[void]$list.RemoveChild($n)}
            $copy=$probe.Document.ImportNode($canonicalNode[0].Node,$true);$copy.SelectSingleNode('path').InnerText='./'+$Source.RelativePath;[void]$list.AppendChild($copy);$probe.Bytes=ConvertTo-EsdeGamelistBytes $probe
            if(-not(Get-PromotionMetadataSafety $probe $Master ('./'+$Source.RelativePath) ('./'+$Canonical)).Safe){throw 'canonical custom metadata unsafe'}
        }
        $boundLocal=ConvertFrom-EsdeGamelistBytes $Local.Bytes
        $target=if($canonicalNode.Count){$boundLocal.Document.ImportNode($canonicalNode[0].Node,$true)}elseif($localNode.Count){$boundLocal.Document.ImportNode($localNode[0].Node,$true)}else{$null}
        if($localNode.Count-and$canonicalNode.Count){foreach($tag in @('playcount','playtime','lastplayed')){$a=$localNode[0].Node.SelectSingleNode($tag);$b=$canonicalNode[0].Node.SelectSingleNode($tag);if($a-and$b-and$a.OuterXml-cne$b.OuterXml){throw 'runtime conflict requires user resolution'}};[void](Merge-EsdeRuntimeGameTags $target $localNode[0].Node)}
        foreach($n in @(Get-EsdeGameEntries $boundLocal|Where-Object {$_.Key-cin@(('./'+$Source.RelativePath),('./'+$Canonical))})){[void]$n.Node.ParentNode.RemoveChild($n.Node)}
        if($target){$target.SelectSingleNode('path').InnerText='./'+$Canonical;[void]$boundLocal.Document.DocumentElement.SelectSingleNode('gameList').AppendChild($target)}
        $boundLocal.Bytes=ConvertTo-EsdeGamelistBytes $boundLocal
        $p.PreparedXml=Get-AndroidBoundGamelist $Master $boundLocal $System
        $p.XmlEvidence=Get-PromotionXmlEvidence $Local $Master ('./'+$Source.RelativePath) ('./'+$Canonical)
    }catch{$p.Reason='metadata unsafe: '+$_.Exception.Message;return $p}
    $p.Grade=if($assets.Operations.Count-or($localNode.Count-and@($localNode[0].Node.ChildNodes|Where-Object {$_.NodeType-eq'Element'-and$_.Name-cne'path'}).Count)){'SAFE_MERGE_DELETE'}else{'SAFE_DELETE'}
    $p.CheckboxEnabled=$true;$p.Reason='verified triple SHA; supported data mapping; no local media/slots/collisions'
    $p.Operations=@($assets.Operations)+@([pscustomobject]@{Kind='XmlCommit';Action='MERGE_AND_REMOVE_LOCAL_NODE'},[pscustomobject]@{Kind='DeleteRomLast';SourceRelativePath=$p.SourceRelativePath;CanonicalRelativePath=$Canonical;ExpectedSha256=$p.ExpectedSha256})
    $p|Add-Member Binding (Get-DuplicateProposalBinding $p)
    return $p
}
function Get-DuplicateProposalBinding($Proposal){Get-MediaTextHash (($Proposal|Select Id,System,SourceRelativePath,CanonicalRelativePath,Grade,ExpectedSha256,Operations,XmlEvidence,FileEvidence|ConvertTo-Json -Depth 12 -Compress)+'|'+[Convert]::ToBase64String($Proposal.PreparedXml.Bytes))}
function New-DuplicateSelectionPlan([object[]]$Rows,[string[]]$SelectedIds){
    if(@($SelectedIds|Select-Object -Unique).Count-ne$SelectedIds.Count){throw 'duplicate selection ids'}
    $selected=@();foreach($id in $SelectedIds){$r=@($Rows|Where-Object Id -CEQ $id);if($r.Count-ne1-or-not$r[0].CheckboxEnabled-or$r[0].Grade-cnotin@('SAFE_DELETE','SAFE_MERGE_DELETE')-or(Get-DuplicateProposalBinding $r[0])-cne$r[0].Binding){throw 'selection unsafe/stale'};$selected+=$r[0]}
    if(@($selected|Group-Object System,CanonicalRelativePath|Where-Object Count -GT 1).Count){throw 'shared canonical batch requires resolution'}
    return [pscustomobject]@{Selected=$selected;Count=$selected.Count;ProductionExecutable=$false;Phases=@('prepared','saves_moved','states_moved','xml_committed','source_deleted','completed')}
}
function Invoke-VerifiedAndroidDuplicateDeleteMock($Proposal,$IO){
    if($IO.Mode-cne'Mock'-or$Proposal.SourceRelativePath-notmatch'^_UNREGISTERED/[^/]'-or@($Proposal.SourceRelativePath.Split('/')|Where-Object {$_-ieq'_TEST'}).Count){throw 'mock delete scope'}
    [void](Get-ClassificationRelativePath $Proposal.System $Proposal.CanonicalRelativePath @($Proposal.System))
    if((Get-EsdeGamePathInfo $Proposal.SourceRelativePath).Class-ceq'Invalid'){throw 'delete traversal'}
    $s=& $IO.Stat $Proposal.SourceRelativePath;$c=& $IO.Stat $Proposal.CanonicalRelativePath;$m=& $IO.Managed $Proposal.CanonicalRelativePath
    foreach($r in @($s,$c,$m)){if(-not$r.Exists-or$r.IsLink-or$r.Kind-cne'File'-or$r.Sha256-cne$Proposal.ExpectedSha256){throw 'delete triple evidence revision'}}
    [void](& $IO.DeleteExact $Proposal.SourceRelativePath)
    $s=& $IO.Stat $Proposal.SourceRelativePath;$c=& $IO.Stat $Proposal.CanonicalRelativePath
    if($s.Exists-or-not$c.Exists-or$c.Sha256-cne$Proposal.ExpectedSha256){throw 'delete recovery-needed'}
}
function Invoke-DuplicateTransactionMock($Proposal,$IO,$Selection){
    if($null-eq$Selection-or@($Selection.Selected|Where-Object Id -CEQ $Proposal.Id).Count-ne1){throw 'explicit selection required'}
    if($IO.Mode-cne'Mock'-or-not$Proposal.CheckboxEnabled-or(Get-DuplicateProposalBinding $Proposal)-cne$Proposal.Binding){throw 'mock transaction gate'}
    $phase='prepared';[void](& $IO.Validate $Proposal);[void](& $IO.Record $phase $Proposal)
    try{foreach($kind in @('Save','State')){foreach($op in @($Proposal.Operations|Where-Object Kind -CEQ $kind)){[void](& $IO.Validate $Proposal);Invoke-VerifiedRenameAssetMoveCore $op $IO};$phase=if($kind-ceq'Save'){'saves_moved'}else{'states_moved'};[void](& $IO.Record $phase $Proposal)}
        [void](& $IO.Validate $Proposal);[void](& $IO.CommitXml $Proposal.PreparedXml);$phase='xml_committed';[void](& $IO.Record $phase $Proposal)
        [void](& $IO.Validate $Proposal);Invoke-VerifiedAndroidDuplicateDeleteMock $Proposal $IO;$phase='source_deleted';[void](& $IO.Record $phase $Proposal);[void](& $IO.Record 'completed' $Proposal)
    }catch{[void](& $IO.Record 'recovery-needed' @{LastSuccessfulPhase=$phase;Error=$_.Exception.Message});throw}
}
function ConvertTo-DuplicateManagerViewModel([object[]]$Rows){
 $items=@($Rows|ForEach-Object {[pscustomobject]@{Id=$_.Id;Selected=$false;CheckboxEnabled=$_.CheckboxEnabled;System=$_.System;UnregisteredRom=$_.SourceRelativePath;ManagedRom=$_.CanonicalRelativePath;Status=if($_.Grade-ceq'SAFE_DELETE'){'정리 가능'}elseif($_.Grade-ceq'SAFE_MERGE_DELETE'){'병합 후 정리'}else{'검토 필요'};Action=if($_.Grade-ceq'SAFE_DELETE'){'ROM 삭제'}elseif($_.Grade-ceq'SAFE_MERGE_DELETE'){'save/state/metadata 병합 후 ROM 삭제'}else{'처리 안 함'};Reason=$_.Reason}})
 [pscustomobject]@{Columns=@('선택','시스템','미등록 ROM','관리 ROM','상태','처리 내용','이유');Rows=$items;ConfirmedDuplicateCount=@($Rows|Where-Object Classification -CEQ 'UNREGISTERED_MANAGED_DUPLICATE').Count;ProductionExecutable=$false}
}