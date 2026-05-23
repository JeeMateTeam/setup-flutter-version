$ErrorActionPreference = 'Stop'

function Write-Log {
  param([string]$Message)
  Write-Host "[setup-flutter-version] $Message"
}

function Write-Fail {
  param([string]$Message)
  Write-Host "::error::$Message"
  exit 1
}

function Test-IsTrue {
  param([string]$Value)
  return $Value -match '^(?i:true|1|yes)$'
}

function Test-FlutterRoot {
  param([string]$Root)
  return (-not [string]::IsNullOrWhiteSpace($Root)) -and (Test-Path "$Root\bin\flutter.bat")
}

function Assert-GitClone {
  param([string]$Root)
  if (-not (Test-Path "$Root\.git")) {
    $repo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'JeeMateTeam/setup-flutter-version' }
    Write-Fail "Flutter SDK at '$Root' is not a git clone (.git directory missing). Install Flutter via git clone. See: https://github.com/$repo#prerequisites"
  }
}

function Get-FlutterRoot {
  if (-not [string]::IsNullOrWhiteSpace($env:INPUT_FLUTTER_ROOT)) {
    $candidate = $env:INPUT_FLUTTER_ROOT
    if (-not (Test-FlutterRoot $candidate)) {
      Write-Fail "Input flutter-root '$candidate' is invalid (bin\flutter.bat not found)."
    }
    Assert-GitClone $candidate
    return (Resolve-Path $candidate).Path
  }

  if (-not [string]::IsNullOrWhiteSpace($env:FLUTTER_ROOT)) {
    $candidate = $env:FLUTTER_ROOT
    if (Test-FlutterRoot $candidate) {
      Assert-GitClone $candidate
      return (Resolve-Path $candidate).Path
    }
  }

  $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
  if ($flutterCmd) {
    $binDir = Split-Path $flutterCmd.Source -Parent
    $candidate = (Resolve-Path (Join-Path $binDir '..')).Path
    if (Test-FlutterRoot $candidate) {
      Assert-GitClone $candidate
      return $candidate
    }
  }

  $commonPaths = @(
    (Join-Path $env:LOCALAPPDATA 'flutter'),
    'C:\flutter',
    'C:\src\flutter',
    (Join-Path $env:USERPROFILE 'flutter'),
    (Join-Path $env:USERPROFILE 'development\flutter')
  )

  foreach ($candidate in $commonPaths) {
    if (Test-FlutterRoot $candidate) {
      Assert-GitClone $candidate
      return (Resolve-Path $candidate).Path
    }
  }

  Write-Fail 'No Flutter git SDK found. Set flutter-root or FLUTTER_ROOT, or install Flutter via git clone. See README prerequisites.'
}

function Ensure-SafeDirectory {
  param([string]$Root)
  git config --global --add safe.directory $Root 2>$null | Out-Null
}

function Get-CurrentRevision {
  param([string]$Root)
  return (git -C $Root rev-parse HEAD).Trim()
}

function Get-NormalizedVersion {
  param([string]$Version)
  return ($Version -replace '-.*$', '')
}

function Get-FlutterMachineJson {
  param([string]$FlutterBin)
  $output = & $FlutterBin --version --machine 2>$null
  if (-not $output) {
    Write-Fail "Unable to read Flutter version via 'flutter --version --machine'."
  }
  return ($output | ConvertFrom-Json)
}

function Assert-FlutterVersion {
  param(
    [string]$FlutterBin,
    [string]$ExpectedVersion
  )

  $machine = Get-FlutterMachineJson $FlutterBin
  $actual = [string]$machine.frameworkVersion

  if ($ExpectedVersion -match '-') {
    if ($actual -ne $ExpectedVersion) {
      Write-Fail "Flutter version mismatch after switch. Expected '$ExpectedVersion', got '$actual'."
    }
    return
  }

  $normalizedExpected = Get-NormalizedVersion $ExpectedVersion
  $normalizedActual = Get-NormalizedVersion $actual

  if ($normalizedActual -ne $normalizedExpected) {
    Write-Fail "Flutter version mismatch after switch. Expected '$ExpectedVersion', got '$actual'."
  }
}

function Switch-ChannelIfNeeded {
  param(
    [string]$FlutterBin,
    [string]$Channel
  )

  $machine = Get-FlutterMachineJson $FlutterBin
  $currentChannel = [string]$machine.channel
  if ($currentChannel -eq $Channel) {
    Write-Log "Already on channel '$Channel'."
    return
  }

  Write-Log "Switching Flutter channel to '$Channel'..."
  & $FlutterBin channel $Channel --cache-artifacts=false
  if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to switch Flutter channel to '$Channel'."
  }
}

function Get-PrecacheFlags {
  $platforms = if ($env:INPUT_PRECACHE_PLATFORMS) { $env:INPUT_PRECACHE_PLATFORMS } else { 'android,ios,web' }
  $flags = New-Object System.Collections.Generic.List[string]

  foreach ($platform in ($platforms -split ',')) {
    $platform = $platform.Trim().ToLowerInvariant()
    switch ($platform) {
      'android' { $flags.Add('--android') }
      'ios' { }
      'web' { $flags.Add('--web') }
      'windows' { $flags.Add('--windows') }
      'linux' { }
      'macos' { }
      default { Write-Log "Ignoring unknown precache platform: $platform" }
    }
  }

  return ,$flags.ToArray()
}

function Switch-FlutterVersion {
  param(
    [string]$Root,
    [string]$FlutterBin,
    [string]$TargetHash,
    [string]$TargetVersion,
    [string]$IsChannelHead,
    [string]$Channel
  )

  $currentHash = Get-CurrentRevision $Root
  if ($currentHash -eq $TargetHash) {
    Write-Log "Already on target revision $($TargetHash.Substring(0, 12)) ($TargetVersion)."
    return
  }

  Switch-ChannelIfNeeded $FlutterBin $Channel

  if (Test-IsTrue $IsChannelHead) {
    Write-Log 'Target is channel head; running flutter upgrade...'
    & $FlutterBin upgrade --force
    if ($LASTEXITCODE -ne 0) {
      Write-Fail 'flutter upgrade failed.'
    }
    return
  }

  Write-Log "Checking out Flutter $TargetVersion ($($TargetHash.Substring(0, 12)))..."
  git -C $Root fetch --tags --force
  if ($LASTEXITCODE -ne 0) {
    Write-Fail 'git fetch failed.'
  }

  git -C $Root checkout $TargetHash -f
  if ($LASTEXITCODE -ne 0) {
    Write-Log "Hash checkout failed; trying tag $TargetVersion..."
    git -C $Root checkout "tags/$TargetVersion" -f
    if ($LASTEXITCODE -ne 0) {
      Write-Fail "Failed to checkout Flutter version $TargetVersion."
    }
  }
}

if ([string]::IsNullOrWhiteSpace($env:RESOLVED_VERSION)) { Write-Fail 'RESOLVED_VERSION is required.' }
if ([string]::IsNullOrWhiteSpace($env:RESOLVED_HASH)) { Write-Fail 'RESOLVED_HASH is required.' }
if ([string]::IsNullOrWhiteSpace($env:RESOLVED_CHANNEL)) { Write-Fail 'RESOLVED_CHANNEL is required.' }
if ([string]::IsNullOrWhiteSpace($env:RESOLVED_IS_CHANNEL_HEAD)) { $env:RESOLVED_IS_CHANNEL_HEAD = 'false' }

$flutterRoot = Get-FlutterRoot
$flutterBin = Join-Path $flutterRoot 'bin\flutter.bat'

Write-Log "Using Flutter SDK at $flutterRoot"
Ensure-SafeDirectory $flutterRoot

Switch-FlutterVersion `
  -Root $flutterRoot `
  -FlutterBin $flutterBin `
  -TargetHash $env:RESOLVED_HASH `
  -TargetVersion $env:RESOLVED_VERSION `
  -IsChannelHead $env:RESOLVED_IS_CHANNEL_HEAD `
  -Channel $env:RESOLVED_CHANNEL

Write-Log 'Running flutter doctor...'
& $flutterBin doctor --suppress-analytics
if ($LASTEXITCODE -ne 0) {
  Write-Fail 'flutter doctor failed.'
}

Assert-FlutterVersion $flutterBin $env:RESOLVED_VERSION

if (Test-IsTrue ($(if ($env:INPUT_PRECACHE) { $env:INPUT_PRECACHE } else { 'true' }))) {
  $precacheFlags = Get-PrecacheFlags
  if ($precacheFlags.Count -gt 0) {
    Write-Log ("Running flutter precache {0}..." -f ($precacheFlags -join ' '))
    & $flutterBin precache --suppress-analytics @precacheFlags
    if ($LASTEXITCODE -ne 0) {
      Write-Fail 'flutter precache failed.'
    }
  } else {
    Write-Log 'No precache platforms applicable on this OS; skipping precache.'
  }
}

if ($env:GITHUB_OUTPUT) {
  Add-Content -Path $env:GITHUB_OUTPUT -Value "flutter-root=$flutterRoot"
}

Write-Log "Flutter $($env:RESOLVED_VERSION) is ready at $flutterRoot"
