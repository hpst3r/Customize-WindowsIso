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

Exit code is 0 if every ISO succeeded or was skipped, 1 otherwise.
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

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir "runner-$(Get-Date -Format yyyyMMdd-HHmmss).log") | Out-Null

# only one runner at a time - a long build must not collide with next week's
$Mutex = New-Object System.Threading.Mutex($false, 'Global\Customize-WindowsIso-Runner')
$Results = [System.Collections.Generic.List[object]]::new()
$ExitCode = 1

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

  $IsoFiles = @(Get-ChildItem -Path $Config.InputDirectory -Filter '*.iso' -File | Sort-Object Name)
  Write-Host "runner: found $($IsoFiles.Count) ISO(s): $(@($IsoFiles | ForEach-Object Name) -join ', ')"

  foreach ($IsoFile in $IsoFiles) {
    $OutPath = Join-Path $Config.OutputDirectory $IsoFile.Name
    $WorkingDirectory = Join-Path $Config.WorkingDirectory ($IsoFile.BaseName -replace '[^\w.-]', '')
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if (Test-FileLocked $IsoFile.FullName) {
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
        continue
      }
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

    $Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    $Minutes = [math]::Round($Stopwatch.Elapsed.TotalMinutes, 1)

    if ($Process.ExitCode -eq 0) {
      $Warnings = @(Get-ConfigValue (Get-Content -Raw $ManifestPath | ConvertFrom-Json) 'warnings' @())
      $Status = if ($Warnings) { "OK ($($Warnings.Count) warnings)" } else { 'OK' }
      Write-Host "runner: $($IsoFile.Name) done in $Minutes minutes: $Status."
      # keep the working directory on failure for troubleshooting; it is reused next run
      Remove-Item $WorkingDirectory -Recurse -Force -ErrorAction Continue
    }
    else {
      $Status = "Failed (exit $($Process.ExitCode))"
      Write-Warning "runner: $($IsoFile.Name) FAILED after $Minutes minutes; see Customize-* log in $LogDir. Previous output (if any) left in place."
    }
    $Results.Add([PSCustomObject]@{ Iso = $IsoFile.Name; Status = $Status; Minutes = $Minutes })
  }

  # postinstall.iso: .postinstall on a disk image, to attach to VMs as a second CD-ROM
  if (Get-ConfigValue $Config 'BuildPostinstallIso' $true) {
    & (Join-Path $PSScriptRoot 'New-PostinstallIso.ps1') -OutPath (Join-Path $Config.OutputDirectory 'postinstall.iso') -VirtIOIsoPath $VirtIOIso
    $Status = if ($LASTEXITCODE -eq 0) { 'OK' } else { "Failed (exit $LASTEXITCODE)" }
    $Results.Add([PSCustomObject]@{ Iso = 'postinstall.iso'; Status = $Status; Minutes = 0 })
  }

  $Failed = @($Results | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Locked' })
  $ExitCode = if ($Failed) { 1 } else { 0 }
}
catch {
  Write-Host "runner: FAILED: $_"
}
finally {
  Write-Host 'runner: summary:'
  $Results | Format-Table -AutoSize | Out-String | Write-Host

  # prune old logs
  Get-ChildItem $LogDir -Filter '*.log' -File |
    Where-Object LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) |
    Remove-Item -Force -ErrorAction Continue

  try { $Mutex.ReleaseMutex() } catch { }
  $Mutex.Dispose()
  Stop-Transcript | Out-Null
}

exit $ExitCode
