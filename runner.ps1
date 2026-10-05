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

# driver sets (DriverSets, or the older VirtIO block): validated in the try block below
. (Join-Path $PSScriptRoot 'DriverSets.ps1')
$DriverSets = @()

# Microsoft Defender update kit for installation images, refreshed once per run
# and applied to every image unless config.json has install.DefenderUpdate = false
$DefenderConfig = Get-ConfigValue $Config 'Defender'
$DefenderEnabled = [bool] (Get-ConfigValue (Get-ConfigValue (Get-Content -Raw $CustomizeConfig | ConvertFrom-Json) 'install') 'DefenderUpdate' $true)
$DefenderUrl = Get-ConfigValue $DefenderConfig 'Url' 'https://go.microsoft.com/fwlink/?linkid=2144531'
$DefenderCache = Get-ConfigValue $DefenderConfig 'CacheDirectory' (Join-Path (Split-Path $Config.WorkingDirectory) 'Cache\defender')
$DefenderRebuildOnSignatures = [bool] (Get-ConfigValue $DefenderConfig 'RebuildOnSignatureUpdate' $false)

# Microsoft 365 Apps for the post-install media (not the images), refreshed once per run
. (Join-Path $PSScriptRoot 'OfficeKit.ps1')
$OfficeConfig = Get-ConfigValue $Config 'Office'
$OfficeEnabled = [bool] (Get-ConfigValue $OfficeConfig 'Enabled' $true)
$OfficeCache = Get-ConfigValue $OfficeConfig 'CacheDirectory' (Join-Path (Split-Path $Config.WorkingDirectory) 'Cache\office')
$OfficeConfiguration = Join-Path $PSScriptRoot '.postinstall\office\configuration.xml'

# current App Installer (WinGet) from microsoft/winget-cli's latest stable release, refreshed
# once per run and provisioned into every image unless config.json has install.UpdateWinGet = false
$WinGetConfig = Get-ConfigValue $Config 'WinGet'
$WinGetEnabled = [bool] (Get-ConfigValue (Get-ConfigValue (Get-Content -Raw $CustomizeConfig | ConvertFrom-Json) 'install') 'UpdateWinGet' $true)
$WinGetRepository = Get-ConfigValue $WinGetConfig 'Repository' 'microsoft/winget-cli'
$WinGetCache = Get-ConfigValue $WinGetConfig 'CacheDirectory' (Join-Path (Split-Path $Config.WorkingDirectory) 'Cache\winget')

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

  $Inputs = @($BuildScript, (Join-Path $PSScriptRoot 'DriverSets.ps1'), (Join-Path $PSScriptRoot 'Profiles.ps1'), $CustomizeConfig, $Autounattend) +
    @(Get-ChildItem (Join-Path $PSScriptRoot 'stub-scripts') -File -Recurse | Sort-Object FullName | ForEach-Object FullName) +
    # the disk picker's WinPE files (not winpe\tests)
    @(Get-ChildItem (Join-Path $PSScriptRoot 'winpe') -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object FullName)
  $Hashes = $Inputs | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_).Hash }
  if ($RecoveryWim -and (Test-Path $RecoveryWim)) {
    $Item = Get-Item $RecoveryWim
    $Hashes += "winre:$($Item.Length):$($Item.LastWriteTimeUtc.Ticks)"
  }
  # a replaced virtio-win ISO, changed driver folder or set definition rebuilds everything
  foreach ($Set in $DriverSets) { $Hashes += Get-DriverSetFingerprint $Set }
  # a Defender kit with a new platform or engine (monthly) rebuilds everything;
  # signature-only kit refreshes don't, unless Defender.RebuildOnSignatureUpdate
  if ($DefenderEnabled) {
    $Defender = 'defender:none'
    if ($DefenderKit) { $Defender = "defender:$($DefenderKit.Platform):$($DefenderKit.Engine)" }
    if ($DefenderKit -and $DefenderRebuildOnSignatures) { $Defender += ":$($DefenderKit.Signatures)" }
    $Hashes += $Defender
  }
  # a new WinGet release rebuilds everything
  if ($WinGetEnabled) { $Hashes += "winget:$(if ($WinGetKit) { $WinGetKit.Release } else { 'none' })" }

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

#region winget

# A prepared WinGet kit folder: the msixbundle and x64 dependencies signed by Microsoft,
# plus the license. Throws otherwise.
function Get-WinGetKit([string] $Directory) {
  $Bundle = Join-Path $Directory 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
  $License = @(Get-ChildItem -LiteralPath $Directory -Filter '*License*.xml' -File -ErrorAction SilentlyContinue)
  $Dependencies = @(Get-ChildItem -LiteralPath (Join-Path $Directory 'x64') -Filter '*.appx' -File -ErrorAction SilentlyContinue)
  if (-not (Test-Path $Bundle) -or $License.Count -ne 1 -or -not $Dependencies) { throw "$Directory doesn't hold the msixbundle, one license and x64\*.appx dependencies." }
  foreach ($File in @($Bundle) + @($Dependencies | ForEach-Object FullName)) {
    if (-not (Test-MicrosoftSignature $File)) { throw "$File is not validly signed by Microsoft; refusing the kit." }
  }
  [PSCustomObject]@{ Root = $Directory; Release = "$(Get-Content -Raw (Join-Path $Directory 'release.txt'))".Trim() }
}

# Refresh the cached kit when the latest stable release on GitHub has a new tag, then
# return the cached kit (or $null). Downloads are checked against the SHA-256 the
# release publishes next to them, then for Microsoft signatures, before they replace a
# good cached kit. Best effort: a failed refresh keeps the cached kit.
function Update-WinGetKit {
  $Current = Join-Path $WinGetCache 'current'
  New-Item -ItemType Directory -Force -Path $WinGetCache | Out-Null

  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # /releases/latest skips prereleases
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$WinGetRepository/releases/latest" -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'Customize-WindowsIso' }
    $Cached = if (Test-Path (Join-Path $Current 'release.txt')) { "$(Get-Content -Raw (Join-Path $Current 'release.txt'))".Trim() }

    if ($Cached -eq $Release.tag_name) {
      Write-Host "runner: WinGet $Cached is current (published $($Release.published_at))."
    }
    else {
      Write-Host "runner: downloading WinGet $($Release.tag_name) (cached: $(if ($Cached) { $Cached } else { 'none' }))."
      $New = Join-Path $WinGetCache 'new'
      if (Test-Path $New) { Remove-Item $New -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $New | Out-Null

      function Get-Asset([string] $Pattern) {
        $Asset = @($Release.assets | Where-Object name -like $Pattern)
        if ($Asset.Count -ne 1) { throw "release $($Release.tag_name) has $($Asset.Count) assets matching '$Pattern'." }
        $Path = Join-Path $New $Asset[0].name
        Invoke-WebRequest -Uri $Asset[0].browser_download_url -OutFile $Path -UseBasicParsing -TimeoutSec 1800
        $Path
      }
      function Assert-Sha256([string] $File, [string] $HashFile) {
        $Expected = "$(Get-Content -Raw $HashFile)".Trim()
        $Actual = (Get-FileHash -Algorithm SHA256 $File).Hash
        if ($Actual -ne $Expected) { throw "$(Split-Path -Leaf $File) has SHA-256 $Actual, the release says $Expected." }
      }

      $Bundle = Get-Asset 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
      Assert-Sha256 $Bundle (Get-Asset 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt')
      $DependencyZip = Get-Asset 'DesktopAppInstaller_Dependencies.zip'
      Assert-Sha256 $DependencyZip (Get-Asset 'DesktopAppInstaller_Dependencies.txt')
      Get-Asset '*License1.xml' | Out-Null

      # only the x64 dependencies are kept; the images are amd64
      $Extract = Join-Path $New 'dependencies'
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::ExtractToDirectory($DependencyZip, $Extract)
      Move-Item (Join-Path $Extract 'x64') (Join-Path $New 'x64')
      Remove-Item $Extract, $DependencyZip -Recurse -Force
      Get-ChildItem $New -Filter '*.txt' -File | Remove-Item -Force
      Set-Content -Encoding ascii -NoNewline -Path (Join-Path $New 'release.txt') -Value $Release.tag_name

      # verify before it replaces a good cached kit
      Get-WinGetKit $New | Out-Null
      $Old = "$Current.old"
      if (Test-Path $Old) { Remove-Item $Old -Recurse -Force }
      if (Test-Path $Current) { Rename-Item $Current (Split-Path -Leaf $Old) }
      Rename-Item $New (Split-Path -Leaf $Current)
      if (Test-Path $Old) { Remove-Item $Old -Recurse -Force }
      Write-Host "runner: WinGet $($Release.tag_name) downloaded and verified."
    }
  }
  catch {
    Write-Warning "runner: couldn't refresh WinGet from github.com/$($WinGetRepository): $_ Using the cached kit, if any."
  }

  if (-not (Test-Path $Current)) {
    Write-Warning "runner: no WinGet kit in $WinGetCache; images keep the App Installer from their media."
    return
  }
  try {
    $Kit = Get-WinGetKit $Current
    Write-Host "runner: provisioning WinGet $($Kit.Release)."
    $Kit
  }
  catch {
    Write-Warning "runner: cached WinGet kit can't be used: $_ Images keep the App Installer from their media."
  }
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

  # configured but missing: Get-DriverSets fails rather than quietly building images without the drivers
  $DriverSets = @(Get-DriverSets $Config)
  foreach ($Set in $DriverSets) {
    Write-Host "runner: driver set '$($Set.Name)' ($($Set.Type)) from $($Set.Path) to $($Set.Targets -join ', ')$(if ($Set.Drivers) { ": $($Set.Drivers -join ', ')" })."
  }
  # postinstall.iso gets the guest tools from the (first) virtio-win ISO
  $VirtIOIso = @($DriverSets | Where-Object Type -eq 'virtio-iso' | ForEach-Object Path) | Select-Object -First 1
  if (-not $VirtIOIso) { $VirtIOIso = '' }

  # once per run, before fingerprinting: the kit version is part of the fingerprint
  $DefenderKit = $null
  if ($DefenderEnabled) { $DefenderKit = Update-DefenderKit }
  $WinGetKit = $null
  if ($WinGetEnabled) { $WinGetKit = Update-WinGetKit }

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
    if ($DriverSets) {
      # structured data doesn't survive a powershell.exe -File command line; hand over a file
      New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null
      $DriverSetsFile = Join-Path $WorkingDirectory 'driversets.json'
      [PSCustomObject]@{ DriverSets = $DriverSets } | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 -Path $DriverSetsFile
      $Arguments += @('-DriverSetsFile', "`"$DriverSetsFile`"")
    }
    if ($KeepPrevious) { $Arguments += '-KeepPrevious' }
    if ($DefenderKit) { $Arguments += @('-DefenderPackage', "`"$($DefenderKit.Cab)`"") }
    if ($WinGetKit) { $Arguments += @('-WinGetPackage', "`"$($WinGetKit.Root)`"") }

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

  # postinstall.iso: .postinstall on a disk image, to attach to VMs as a second CD-ROM,
  # and the same tree as a folder (PostinstallFolder) to copy to USB/Ventoy drives
  if (Get-ConfigValue $Config 'BuildPostinstallIso' $true) {
    # after the images: a new Office build is a multi-GB download
    $OfficeKit = $null
    if ($OfficeEnabled) { $OfficeKit = Update-OfficeKit $OfficeCache $OfficeConfiguration }

    $PostinstallPath = Join-Path $Config.OutputDirectory 'postinstall.iso'
    $PostinstallArguments = @{ OutPath = $PostinstallPath; VirtIOIsoPath = $VirtIOIso }
    if ($OfficeKit) { $PostinstallArguments.OfficePath = $OfficeKit.Root }
    $PostinstallFolder = Get-ConfigValue $Config 'PostinstallFolder' (Join-Path $Config.OutputDirectory 'postinstall')
    if ($PostinstallFolder) { $PostinstallArguments.FolderPath = $PostinstallFolder }
    $BuiltBefore = Get-ConfigValue (Read-JsonFile "$PostinstallPath.json") 'built'
    & (Join-Path $PSScriptRoot 'New-PostinstallIso.ps1') @PostinstallArguments
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
