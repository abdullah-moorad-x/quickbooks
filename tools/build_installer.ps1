Param(
  [switch]$AnalyzeSize
)

$ErrorActionPreference = 'Stop'

Write-Host '1) Cleaning and getting packages'
flutter clean | Out-Null
flutter pub get | Out-Null

Write-Host '1.5) Generating launcher icons (Windows)'
try {
  # Uses flutter_launcher_icons config from pubspec.yaml
  dart run flutter_launcher_icons | Out-Null
} catch {
  Write-Warning 'flutter_launcher_icons failed or is not configured; proceeding with existing icons.'
}

# Ensure the Windows .ico exists for both the EXE and installer
$icoPath = Join-Path -Path 'windows' -ChildPath 'runner\resources\app_icon.ico'
if (-not (Test-Path $icoPath)) {
  throw "Windows icon not found at '$icoPath'. Convert your PNG to .ico or ensure flutter_launcher_icons is configured and run."
}

Write-Host '2) Building Windows release'
$buildArgs = @('build','windows','--release','--tree-shake-icons')
if ($AnalyzeSize) { $buildArgs += '--analyze-size' }
flutter @buildArgs

Write-Host '3) Compiling installer with Inno Setup'
if (-not (Get-Command iscc.exe -ErrorAction SilentlyContinue)) {
  $defaultISCC = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
  if (Test-Path $defaultISCC) { $iscc = $defaultISCC } else { throw 'ISCC.exe not found. Install Inno Setup 6 and ensure ISCC.exe is on PATH.' }
} else { $iscc = (Get-Command iscc.exe).Source }

& "$iscc" installer.iss | Write-Host

Write-Host '4) Done. Output:'
Get-ChildItem dist -Filter *.exe -ErrorAction SilentlyContinue | Select-Object FullName,Length | Format-Table -AutoSize
