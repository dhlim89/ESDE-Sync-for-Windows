param([Parameter(Mandatory=$true)][string]$AppRoot, [Parameter(Mandatory=$true)][string]$SessionPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'update-common.ps1')
. (Join-Path $PSScriptRoot 'update-transaction.ps1')
try {
    $session=Assert-UpdateSessionPath $SessionPath $AppRoot
    if ($PSScriptRoot -ine $session) { throw 'update-worker는 App 밖의 승인된 세션 폴더에서 실행해야 합니다.' }
    $state=Invoke-UpdateTransaction $AppRoot $session -OperationTimeoutMilliseconds 10000
    if ($state.state -eq 'completed') { exit 0 }
    if ($state.state -eq 'rollback_failed') { exit 2 }
    exit 1
}
catch { Write-Error $_; exit 1 }
