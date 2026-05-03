Param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [int]$BuildNumber = 0,

  [string]$CommitMessage = '',

  [switch]$AnalyzeSize
)

$ErrorActionPreference = 'Stop'

function Get-PubspecVersionParts {
  $pubspec = Get-Content pubspec.yaml -Raw
  $match = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$')
  if (-not $match.Success) {
    throw 'Could not read version from pubspec.yaml'
  }
  return @{
    Semver = $match.Groups[1].Value
    Build = [int]$match.Groups[2].Value
  }
}

function Set-PubspecVersion([string]$Semver, [int]$Build) {
  $path = 'pubspec.yaml'
  $content = Get-Content $path -Raw
  $updated = [regex]::Replace(
    $content,
    '(?m)^version:\s*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+\s*$',
    "version: $Semver+$Build"
  )
  if ($updated -eq $content) {
    throw 'Failed to update pubspec.yaml version'
  }
  Set-Content -Path $path -Value $updated
}

function Set-InstallerVersion([string]$Semver) {
  $path = 'installer.iss'
  $content = Get-Content $path -Raw
  $updated = [regex]::Replace(
    $content,
    '#define MyAppVersion "[^"]+"',
    "#define MyAppVersion `"$Semver`""
  )
  if ($updated -eq $content) {
    throw 'Failed to update installer.iss version'
  }
  Set-Content -Path $path -Value $updated
}

function Require-CleanTag([string]$TagName) {
  $existing = git tag --list $TagName
  if ($null -eq $existing) {
    $existing = ''
  } else {
    $existing = "$existing".Trim()
  }
  if ($existing) {
    throw "Git tag '$TagName' already exists."
  }
}

function Stage-ReleaseFiles {
  $paths = @(
    'android',
    'assets',
    'installer.iss',
    'ios',
    'lib',
    'linux',
    'macos',
    'pubspec.lock',
    'pubspec.yaml',
    'README.md',
    'tools',
    'web',
    'windows'
  )
  git add -- $paths
}

$current = Get-PubspecVersionParts
if ($BuildNumber -le 0) {
  $BuildNumber = $current.Build + 1
}

$tagName = "v$Version"
if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
  $CommitMessage = "Release $tagName"
}

Write-Host "1) Preparing version $Version+$BuildNumber"
Require-CleanTag $tagName
Set-PubspecVersion -Semver $Version -Build $BuildNumber
Set-InstallerVersion -Semver $Version

Write-Host '2) Building installer'
$buildArgs = @('-ExecutionPolicy', 'Bypass', '-File', 'tools\build_installer.ps1')
if ($AnalyzeSize) { $buildArgs += '-AnalyzeSize' }
powershell @buildArgs

Write-Host '3) Staging release source files'
Stage-ReleaseFiles

& git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
  Write-Host '4) Creating release commit'
  git commit -m $CommitMessage
} else {
  Write-Host '4) No staged changes to commit'
}

Write-Host '5) Pushing branch'
git push origin HEAD

Write-Host "6) Creating and pushing tag $tagName"
git tag $tagName
git push origin "refs/tags/$tagName"

Write-Host '7) Done'
Write-Host 'Next: create a GitHub Release for the pushed tag and upload:'
Write-Host '  dist\QuickBill_By_Abdullah_Installer.exe'
