param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$NewVersion,

  [Parameter(Position = 1)]
  [string]$NewVersionMessage = "v$NewVersion"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ImageName = 'yschuurmans/aircon'
$TargetPlatforms = @('linux/arm/v7', 'linux/arm64', 'linux/amd64', 'linux/386')
$VersionFiles = @(
  'aircon/__init__.py',
  'hassio/config.json',
  'docker-compose.yaml'
)

$PrimaryVersionFile = 'aircon/__init__.py'

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter()]
    [string[]]$ArgumentList = @(),

    [switch]$CaptureOutput
  )

  function Format-ProcessArgument {
    param(
      [Parameter(Mandatory = $true)]
      [AllowEmptyString()]
      [string]$Value
    )

    if ($Value -notmatch '[\s"]') {
      return $Value
    }

    $escapedValue = $Value -replace '(\\*)"', '$1$1\\"'
    $escapedValue = $escapedValue -replace '(\\+)$', '$1$1'
    return '"' + $escapedValue + '"'
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $CaptureOutput.IsPresent
  $startInfo.RedirectStandardError = $CaptureOutput.IsPresent
  $startInfo.CreateNoWindow = $true
  $startInfo.WorkingDirectory = (Get-Location).Path
  $startInfo.Arguments = (($ArgumentList | ForEach-Object { Format-ProcessArgument $_ }) -join ' ')

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo

  try {
    $null = $process.Start()
    if ($CaptureOutput) {
      $stdoutTask = $process.StandardOutput.ReadToEndAsync()
      $stderrTask = $process.StandardError.ReadToEndAsync()
    }
    $process.WaitForExit()
    if ($CaptureOutput) {
      $stdout = $stdoutTask.GetAwaiter().GetResult()
      $stderr = $stderrTask.GetAwaiter().GetResult()
    }
    else {
      $stdout = ''
      $stderr = ''
    }
    $exitCode = $process.ExitCode
  }
  finally {
    $process.Dispose()
  }

  if ($stderr) {
    $trimmedStderr = $stderr.TrimEnd()
    if ($exitCode -eq 0) {
      Write-Warning $trimmedStderr
    }
  }

  if ($exitCode -ne 0) {
    $commandText = @($FilePath) + $ArgumentList -join ' '
    $errorText = $stderr.Trim()
    if ([string]::IsNullOrWhiteSpace($errorText)) {
      throw "Command failed with exit code ${exitCode}: $commandText"
    }

    throw "Command failed with exit code ${exitCode}: $commandText`n$errorText"
  }

  if ($CaptureOutput) {
    return $stdout
  }
}

function Get-FileVersion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $content = Get-Content -Path $Path -Raw
  $match = [regex]::Match($content, '(?m)__version__\s*=\s*[''\"](?<version>[^''\"]+)[''\"]')
  if (-not $match.Success) {
    throw "Failed to determine the current version from $Path"
  }

  return $match.Groups['version'].Value
}

function Get-LatestGitTag {
  try {
    $output = Invoke-NativeCommand git @('tag', '--sort=-creatordate') -CaptureOutput
  }
  catch {
    return $null
  }

  $tags = @($output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($tags.Count -eq 0) {
    return $null
  }

  return $tags[0].Trim()
}

function Test-GitTagExists {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TagName
  )

  $output = Invoke-NativeCommand git @('tag', '--list', $TagName) -CaptureOutput
  return -not [string]::IsNullOrWhiteSpace($output)
}

function Assert-DockerAvailable {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $docker) {
    throw 'docker is not installed or not available on PATH.'
  }

  try {
    $null = Invoke-NativeCommand docker @('info') -CaptureOutput
  }
  catch {
    throw @'
Docker is not reachable from this PowerShell session.

On Windows, make sure Docker Desktop is running and set to Linux containers before publishing.
Then verify the connection with:
  docker info

If Docker Desktop is already open, wait for it to finish starting and retry.
'@
  }
}

function Ensure-BuildxBuilder {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BuilderName
  )

  try {
    $null = Invoke-NativeCommand docker @('buildx', 'inspect', $BuilderName) -CaptureOutput
    Invoke-NativeCommand docker @('buildx', 'use', $BuilderName)
  }
  catch {
    Invoke-NativeCommand docker @(
      'buildx', 'create',
      '--name', $BuilderName,
      '--driver', 'docker-container',
      '--use'
    )
  }

  Invoke-NativeCommand docker @('buildx', 'inspect', $BuilderName, '--bootstrap')
}

function Assert-BuildxPlatforms {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BuilderName,

    [Parameter(Mandatory = $true)]
    [string[]]$Platforms
  )

  $inspectOutput = Invoke-NativeCommand docker @('buildx', 'inspect', $BuilderName) -CaptureOutput
  $platformLine = @($inspectOutput -split "`r?`n" | Where-Object { $_ -match '^Platforms:\s+' })
  if ($platformLine.Count -eq 0) {
    throw "Failed to determine supported platforms for buildx builder '$BuilderName'."
  }

  $supportedPlatforms = $platformLine[0] -replace '^Platforms:\s+', '' -split ',\s*'
  $missingPlatforms = @($Platforms | Where-Object { $_ -notin $supportedPlatforms })
  if ($missingPlatforms.Count -gt 0) {
    $missingPlatformsText = $missingPlatforms -join ', '
    throw @"
The buildx builder '$BuilderName' is missing required platforms: $missingPlatformsText

Current builder platforms:
  $($supportedPlatforms -join ', ')

On Rancher Desktop/Windows, install or enable binfmt/QEMU support for ARM builds,
or reduce the target platform list before publishing.
"@
  }
}

function Update-VersionInFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$OldVersion,

    [Parameter(Mandatory = $true)]
    [string]$NewVersion
  )

  $content = Get-Content -Path $Path -Raw
  $escapedOldVersion = [regex]::Escape($OldVersion)
  $updatedContent = [regex]::Replace($content, $escapedOldVersion, $NewVersion)

  if ($content -eq $updatedContent) {
    throw "Version '$OldVersion' was not found in $Path"
  }

  Set-Content -Path $Path -Value $updatedContent -NoNewline
}

Invoke-NativeCommand git @('pull')

$currentVersion = Get-FileVersion -Path $PrimaryVersionFile
$oldVersion = Get-LatestGitTag
if ([string]::IsNullOrWhiteSpace($oldVersion)) {
  $oldVersion = $currentVersion
}

$needsVersionUpdate = $currentVersion -ne $NewVersion

if ($needsVersionUpdate) {
  if (Test-GitTagExists -TagName $NewVersion) {
    Invoke-NativeCommand git @('tag', '-d', $NewVersion)
  }
  Invoke-NativeCommand git @('tag', '-a', $NewVersion, '-m', $NewVersionMessage)

  $autoChangelog = Get-Command auto-changelog -ErrorAction SilentlyContinue
  if (-not $autoChangelog) {
    throw 'auto-changelog is not installed or not available on PATH.'
  }
  Invoke-NativeCommand $autoChangelog.Source

  foreach ($file in $VersionFiles) {
    Update-VersionInFile -Path $file -OldVersion $oldVersion -NewVersion $NewVersion
  }

  Invoke-NativeCommand git @('commit', '-a', '-m', $NewVersion)
  Invoke-NativeCommand git @('tag', '-d', $NewVersion)
}

if (Test-GitTagExists -TagName $NewVersion) {
  Invoke-NativeCommand git @('tag', '-d', $NewVersion)
}
Invoke-NativeCommand git @('tag', '-a', $NewVersion, '-m', $NewVersionMessage)
Assert-DockerAvailable
Ensure-BuildxBuilder -BuilderName 'multiarch'
Assert-BuildxPlatforms -BuilderName 'multiarch' -Platforms $TargetPlatforms

Invoke-NativeCommand docker @(
  'buildx', 'build',
  '--builder', 'multiarch',
  '--platform', ($TargetPlatforms -join ','),
  '-t', "${ImageName}:$NewVersion",
  '--push',
  '.'
)

Invoke-NativeCommand git @('push')
Invoke-NativeCommand git @('push', '--tags')