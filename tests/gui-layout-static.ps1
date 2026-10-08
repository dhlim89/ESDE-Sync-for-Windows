# production layout 함수만 추출. 실제 GUI entrypoint/ADB는 실행하지 않는다.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ESDE-Sync.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-EsdeGuiLayout','Set-EsdeGuiLayout')){
 $fn=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq$name},$false)
 . ([scriptblock]::Create($fn.Extent.Text))
}
$script:Passed=0
function Check($ok,$name){if(-not$ok){throw ('검증 실패: '+$name)};$script:Passed++;Write-Output ('PASS: '+$name)}
$layout=Get-EsdeGuiLayout
$textAssignments=@{}
foreach($node in $ast.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]},$false)){
 if($node.Left.Extent.Text-match'^\$(info|warn|desc)\.Text$'){$textAssignments[$Matches[1]]=(& ([scriptblock]::Create($node.Right.Extent.Text)))}
}
$form=New-Object Windows.Forms.Form
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$controls=@{}
try{
 foreach($name in $layout.Bounds.Keys){
  $type=if($name-in@('sourceBox','logBox')){'TextBox'}elseif($name-eq'deviceCombo'){'ComboBox'}elseif($name-in@('browseBtn','refreshBtn','updateBtn','installUpdateBtn','syncBtn')){'Button'}elseif($name-eq'progress'){'ProgressBar'}else{'Label'}
  $control=New-Object ('System.Windows.Forms.'+$type)
  $controls[$name]=$control
  if($textAssignments.ContainsKey($name)){$control.Text=$textAssignments[$name]}
  if($name-eq'warn'){$control.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)}
  $form.Controls.Add($control)
 }
 Set-EsdeGuiLayout $form $controls
 Check ($form.AutoScaleMode-eq[Windows.Forms.AutoScaleMode]::Dpi) '명시적 Dpi autoscale'
 Check ($form.AutoScaleDimensions.Width-eq96 -and $form.AutoScaleDimensions.Height-eq96) '96 DPI 기준'
 Check (-not$controls.info.AutoSize -and $controls.info.Height-ge84) '경로 4줄 고정 높이'
 Check ($controls.info.Bottom-lt$controls.updateLabel.Top) '실제 control 경로/update overlap 없음'
 Check ($controls.updateLabel.Bottom-lt$controls.warn.Top) 'update/warn overlap 없음'
 Check ($controls.warn.Bottom-lt$controls.syncBtn.Top) 'warn/sync overlap 없음'
 Check ($controls.logBox.Bottom-lt$form.ClientSize.Height) '하단 로그와 여백 유지'
 foreach($scale in @(1.0,1.25)){
  $clientWidth=[math]::Round($layout.ClientWidth*$scale)
  $clientHeight=[math]::Round($layout.ClientHeight*$scale)
  foreach($name in $layout.Bounds.Keys){
   $b=$layout.Bounds[$name]
   Check ($b[0]*$scale-ge0 -and $b[1]*$scale-ge0 -and ($b[0]+$b[2])*$scale-le$clientWidth -and ($b[1]+$b[3])*$scale-le$clientHeight) ($name+' client bounds '+$scale)
  }
  $bitmap=New-Object Drawing.Bitmap(1000,1000)
  $bitmap.SetResolution(96,96)
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{
   foreach($name in @('info','warn','desc')){
    $points=if($name-eq'warn'){9*$scale}else{10*$scale}
    $style=if($name-eq'warn'){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
    $font=New-Object Drawing.Font('Segoe UI',$points,$style)
    try{
     $b=$layout.Bounds[$name]
     $measured=$graphics.MeasureString($textAssignments[$name],$font,[int]($b[2]*$scale-8))
     Check ($measured.Height+4-le$b[3]*$scale) ($name+' GDI text height '+$scale)
    }finally{$font.Dispose()}
   }
  }finally{$graphics.Dispose();$bitmap.Dispose()}
 }
 # HWND 표시 없이 Forms의 실제 Scale 경로를 검증한다.
 $form.AutoScaleMode=[Windows.Forms.AutoScaleMode]::None
 $form.Scale((New-Object Drawing.SizeF(1.25,1.25)))
 Check ($controls.info.Bottom-lt$controls.updateLabel.Top -and $controls.warn.Bottom-lt$controls.syncBtn.Top) 'Forms 실제 125% scale 겹침 없음'
 foreach($name in $controls.Keys){Check ($controls[$name].Right-le$form.ClientSize.Width -and $controls[$name].Bottom-le$form.ClientSize.Height) ($name+' 실제 scaled bounds')}
}finally{$form.Dispose()}
Write-Output ('GUI layout 검증 완료: '+$script:Passed+' / 100%,125% 모델·GDI·Forms Scale; 실제 모니터 DPI 전환은 미검증')