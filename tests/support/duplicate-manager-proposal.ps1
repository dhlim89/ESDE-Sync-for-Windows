# Stage 1 test entry point: share runtime proposal definitions, never execute worker body.
$duplicateAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'sync-worker.ps1'),[ref]$null,[ref]$null)
foreach($fn in $duplicateAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -In @('New-UnregisteredDuplicateProposal','Get-DuplicateProposalBinding','New-DuplicateSelectionPlan','ConvertTo-DuplicateManagerViewModel')){. ([scriptblock]::Create($fn.Extent.Text))}
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