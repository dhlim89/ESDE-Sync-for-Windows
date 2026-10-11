# Mock executor only. Pure planning helpers are loaded from sync-worker.ps1.
function Invoke-VerifiedRenameAssetMoveMock($Operation,$IO) {
    if($IO.Mode-cne'Mock'){throw 'mock asset adapter required'}
    Invoke-VerifiedRenameAssetMoveCore $Operation $IO
}
function Assert-RenameMockBinding($Proposal) {
    if((Get-RenamePlanBinding $Proposal)-cne$Proposal.PlanBinding -or (Get-MediaTextHash ([Convert]::ToBase64String($Proposal.PreparedXml.Bytes)))-cne$Proposal.PreparedXmlSha){throw 'rename plan/staging tampered'}
}
function Invoke-RenamePromotionMock($Proposal,$IO) {
    if($IO.Mode-cne'Mock' -or -not$Proposal.Eligible -or $Proposal.Action-cne'PROMOTE_WITH_RENAME' -or $Proposal.ChangeType-cne'RENAME_ONLY'){throw 'rename mock gate'}
    Assert-RenameMockBinding $Proposal
    # Validate every ROM/asset/XML fingerprint before any move; no real ADB adapter.
    [void](& $IO.ValidateEvidence $Proposal)
    foreach($op in $Proposal.Operations){
        $sourcePath=$op.Root+'/'+$op.SourceRelativePath;$destinationPath=$op.Root+'/'+$op.DestinationRelativePath
        $src=& $IO.Stat $sourcePath;$dst=& $IO.Stat $destinationPath
        if(-not$src.Exists -or $src.Kind-cne'File' -or $src.IsLink -or $src.Sha256-cne$op.ExpectedSha256 -or [string]::IsNullOrWhiteSpace($src.Device) -or $dst.Exists -or $dst.IsLink){throw 'rename preflight revision/collision'}
        foreach($path in @($sourcePath,$destinationPath)){$parent=& $IO.Parent $op.Root $path.Substring(0,$path.LastIndexOf('/')) $false;if(-not$parent.Safe -or -not$parent.Exists -or $parent.Kind-cne'Directory' -or $parent.Device-cne$src.Device){throw 'rename parent/filesystem preflight'}}
    }
    $phase='prepared';$attempted=$false;[void](& $IO.Record $phase $Proposal)
    try{
        foreach($kind in @('ROM','Save','State')){foreach($op in @($Proposal.Operations|Where-Object Kind -CEQ $kind)){
            Assert-RenameMockBinding $Proposal;[void](& $IO.ValidateEvidence $Proposal);$attempted=$true
            if($kind-ceq'ROM'){$move=[pscustomobject]@{System=$Proposal.System;SourceRelativePath=$op.SourceRelativePath;DestinationRelativePath=$op.DestinationRelativePath;ExpectedSha256=$op.ExpectedSha256;InitialSourceSha256=$op.ExpectedSha256;DestinationExpectedAbsent=$true};[void](Invoke-VerifiedAndroidRomMoveCore $move $IO)}else{Invoke-VerifiedRenameAssetMoveMock $op $IO}
        };$phase=switch($kind){'ROM'{'rom_moved'} 'Save'{'saves_moved'} 'State'{'states_moved'}};[void](& $IO.Record $phase $Proposal)}
        Assert-RenameMockBinding $Proposal;[void](& $IO.ValidateEvidence $Proposal);[void](& $IO.CommitXml $Proposal.PreparedXml $Proposal.XmlEvidence);$phase='xml_committed';[void](& $IO.Record $phase $Proposal)
        $phase='media_completed_or_held';[void](& $IO.Record $phase $Proposal)
        [void](& $IO.Refresh $Proposal);$phase='completed';[void](& $IO.Record $phase $Proposal)
        return [pscustomobject]@{Completed=$true;PromotedCount=1;Phase=$phase}
    }catch{[void](& $IO.Record 'recovery-needed' ([pscustomobject]@{LastSuccessfulPhase=$phase;MutationAttempted=$attempted;Error=$_.Exception.Message}));throw}
}
