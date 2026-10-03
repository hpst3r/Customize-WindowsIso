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

# Microsoft Defender update kit for installation images, refreshed once per run
# and applied to every image unless config.json has install.DefenderUpdate = false
$DefenderConfig = Get-ConfigValue $Config 'Defender'
$DefenderEnabled = [bool] (Get-ConfigValue (Get-ConfigValue (Get-Content -Raw $CustomizeConfig | ConvertFrom-Json) 'install') 'DefenderUpdate' $true)
$DefenderUrl = Get-ConfigValue $DefenderConfig 'Url' 'https://go.microsoft.com/fwlink/?linkid=2144531'
$DefenderCache = Get-ConfigValue $DefenderConfig 'CacheDirectory' (Join-Path (Split-Path $Config.WorkingDirectory) 'Cache\defender')
$DefenderRebuildOnSignatures = [bool] (Get-ConfigValue $DefenderConfig 'RebuildOnSignatureUpdate' $false)

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
  # a Defender kit with a new platform or engine (monthly) rebuilds everything;
  # signature-only kit refreshes don't, unless Defender.RebuildOnSignatureUpdate
  if ($DefenderEnabled) {
    $Defender = 'defender:none'
    if ($DefenderKit) { $Defender = "defender:$($DefenderKit.Platform):$($DefenderKit.Engine)" }
    if ($DefenderKit -and $DefenderRebuildOnSignatures) { $Defender += ":$($DefenderKit.Signatures)" }
    $Hashes += $Defender
  }

  $Bytes = [System.Text.Encoding]::UTF8.GetBytes((@($Source) + $Hashes) -join '|')
  $Sha = [System.Security.Cryptography.SHA256]::Create()
  try { -join ($Sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $Sha.Dispose() }
}

# true if another process still has the file open for writing (e.g. it is still being copied in)
function Test-FileLocked([string] $Path) {
  try { [System.IO.File]::Open($Path, 'Open', 'Read', 'Read').Dispose(); $false } catch { $true }
}

#region defender

# true if $Path has a valid Authenticode signature from Microsoft, chaining to a Microsoft root
function Test-MicrosoftSignature([string] $Path) {
  $Signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { return $false }
  $Chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
  $Chain.ChainPolicy.RevocationMode = 'NoCheck'
  try {
    $Chain.Build($Signature.SignerCertificate) | Out-Null
    $Root = $Chain.ChainElements[$Chain.ChainElements.Count - 1].Certificate
    $Root.Subject -match '^CN=Microsoft Root Certificate Authority'
  }
  finally { $Chain.Dispose() }
}

# An extracted defender-update-kit: check the cab and script are signed by
# Microsoft and read the versions from the cab's package-defender.xml. Throws otherwise.
function Get-DefenderKit([string] $Directory) {
  $Cab = @(Get-ChildItem -LiteralPath $Directory -Filter 'defender-dism-*.cab' -File -ErrorAction SilentlyContinue)
  $Script = Join-Path $Directory 'DefenderUpdateWinImage.ps1'
  if ($Cab.Count -ne 1 -or -not (Test-Path $Script)) { throw "$Directory doesn't hold one defender-dism-*.cab and DefenderUpdateWinImage.ps1." }
  foreach ($File in $Cab[0].FullName, $Script) {
    if (-not (Test-MicrosoftSignature $File)) { throw "$File is not validly signed by Microsoft; refusing the kit." }
  }

  $Temporary = Join-Path $DefenderCache 'xml'
  if (Test-Path $Temporary) { Remove-Item $Temporary -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Temporary | Out-Null
  try {
    $Output = & expand.exe $Cab[0].FullName '-F:package-defender.xml' $Temporary 2>&1
    if ($LASTEXITCODE -ne 0) { throw "expand.exe failed with exit code $($LASTEXITCODE): $Output" }
    [xml] $Xml = Get-Content -Raw (Join-Path $Temporary 'package-defender.xml')
  }
  finally { Remove-Item $Temporary -Recurse -Force -ErrorAction Continue }

  [PSCustomObject]@{
    Cab        = $Cab[0].FullName
    Package    = "$($Xml.packageinfo.versions.defender)"
    Platform   = "$($Xml.packageinfo.versions.platform)"
    Engine     = "$($Xml.packageinfo.versions.engine)"
    Signatures = "$($Xml.packageinfo.versions.signatures)"
  }
}

# Refresh the cached kit if Microsoft's copy changed, then return the cached kit
# (or $null). The fwlink redirects to a blob whose URL carries the package
# version; that URL, ETag, Last-Modified and size identify it without downloading.
# Best effort: a failed refresh keeps the cached kit; no usable kit means no update.
function Update-DefenderKit {
  $Current = Join-Path $DefenderCache 'current'
  $StateFile = Join-Path $DefenderCache 'kit.json'
  New-Item -ItemType Directory -Force -Path $DefenderCache | Out-Null

  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Head = Invoke-WebRequest -Uri $DefenderUrl -Method Head -UseBasicParsing -TimeoutSec 120
    $Remote = [ordered]@{
      source       = $Head.BaseResponse.ResponseUri.AbsoluteUri
      etag         = "$($Head.Headers['ETag'])"
      lastModified = "$($Head.Headers['Last-Modified'])"
      length       = "$($Head.Headers['Content-Length'])"
    }
    $State = if (Test-Path $StateFile) { Get-Content -Raw $StateFile | ConvertFrom-Json }
    $Changed = @($Remote.Keys | Where-Object { "$(Get-ConfigValue $State $_)" -ne $Remote[$_] })

    if (-not $Changed -and (Test-Path $Current)) {
      Write-Host "runner: Defender update kit $(Get-ConfigValue $State 'package') is current (published $($Remote.lastModified))."
    }
    else {
      Write-Host "runner: downloading the Defender update kit from $($Remote.source)."
      $Zip = Join-Path $DefenderCache 'download.zip'
      $New = Join-Path $DefenderCache 'new'
      foreach ($Path in $Zip, $New) { if (Test-Path $Path) { Remove-Item $Path -Recurse -Force } }

      Invoke-WebRequest -Uri $Remote.source -OutFile $Zip -UseBasicParsing -TimeoutSec 1800
      if ($Remote.length -and (Get-Item $Zip).Length -ne [int64] $Remote.length) {
        throw "downloaded $((Get-Item $Zip).Length) bytes, expected $($Remote.length)."
      }
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $New)
      # verify before it replaces a good cached kit
      $Kit = Get-DefenderKit $New

      $Old = "$Current.old"
      if (Test-Path $Old) { Remove-Item $Old -Recurse -Force }
      if (Test-Path $Current) { Rename-Item $Current (Split-Path -Leaf $Old) }
      Rename-Item $New (Split-Path -Leaf $Current)
      foreach ($Path in $Old, $Zip) { if (Test-Path $Path) { Remove-Item $Path -Recurse -Force } }

      $Remote['package'] = $Kit.Package
      $Remote['downloaded'] = (Get-Date -Format o)
      [PSCustomObject] $Remote | ConvertTo-Json | Set-Content -Encoding utf8 -Path $StateFile
      Write-Host "runner: Defender update kit $($Kit.Package) downloaded: platform $($Kit.Platform), engine $($Kit.Engine), security intelligence $($Kit.Signatures)."
    }
  }
  catch {
    Write-Warning "runner: couldn't refresh the Defender update kit from $($DefenderUrl): $_ Using the cached kit, if any."
  }

  if (-not (Test-Path $Current)) {
    Write-Warning "runner: no Defender update kit in $DefenderCache; images keep the Defender version from their media."
    return
  }
  try {
    $Kit = Get-DefenderKit $Current
    Write-Host "runner: applying Defender update kit $($Kit.Package) (platform $($Kit.Platform), engine $($Kit.Engine), security intelligence $($Kit.Signatures))."
    $Kit
  }
  catch {
    # forget the cached identity so the next run downloads it again
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Warning "runner: cached Defender update kit can't be used: $_ Images keep the Defender version from their media."
  }
}

#endregion

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

  # once per run, before fingerprinting: the kit version is part of the fingerprint
  $DefenderKit = $null
  if ($DefenderEnabled) { $DefenderKit = Update-DefenderKit }

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
    if ($DefenderKit) { $Arguments += @('-DefenderPackage', "`"$($DefenderKit.Cab)`"") }

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
