#Requires -Version 5.1 -RunAsAdministrator

<#
.SYNOPSIS
Customizes every ISO in the input directory with Customize-Iso.ps1.

.DESCRIPTION
ISOs are processed one at a time, each in its own PowerShell process. DISM is
disk-bound, so running images in parallel buys little and was the main source
of flaky builds.

An ISO is skipped when its customized output already exists and was built from
the same input ISO with the same config, unattend, stubs, and script. Use
-Force to rebuild everything.

With DeleteSourceAfterBuild (default), a source ISO is deleted once its output
is current, keeping its .iso.json and .sha256.txt; an output that later needs
rebuilding is reported as Stale, with the command to download the source again.

Exit code is 0 if every ISO succeeded or was skipped, 1 otherwise (including
stale images whose source was deleted).

Every run writes a machine-readable summary to <LogDirectory>\last-run-runner.json
(and runner-<timestamp>.json beside the transcript) for Send-BuildNotification.ps1.
#>
param (
  [string] $ConfigFile = (Join-Path $PSScriptRoot 'runner-config.json'),
  [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BuildScript = Join-Path $PSScriptRoot 'Customize-Iso.ps1'
$Config = Get-Content -Raw $ConfigFile | ConvertFrom-Json

function Get-ConfigValue($Object, [string] $Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}

$CustomizeConfig = Get-ConfigValue $Config 'CustomizeConfigFile' (Join-Path $PSScriptRoot 'config.json')
$Autounattend = Get-ConfigValue $Config 'AutounattendFile' (Join-Path $PSScriptRoot 'autounattend.xml')
$RecoveryWim = Get-ConfigValue $Config 'RecoveryWimPath' ''
$LogDir = Get-ConfigValue $Config 'LogDirectory' (Join-Path $PSScriptRoot 'logs')
$LogRetentionDays = Get-ConfigValue $Config 'LogRetentionDays' 90
# keep the ISO a rebuild replaces as <name>.previous.iso in the output directory
$KeepPrevious = [bool](Get-ConfigValue $Config 'KeepPrevious' $true)
# delete a source ISO once its output is current, keeping its .iso.json and .sha256.txt
$DeleteSource = [bool](Get-ConfigValue $Config 'DeleteSourceAfterBuild' $true)

# optional virtio-win ISO: drivers go into the images, guest tools onto postinstall.iso
$VirtIO = Get-ConfigValue $Config 'VirtIO'
$VirtIOIso = Get-ConfigValue $VirtIO 'IsoPath' ''
$VirtIODrivers = @(Get-ConfigValue $VirtIO 'Drivers' @('vioscsi', 'viostor', 'NetKVM')) -join ','

# Identify everything that affects the output. If none of it has changed since
# the last successful build, rebuilding would produce the same ISO.
function Get-BuildFingerprint([System.IO.FileInfo] $Iso) {
  # Get-WindowsIso writes a .sha256.txt beside each ISO; fall back to size + timestamp
  $Sidecar = "$($Iso.FullName).sha256.txt"
  $Source = if ((Test-Path $Sidecar) -and (Get-Item $Sidecar).LastWriteTimeUtc -ge $Iso.LastWriteTimeUtc) {
    "sha256:$((Get-Content -Raw $Sidecar).Trim())"
  }
  else {
    "file:$($Iso.Length):$($Iso.LastWriteTimeUtc.Ticks)"
  }

  $Inputs = @($BuildScript, $CustomizeConfig, $Autounattend) +
    @(Get-ChildItem (Join-Path $PSScriptRoot 'stub-scripts') -File -Recurse | Sort-Object FullName | ForEach-Object FullName)
  $Hashes = $Inputs | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_).Hash }
  if ($RecoveryWim -and (Test-Path $RecoveryWim)) {
    $Item = Get-Item $RecoveryWim
    $Hashes += "winre:$($Item.Length):$($Item.LastWriteTimeUtc.Ticks)"
  }
  # a replaced virtio-win ISO (new driver version) or driver list rebuilds everything
  if ($VirtIOIso) {
    $Item = Get-Item $VirtIOIso
    $Hashes += "virtio:$($Item.Length):$($Item.LastWriteTimeUtc.Ticks):$VirtIODrivers"
  }

  $Bytes = [System.Text.Encoding]::UTF8.GetBytes((@($Source) + $Hashes) -join '|')
  $Sha = [System.Security.Cryptography.SHA256]::Create()
  try { -join ($Sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $Sha.Dispose() }
}

# true if another process still has the file open for writing (e.g. it is still being copied in)
function Test-FileLocked([string] $Path) {
  try { [System.IO.File]::Open($Path, 'Open', 'Read', 'Read').Dispose(); $false } catch { $true }
}

#region deleted sources

# Inputs: every ISO, plus every image whose ISO was deleted after it was customized
# (DeleteSourceAfterBuild) but whose .iso.sha256.txt/.iso.json from Get-WindowsIso remain.
# The latter come back as FileInfo objects for the missing ISO: Get-BuildFingerprint only
# needs the .sha256.txt for those (a missing file's LastWriteTimeUtc is year 1601).
function Get-InputImages([string] $Directory) {
  $Isos = @(Get-ChildItem -Path $Directory -Filter '*.iso' -File |
      Where-Object { $_.Extension -eq '.iso' -and $_.Name -notlike '*.previous.iso' })
  $Deleted = @(Get-ChildItem -Path $Directory -File |
      Where-Object { $_.Name -like '*.iso.sha256.txt' -or $_.Name -like '*.iso.json' } |
      ForEach-Object { $_.Name -replace '\.(sha256\.txt|json)$', '' } |
      Where-Object { $_ -notlike '*.previous.iso' } | Sort-Object -Unique |
      Where-Object { -not (Test-Path -LiteralPath (Join-Path $Directory $_)) } |
      ForEach-Object { [System.IO.FileInfo] (Join-Path $Directory $_) })
  @($Isos + $Deleted | Sort-Object Name)
}

# Delete a source ISO whose output is current. Its .sha256.txt (for the fingerprint) and
# .iso.json (so Get-WindowsIso knows the build is already published) stay, so the ISO is
# only deleted if both are there and the checksum is at least as new as the ISO.
function Remove-SourceIso([System.IO.FileInfo] $Iso) {
  $Sidecar = "$($Iso.FullName).sha256.txt"
  if (-not ((Test-Path $Sidecar) -and (Test-Path "$($Iso.FullName).json") -and
      (Get-Item $Sidecar).LastWriteTimeUtc -ge $Iso.LastWriteTimeUtc)) {
    Write-Warning "runner: keeping source $($Iso.Name): it has no current .sha256.txt and .json beside it."
    return
  }
  try {
    Remove-Item -LiteralPath $Iso.FullName -Force
    Write-Host "runner: deleted source $($Iso.Name) (kept its .json and .sha256.txt)."
  }
  catch { Write-Warning "runner: could not delete source $($Iso.Name): $_" }
}

#endregion

#region run summary

# Parsed JSON file, or $null if it is missing or unreadable
function Read-JsonFile([string] $Path) {
  if (-not (Test-Path $Path)) { return $null }
  try { Get-Content -Raw $Path | ConvertFrom-Json } catch { Write-Warning "runner: could not read $($Path): $_"; $null }
}

# One summary item per result row, with build details from the output manifest
# (what is published now) and the source ISO's .iso.json from Get-WindowsIso
function ConvertTo-SummaryItem($Row) {
  $Result = switch -Wildcard ($Row.Status) {
    'OK*' { 'Built' }
    'Failed*' { 'Failed' }
    'Stale*' { 'Stale' }
    default { $Row.Status }   # UpToDate, Locked, Built
  }
  $Manifest = Read-JsonFile (Join-Path $Config.OutputDirectory "$($Row.Iso).json")
  $Source = Read-JsonFile (Join-Path $Config.InputDirectory "$($Row.Iso).json")
  $Images = @(Get-ConfigValue $Manifest 'images' @())
  $Warnings = @(Get-ConfigValue $Manifest 'warnings' @())
  [PSCustomObject]@{
    name            = $Row.Iso
    status          = $Row.Status
    # Built | UpToDate | Failed | Locked | Stale
    result          = $Result
    minutes         = $Row.Minutes
    # warnings of the build that is published now (this run's, if it was rebuilt)
    warnings        = $Warnings.Count
    warningMessages = @($Warnings)
    sourceVersion   = Get-ConfigValue $Source 'name'
    sourceBuild     = Get-ConfigValue $Source 'build'
    imageVersions   = @($Images | ForEach-Object { Get-ConfigValue $_ 'Version' } | Where-Object { $_ } | Sort-Object -Unique)
    editions        = @($Images | ForEach-Object { Get-ConfigValue $_ 'Name' })
    built           = Get-ConfigValue $Manifest 'built'
    # the source ISO is gone (deleted after customizing, see DeleteSourceAfterBuild)
    sourceDeleted   = $Row.Iso -like '*.iso' -and $Row.Iso -ne 'postinstall.iso' -and -not (Test-Path -LiteralPath (Join-Path $Config.InputDirectory $Row.Iso))
  }
}

# UTF-8 without BOM; last-run-runner.json is replaced in one step so readers never see half a file
function Write-RunSummary {
  $Ended = Get-Date
  $Summary = [PSCustomObject]@{
    stage    = 'runner'
    version  = $(try { git -c safe.directory='*' -C $PSScriptRoot rev-parse --short HEAD 2>$null } catch { $null })
    computer = $env:COMPUTERNAME
    started  = $Started.ToString('o')
    ended    = $Ended.ToString('o')
    minutes  = [math]::Round(($Ended - $Started).TotalMinutes, 1)
    exitCode = $ExitCode
    error    = $RunError
    logFile  = $TranscriptPath
    items    = @($Results | ForEach-Object { ConvertTo-SummaryItem $_ })
  }
  $Json = $Summary | ConvertTo-Json -Depth 6
  $Utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $LogDir "runner-$Stamp.json"), $Json, $Utf8)
  $Latest = Join-Path $LogDir 'last-run-runner.json'
  [System.IO.File]::WriteAllText("$Latest.tmp", $Json, $Utf8)
  Move-Item "$Latest.tmp" $Latest -Force
}

#endregion

$Started = Get-Date
$Stamp = $Started.ToString('yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$TranscriptPath = Join-Path $LogDir "runner-$Stamp.log"
Start-Transcript -Path $TranscriptPath | Out-Null

# only one runner at a time - a long build must not collide with next week's
$Mutex = New-Object System.Threading.Mutex($false, 'Global\Customize-WindowsIso-Runner')
$Results = [System.Collections.Generic.List[object]]::new()
$ExitCode = 1
$RunError = $null
$Acquired = $false

try {
  # an abandoned mutex (previous runner was killed) is still acquired
  $Acquired = try { $Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $true }
  if (-not $Acquired) { throw 'runner: another runner is already active. Exiting.' }

  Write-Host "runner: input $($Config.InputDirectory), output $($Config.OutputDirectory), working $($Config.WorkingDirectory)."

  New-Item -ItemType Directory -Force -Path $Config.WorkingDirectory, $Config.OutputDirectory | Out-Null

  # configured but missing: fail rather than quietly build images without the drivers
  if ($VirtIOIso -and -not (Test-Path $VirtIOIso)) {
    throw "runner: VirtIO.IsoPath is set but $VirtIOIso does not exist. Put a virtio-win ISO there or clear VirtIO.IsoPath."
  }
  if ($VirtIOIso) { Write-Host "runner: adding virtio-win drivers ($VirtIODrivers) from $VirtIOIso." }

  # *.previous.iso is a kept copy of an older output, never an input
  $IsoFiles = @(Get-InputImages $Config.InputDirectory)
  $SourceDeleted = @($IsoFiles | Where-Object { -not $_.Exists })
  Write-Host "runner: found $($IsoFiles.Count) ISO(s): $(@($IsoFiles | ForEach-Object Name) -join ', ')$(if ($SourceDeleted) { " ($($SourceDeleted.Count) already customized and deleted)" })"

  foreach ($IsoFile in $IsoFiles) {
    $OutPath = Join-Path $Config.OutputDirectory $IsoFile.Name
    $WorkingDirectory = Join-Path $Config.WorkingDirectory ($IsoFile.BaseName -replace '[^\w.-]', '')
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # source deleted after an earlier build: only the .sha256.txt can say whether the output is current
    if (-not $IsoFile.Exists -and -not (Test-Path "$($IsoFile.FullName).sha256.txt")) {
      $Status = "Stale: source ISO and its .sha256.txt are missing - rerun Get-WindowsIso for $($IsoFile.Name), or delete its .json from $($Config.InputDirectory)"
      Write-Warning "runner: $($IsoFile.Name): $Status"
      $Results.Add([PSCustomObject]@{ Iso = $IsoFile.Name; Status = $Status; Minutes = 0 })
      continue
    }

    if ($IsoFile.Exists -and (Test-FileLocked $IsoFile.FullName)) {
      Write-Warning "runner: $($IsoFile.Name) is in use (still being written?). Skipping this run."
      $Results.Add([PSCustomObject]@{ Iso = $IsoFile.Name; Status = 'Locked'; Minutes = 0 })
      continue
    }

    $Fingerprint = Get-BuildFingerprint $IsoFile
    $ManifestPath = "$OutPath.json"
    if (-not $Force -and (Test-Path $OutPath) -and (Test-Path $ManifestPath)) {
      $Manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
      if ((Get-ConfigValue $Manifest 'fingerprint') -eq $Fingerprint) {
        Write-Host "runner: $($IsoFile.Name) is unchanged since its last build. Skipping."
        $Results.Add([PSCustomObject]@{ Iso = $IsoFile.Name; Status = 'UpToDate'; Minutes = 0 })
        # the output was built from exactly this source, so it can go (e.g. the first run with DeleteSourceAfterBuild)
        if ($DeleteSource -and $IsoFile.Exists) { Remove-SourceIso $IsoFile }
        continue
      }
    }

    # the output is out of date (or -Force) but there is nothing to rebuild it from
    if (-not $IsoFile.Exists) {
      $Version = Get-ConfigValue (Read-JsonFile "$($IsoFile.FullName).json") 'name' $IsoFile.BaseName
      $Status = "Stale: source deleted - rerun Get-WindowsIso: stub.ps1 -Force -Version '$Version', then runner.ps1"
      Write-Warning "runner: $($IsoFile.Name) needs rebuilding (its inputs changed, or -Force) but its source ISO was deleted. $Status"
      $Results.Add([PSCustomObject]@{ Iso = $IsoFile.Name; Status = $Status; Minutes = 0 })
      continue
    }

    Write-Host "runner: customizing $($IsoFile.Name) in $WorkingDirectory."

    $Arguments = @(
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', "`"$BuildScript`"",
      '-IsoPath', "`"$($IsoFile.FullName)`"",
      '-WorkingDir', "`"$WorkingDirectory`"",
      '-OutPath', "`"$OutPath`"",
      '-ConfigFile', "`"$CustomizeConfig`"",
      '-Autounattend', "`"$Autounattend`"",
      '-LogDir', "`"$LogDir`"",
      '-Fingerprint', $Fingerprint
    )
    if ($RecoveryWim) { $Arguments += @('-WinREWimPath', "`"$RecoveryWim`"") }
    if ($VirtIOIso) { $Arguments += @('-VirtIOIsoPath', "`"$VirtIOIso`"", '-VirtIODrivers', $VirtIODrivers) }
    if ($KeepPrevious) { $Arguments += '-KeepPrevious' }

    $Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    $Minutes = [math]::Round($Stopwatch.Elapsed.TotalMinutes, 1)

    if ($Process.ExitCode -eq 0) {
      $Warnings = @(Get-ConfigValue (Get-Content -Raw $ManifestPath | ConvertFrom-Json) 'warnings' @())
      $Status = if ($Warnings) { "OK ($($Warnings.Count) warnings)" } else { 'OK' }
      Write-Host "runner: $($IsoFile.Name) done in $Minutes minutes: $Status."
      # keep the working directory on failure for troubleshooting; it is reused next run
      Remove-Item $WorkingDirectory -Recurse -Force -ErrorAction Continue
      if ($DeleteSource) { Remove-SourceIso $IsoFile }
    }
    else {
      $Status = "Failed (exit $($Process.ExitCode))"
      Write-Warning "runner: $($IsoFile.Name) FAILED after $Minutes minutes; see Customize-* log in $LogDir. Previous output (if any) left in place."
    }
    $Results.Add([PSCustomObject]@{ Iso = $IsoFile.Name; Status = $Status; Minutes = $Minutes })
  }

  # postinstall.iso: .postinstall on a disk image, to attach to VMs as a second CD-ROM
  if (Get-ConfigValue $Config 'BuildPostinstallIso' $true) {
    $PostinstallPath = Join-Path $Config.OutputDirectory 'postinstall.iso'
    $BuiltBefore = Get-ConfigValue (Read-JsonFile "$PostinstallPath.json") 'built'
    & (Join-Path $PSScriptRoot 'New-PostinstallIso.ps1') -OutPath $PostinstallPath -VirtIOIsoPath $VirtIOIso
    $Status = if ($LASTEXITCODE -ne 0) { "Failed (exit $LASTEXITCODE)" }
    elseif ((Get-ConfigValue (Read-JsonFile "$PostinstallPath.json") 'built') -eq $BuiltBefore) { 'UpToDate' }
    else { 'Built' }
    $Results.Add([PSCustomObject]@{ Iso = 'postinstall.iso'; Status = $Status; Minutes = 0 })
  }

  # stale images (source deleted) need someone to act, so they fail the run too
  $Failed = @($Results | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Locked' -or $_.Status -like 'Stale*' })
  $ExitCode = if ($Failed) { 1 } else { 0 }
}
catch {
  $RunError = "$_"
  Write-Host "runner: FAILED: $_"
}
finally {
  Write-Host 'runner: summary:'
  $Results | Format-Table -AutoSize | Out-String | Write-Host

  try { Write-RunSummary } catch { Write-Warning "runner: could not write the run summary: $_" }

  # index.html/index.json in the output directory, whatever happened to the builds
  if ($Acquired -and (Get-ConfigValue $Config 'BuildIndex' $true) -and (Test-Path $Config.OutputDirectory)) {
    try {
      & (Join-Path $PSScriptRoot 'New-ImageIndex.ps1') -OutputDirectory $Config.OutputDirectory -SourceDirectory $Config.InputDirectory `
        -RunSummaryPath (Join-Path $LogDir 'last-run-runner.json')
      if ($LASTEXITCODE -ne 0) { throw "New-ImageIndex.ps1 exited with $LASTEXITCODE" }
    }
    catch {
      Write-Warning "runner: index page: $_"
      $Results.Add([PSCustomObject]@{ Iso = 'index.html'; Status = 'Failed'; Minutes = 0 })
      $ExitCode = 1
      try { Write-RunSummary } catch { Write-Warning "runner: could not write the run summary: $_" }
    }
  }

  # prune old logs and run summaries (last-run-*.json is kept)
  Get-ChildItem $LogDir -File | Where-Object { $_.Name -like '*.log' -or $_.Name -match '-\d{8}-\d{6}\.json$' } |
    Where-Object LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) |
    Remove-Item -Force -ErrorAction Continue

  try { $Mutex.ReleaseMutex() } catch { }
  $Mutex.Dispose()
  Stop-Transcript | Out-Null
}

exit $ExitCode
