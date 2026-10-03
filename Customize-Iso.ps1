#Requires -Version 5.1 -RunAsAdministrator

<#
.SYNOPSIS
Customizes a Windows ISO: removes unwanted packages, applies offline registry
settings, adds an autounattend.xml and post-install stubs, and builds a new ISO.

.DESCRIPTION
Every image (index) in install.wim is customized, not just the first.

The script cleans up after itself on failure (dismounts images without saving,
unloads registry hives, dismounts the source ISO) so a failed run does not
poison the next one, and it only replaces -OutPath once the new ISO has been
built and verified.

Exit code is 0 on success and 1 on failure.

.EXAMPLE
.\Customize-Iso.ps1 -IsoPath Y:\Images\Standard\WindowsServer2025.iso -WorkingDir Y:\IsoBuild\Customize\ws2025 -OutPath Y:\Images\Customized\WindowsServer2025.iso
#>
param (
  [Parameter(Mandatory = $true)]
  [string] $IsoPath,
  [Parameter(Mandatory = $true)]
  [string] $WorkingDir,
  # defaults: config.json, autounattend.xml and logs\ next to this script
  [string] $ConfigFile,
  [string] $Autounattend,
  # optional: only used if an image has no WinRE of its own
  [string] $WinREWimPath,
  # default: Customized.iso in the working directory
  [string] $OutPath,
  [string] $LogDir,
  # opaque string recorded in the output manifest; runner.ps1 uses it to skip unchanged inputs
  [string] $Fingerprint,
  # optional: a virtio-win ISO. The drivers below are added to boot.wim (so Setup
  # sees virtio disks) and to every image in install.wim (so it boots from them).
  [string] $VirtIOIsoPath,
  # comma-separated driver folders from the virtio-win ISO
  [string] $VirtIODrivers = 'vioscsi,viostor,NetKVM',
  # optional: defender-dism-<arch>.cab from Microsoft's "Defender update for Windows
  # operating system installation images" kit (or the folder holding it). Applied to
  # every image in install.wim unless config.json has install.DefenderUpdate = false.
  [string] $DefenderPackage
)

# Windows PowerShell leaves $PSScriptRoot empty while evaluating parameter
# defaults in an advanced script, so path defaults are resolved here instead
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.json' }
if (-not $Autounattend) { $Autounattend = Join-Path $PSScriptRoot 'autounattend.xml' }
if (-not $OutPath) { $OutPath = Join-Path $WorkingDir 'Customized.iso' }
if (-not $LogDir) { $LogDir = Join-Path $PSScriptRoot 'logs' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# working directories
$ScratchPath = Join-Path $WorkingDir 'Scratch'
$MountDir = Join-Path $WorkingDir 'Mount'
$DismScratch = Join-Path $WorkingDir 'DismScratch'
$StagingIso = Join-Path $WorkingDir 'staging.iso'

# state tracked so the finally block can clean up whatever is still open
$script:LoadedHives = [System.Collections.Generic.List[string]]::new()
$script:Warnings = [System.Collections.Generic.List[string]]::new()
$script:Removed = [System.Collections.Generic.List[string]]::new()
$script:DriversAdded = [System.Collections.Generic.List[string]]::new()
$script:VirtIORoot = $null
$script:VirtIOMountedHere = $false
$script:VirtIODriverList = @($VirtIODrivers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# expanded Defender package (if any), the manifest's "defender" entry, and per-image results
$script:Defender = $null
$script:DefenderSummary = $null
$script:DefenderImages = [System.Collections.Generic.List[object]]::new()

# offline hive files, relative to the root of a mounted image.
# DEFAULTUSER is the template profile copied for new users. The DEFAULT hive in
# System32\config is the SYSTEM/logon screen profile and does not affect users.
$HiveFiles = @{
  SOFTWARE    = 'Windows\System32\config\SOFTWARE'
  SYSTEM      = 'Windows\System32\config\SYSTEM'
  DEFAULTUSER = 'Users\Default\NTUSER.DAT'
}

function Add-BuildWarning([string] $Message) {
  Write-Warning $Message
  $script:Warnings.Add($Message)
}

# return a property of a PSCustomObject, or $Default if it is missing (StrictMode-safe)
function Get-ConfigValue($Object, [string] $Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}

# Run a native command, capture its output, and throw on a non-zero exit code.
# Windows PowerShell turns redirected stderr into terminating errors under
# $ErrorActionPreference = 'Stop', so it is relaxed for the call.
function Invoke-Native {
  param (
    [Parameter(Mandatory = $true)]
    [string] $FilePath,
    [string[]] $ArgumentList = @(),
    [int[]] $SuccessExitCodes = @(0),
    [switch] $AllowFailure
  )

  $PreviousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $Output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
    $ExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $PreviousPreference
  }

  # drop progress-bar lines (dism, robocopy) so errors stay readable
  $Output = @($Output | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*\[[= ]*\d+(\.\d+)?%[= ]*\]\s*$' })

  if ($SuccessExitCodes -notcontains $ExitCode -and -not $AllowFailure) {
    throw "Invoke-Native: '$FilePath $($ArgumentList -join ' ')' failed with exit code $($ExitCode): $(($Output | Select-Object -Last 15) -join ' | ')"
  }

  $Output | Write-Verbose
  [PSCustomObject]@{ ExitCode = $ExitCode; Output = $Output }
}

#region dism

# Servicing goes through dism.exe child processes rather than the DISM
# PowerShell cmdlets. The cmdlets load the image's servicing stack (CBS) into
# this process, and transactions it leaves open (e.g. after removing a
# capability) make the later commit fail with 0x80071A90 and the discard hang.
# A dism.exe process closes everything when it exits.
function Find-Dism {
  $Adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe"
  if (Test-Path $Adk) { return $Adk }
  Join-Path $env:SystemRoot 'System32\dism.exe'
}

function Invoke-Dism([string[]] $Arguments, [switch] $AllowFailure) {
  $Common = @('/English', "/LogPath:$(Join-Path $WorkingDir 'dism.log')")
  # /ScratchDir only applies to commands that service an image
  if ($Arguments -match '^/Image:') { $Common += "/ScratchDir:$DismScratch" }
  # 3010 = success, reboot required (meaningless offline)
  Invoke-Native $script:Dism ($Arguments + $Common) -SuccessExitCodes @(0, 3010) -AllowFailure:$AllowFailure
}

# /Optimize mounts faster but leaves files unhydrated; newer servicing stacks
# (seen on 29xxx) then fail capability removal with 4350 (ERROR_FILE_OFFLINE).
# Only use it for images that just get registry edits.
function Mount-Wim([string] $ImageFile, [int] $Index, [switch] $Optimize) {
  $Arguments = @('/Mount-Image', "/ImageFile:$ImageFile", "/Index:$Index", "/MountDir:$MountDir")
  if ($Optimize) { $Arguments += '/Optimize' }
  Invoke-Dism $Arguments | Out-Null
}

function Dismount-Wim([switch] $Commit) {
  $Mode = if ($Commit) { '/Commit' } else { '/Discard' }
  Invoke-Dism @('/Unmount-Image', "/MountDir:$MountDir", $Mode) | Out-Null
}

# dism /Get-ProvisionedAppxPackages prints "Key : Value" blocks separated by blank lines
function Get-ProvisionedAppx([string] $ImageRoot) {
  $Result = Invoke-Dism @("/Image:$ImageRoot", '/Get-ProvisionedAppxPackages') -AllowFailure
  # Server Core has no AppX servicing provider, so DISM doesn't know the option
  if ($Result.ExitCode -eq 87 -and ($Result.Output -match 'option is unknown')) {
    Write-Host "Get-ProvisionedAppx: image has no AppX support (e.g. Server Core); nothing to remove."
    return
  }
  if ($Result.ExitCode -ne 0) { throw "Get-ProvisionedAppx: dism failed with exit code $($Result.ExitCode): $(($Result.Output | Select-Object -Last 10) -join ' | ')" }

  $Current = @{}
  foreach ($Line in $Result.Output) {
    if ($Line -match '^\s*(DisplayName|PackageName)\s*:\s*(.+?)\s*$') { $Current[$Matches[1]] = $Matches[2] }
    if ($Current.ContainsKey('PackageName') -and $Current.ContainsKey('DisplayName')) {
      [PSCustomObject]@{ DisplayName = $Current.DisplayName; PackageName = $Current.PackageName }
      $Current = @{}
    }
  }
}

# names from a "/Format:Table" listing ("Name | State | ...") whose state is Installed
function Get-InstalledFromTable([string] $ImageRoot, [string] $Command) {
  foreach ($Line in (Invoke-Dism @("/Image:$ImageRoot", $Command, '/Format:Table')).Output) {
    $Columns = @($Line -split '\|' | ForEach-Object { $_.Trim() })
    if ($Columns.Count -ge 2 -and $Columns[1] -eq 'Installed') { $Columns[0] }
  }
}

#endregion

#region registry

function Mount-OfflineHive([string] $ImageRoot, [string] $Hive) {
  # PID in the key name so concurrent runs can never write into each other's hives
  $Key = "HKLM\CWI_$($PID)_$($Hive)"
  $File = Join-Path $ImageRoot $HiveFiles[$Hive]

  if (-not (Test-Path $File)) { throw "Mount-OfflineHive: hive file not found: $File" }

  Invoke-Native reg.exe @('load', $Key, $File) | Out-Null
  $script:LoadedHives.Add($Key)
  $Key
}

function Dismount-OfflineHive([string] $Key) {
  # unload can fail while something still holds a handle - collect and retry
  for ($Attempt = 1; $Attempt -le 10; $Attempt++) {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if ((Invoke-Native reg.exe @('unload', $Key) -AllowFailure).ExitCode -eq 0) {
      $script:LoadedHives.Remove($Key) | Out-Null
      return
    }
    Start-Sleep -Seconds 3
  }
  throw "Dismount-OfflineHive: failed to unload $Key"
}

# Apply registry groups from config to a mounted image.
# Each group: { Name, Enabled, Description, Values: [ { Hive, Key, Name, Type, Data } | { Hive, Key, Name?, Delete: true } ] }
function Set-ImageRegistry([string] $ImageRoot, [object[]] $Groups) {
  $Groups = @($Groups | Where-Object { Get-ConfigValue $_ 'Enabled' $true })
  if (-not $Groups) { Write-Host 'Set-ImageRegistry: no registry groups enabled.'; return }

  $Hives = @{}
  try {
    foreach ($HiveName in @($Groups.Values.Hive | Sort-Object -Unique)) {
      if (-not $HiveFiles.ContainsKey($HiveName)) { throw "Set-ImageRegistry: unknown hive '$HiveName' (valid: $($HiveFiles.Keys -join ', '))" }
      $Hives[$HiveName] = Mount-OfflineHive $ImageRoot $HiveName
    }

    foreach ($Group in $Groups) {
      Write-Host "Set-ImageRegistry: applying '$($Group.Name)'."

      foreach ($Value in $Group.Values) {
        $Key = "$($Hives[$Value.Hive])\$($Value.Key)"
        $Name = Get-ConfigValue $Value 'Name'

        if (Get-ConfigValue $Value 'Delete' $false) {
          $Arguments = @('delete', $Key, '/f')
          if ($Name) { $Arguments = @('delete', $Key, '/v', $Name, '/f') }
          # a missing key/value is fine - the goal is for it not to exist
          Invoke-Native reg.exe $Arguments -AllowFailure | Out-Null
        }
        else {
          Invoke-Native reg.exe @('add', $Key, '/v', $Name, '/t', $Value.Type, '/d', "$($Value.Data)", '/f') | Out-Null
        }
      }
    }
  }
  finally {
    foreach ($Key in @($Hives.Values)) { Dismount-OfflineHive $Key }
  }
}

#endregion

#region packages

function Remove-ImagePackages([string] $ImageRoot, $PackageConfig, [string] $ImageLabel) {
  # enumerate each type once per image - these calls take seconds to minutes each

  $AppxPatterns = @(Get-ConfigValue $PackageConfig 'AppXPackagesToRemove' @())
  if ($AppxPatterns) {
    $Provisioned = @(Get-ProvisionedAppx $ImageRoot)
    Write-Host "Remove-ImagePackages: $($Provisioned.Count) provisioned AppX package(s) in $ImageLabel."
    foreach ($Package in $Provisioned) {
      if (-not ($AppxPatterns | Where-Object { $Package.PackageName -like $_ -or $Package.DisplayName -like $_ })) { continue }
      Write-Host "Remove-ImagePackages: removing AppX $($Package.PackageName)"
      try {
        Invoke-Dism @("/Image:$ImageRoot", '/Remove-ProvisionedAppxPackage', "/PackageName:$($Package.PackageName)") | Out-Null
        $script:Removed.Add("$($ImageLabel): appx $($Package.DisplayName)")
      }
      catch { Add-BuildWarning "$($ImageLabel): failed to remove AppX $($Package.PackageName): $_" }
    }
  }

  $CapabilityPatterns = @(Get-ConfigValue $PackageConfig 'WindowsCapabilitiesToRemove' @())
  if ($CapabilityPatterns) {
    foreach ($Capability in @(Get-InstalledFromTable $ImageRoot '/Get-Capabilities')) {
      if (-not ($CapabilityPatterns | Where-Object { $Capability -like $_ })) { continue }
      Write-Host "Remove-ImagePackages: removing capability $Capability"
      try {
        Invoke-Dism @("/Image:$ImageRoot", '/Remove-Capability', "/CapabilityName:$Capability") | Out-Null
        $script:Removed.Add("$($ImageLabel): capability $Capability")
      }
      catch { Add-BuildWarning "$($ImageLabel): failed to remove capability $($Capability): $_" }
    }
  }

  $PackagePatterns = @(Get-ConfigValue $PackageConfig 'WindowsPackagesToRemove' @())
  if ($PackagePatterns) {
    foreach ($Package in @(Get-InstalledFromTable $ImageRoot '/Get-Packages')) {
      if (-not ($PackagePatterns | Where-Object { $Package -like $_ })) { continue }
      Write-Host "Remove-ImagePackages: removing package $Package"
      try {
        Invoke-Dism @("/Image:$ImageRoot", '/Remove-Package', "/PackageName:$Package") | Out-Null
        $script:Removed.Add("$($ImageLabel): package $Package")
      }
      catch { Add-BuildWarning "$($ImageLabel): failed to remove package $($Package): $_" }
    }
  }
}

#endregion

#region images

# Dismount any image left mounted under this working directory, discard
# changes, and drop stale mount points. Safe to call at any time.
function Clear-StaleMounts {
  foreach ($Image in @(Get-WindowsImage -Mounted)) {
    if ($Image.Path -like "$($WorkingDir)*") {
      Write-Host "Clear-StaleMounts: discarding mounted image at $($Image.Path) (status $($Image.MountStatus))."
      $Result = Invoke-Dism @('/Unmount-Image', "/MountDir:$($Image.Path)", '/Discard') -AllowFailure
      if ($Result.ExitCode -ne 0) { Write-Warning "Clear-StaleMounts: dismount failed for $($Image.Path): $($Result.Output -join ' | ')" }
    }
  }
  Invoke-Dism @('/Cleanup-Mountpoints') -AllowFailure | Out-Null
}

# Volume of an attached ISO. The drive letter can take a moment to appear after mounting.
function Get-IsoVolume($DiskImage, [string] $Path) {
  for ($i = 0; $i -lt 30; $i++) {
    $Volume = $DiskImage | Get-Volume -ErrorAction SilentlyContinue
    if ($Volume -and $Volume.DriveLetter) { return $Volume }
    Start-Sleep -Seconds 1
  }
  throw "Get-IsoVolume: $Path mounted but no drive letter was assigned."
}

# Copy the ISO contents to $Destination. Returns the ISO's volume label.
function Copy-IsoContents([string] $Path, [string] $Destination) {
  $DiskImage = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly -PassThru
  try {
    $Volume = Get-IsoVolume $DiskImage $Path

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    # /A-:R clears read-only as files are copied. Robocopy exit codes 0-7 are success.
    Invoke-Native robocopy.exe @("$($Volume.DriveLetter):\", $Destination, '/E', '/A-:R', '/R:3', '/W:5', '/MT:8', '/NP', '/NFL', '/NDL') `
      -SuccessExitCodes (0..7) | Out-Null

    $Volume.FileSystemLabel
  }
  finally {
    Dismount-DiskImage -ImagePath $Path | Out-Null
  }
}

function Get-SetupBootIndex([string] $BootWim) {
  $Images = @(Get-WindowsImage -ImagePath $BootWim)
  # "Microsoft Windows Setup (x64)" on client media, "(amd64)" on some server media
  $Setup = $Images | Where-Object ImageName -like 'Microsoft Windows Setup*' | Select-Object -Last 1
  if ($Setup) { return $Setup.ImageIndex }
  # boot.wim index 2 is Setup by convention
  if ($Images.Count -ge 2) { return 2 }
  throw "Get-SetupBootIndex: could not find the Setup image in $BootWim"
}

function Set-InstallImage([string] $InstallWim, $Config) {
  $Images = @(Get-WindowsImage -ImagePath $InstallWim)
  Write-Host "Set-InstallImage: $($Images.Count) image(s) in $($InstallWim): $(($Images | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" }) -join ', ')"

  foreach ($Image in $Images) {
    $Label = "[$($Image.ImageIndex)] $($Image.ImageName)"
    Write-Host "Set-InstallImage: mounting $Label."

    $Detail = Get-WindowsImage -ImagePath $InstallWim -Index $Image.ImageIndex
    Mount-Wim -ImageFile $InstallWim -Index $Image.ImageIndex
    $Saved = $false
    try {
      Set-WinRE -ImageRoot $MountDir -ImageLabel $Label -ImageVersion $Detail.Version

      Write-Host "Set-InstallImage: removing packages from $Label."
      Remove-ImagePackages -ImageRoot $MountDir -PackageConfig $Config.install.Packages -ImageLabel $Label

      Write-Host "Set-InstallImage: applying registry settings to $Label."
      Set-ImageRegistry -ImageRoot $MountDir -Groups @(Get-ConfigValue $Config.install 'Registry' @())

      if ($script:VirtIORoot) {
        Add-VirtIODrivers -ImageRoot $MountDir -OsFolder (Get-VirtIOOsFolder $Detail.Version $Detail.InstallationType) -ImageLabel $Label
      }

      if ($script:Defender) { Add-DefenderUpdate -ImageRoot $MountDir -Image $Detail -ImageLabel $Label }

      Write-Host "Set-InstallImage: saving $Label."
      Dismount-Wim -Commit
      $Saved = $true
    }
    finally {
      if (-not $Saved) {
        Write-Warning "Set-InstallImage: discarding changes to $Label."
        try { Dismount-Wim } catch { Write-Warning "Set-InstallImage: discard failed: $_" }
      }
    }
  }

  $Format = "$(Get-ConfigValue $Config.install 'Format' 'wim')".ToLowerInvariant()

  if ($Format -eq 'esd') {
    # install.esd with LZMS ("recovery") compression: much smaller, much slower
    # to build. Setup uses install.esd when there is no install.wim.
    $Esd = Join-Path (Split-Path $InstallWim) 'install.esd'
    if (Test-Path $Esd) { Remove-Item $Esd -Force }
    foreach ($Image in $Images) {
      Write-Host "Set-InstallImage: exporting [$($Image.ImageIndex)] $($Image.ImageName) to install.esd (recovery compression)."
      Invoke-Dism @('/Export-Image', "/SourceImageFile:$InstallWim", "/SourceIndex:$($Image.ImageIndex)", "/DestinationImageFile:$Esd", '/Compress:recovery') | Out-Null
    }
    Remove-Item $InstallWim -Force
    return $Esd
  }

  if ($Format -ne 'wim') { throw "Set-InstallImage: install.Format must be 'wim' or 'esd', not '$Format'." }

  # Saving appends new data to the WIM and orphans the old; exporting every
  # index into a fresh WIM drops the dead weight (usually several hundred MB).
  if (Get-ConfigValue $Config.install 'ExportWim' $true) {
    $Exported = "$InstallWim.export"
    if (Test-Path $Exported) { Remove-Item $Exported -Force }
    foreach ($Image in $Images) {
      Write-Host "Set-InstallImage: exporting [$($Image.ImageIndex)] $($Image.ImageName) to a fresh WIM."
      Invoke-Dism @('/Export-Image', "/SourceImageFile:$InstallWim", "/SourceIndex:$($Image.ImageIndex)", "/DestinationImageFile:$Exported", '/Compress:max') | Out-Null
    }
    Move-Item $Exported $InstallWim -Force
  }
  $InstallWim
}

function Set-WinRE([string] $ImageRoot, [string] $ImageLabel, [version] $ImageVersion) {
  $Target = Join-Path $ImageRoot 'Windows\System32\Recovery\Winre.wim'

  if (Test-Path $Target) {
    # media built with uupdump SkipWinRE=0 already has a WinRE that matches the build
    Write-Host "Set-WinRE: $ImageLabel already has WinRE ($((Get-WindowsImage -ImagePath $Target -Index 1).Version)); keeping it."
    return
  }

  if (-not $WinREWimPath) {
    Add-BuildWarning "$($ImageLabel): image has no WinRE and no -WinREWimPath was given; recovery environment will be unavailable."
    return
  }

  $WinREVersion = [version](Get-WindowsImage -ImagePath $WinREWimPath -Index 1).Version
  if ($ImageVersion.Build -ne $WinREVersion.Build) {
    Add-BuildWarning "$($ImageLabel): injecting WinRE $WinREVersion into a $ImageVersion image - build mismatch."
  }

  Write-Host "Set-WinRE: copying $WinREWimPath into $ImageLabel."
  New-Item -ItemType Directory -Force -Path (Split-Path $Target) | Out-Null
  Copy-Item $WinREWimPath $Target -Force
}

# The virtio-win ISO has one folder per OS: <driver>\<w11|w10|2k25|2k22|2k19>\amd64
function Get-VirtIOOsFolder([version] $Version, [string] $InstallationType) {
  if ($InstallationType -like 'Server*') {
    if ($Version.Build -ge 26100) { return '2k25' }
    if ($Version.Build -ge 20348) { return '2k22' }
    return '2k19'
  }
  if ($Version.Build -ge 22000) { return 'w11' }
  'w10'
}

# Attach the virtio-win ISO (unless it already is) and remember its root
function Mount-VirtIOIso {
  $DiskImage = Get-DiskImage -ImagePath $VirtIOIsoPath
  if (-not $DiskImage.Attached) {
    $DiskImage = Mount-DiskImage -ImagePath $VirtIOIsoPath -StorageType ISO -Access ReadOnly -PassThru
    $script:VirtIOMountedHere = $true
  }
  $Volume = Get-IsoVolume $DiskImage $VirtIOIsoPath
  $script:VirtIORoot = "$($Volume.DriveLetter):\"
  Write-Host "Mount-VirtIOIso: $VirtIOIsoPath ($($Volume.FileSystemLabel)) at $($script:VirtIORoot); adding $($script:VirtIODriverList -join ', ')."
  $Volume.FileSystemLabel
}

# Add the configured virtio-win drivers for $OsFolder to a mounted image.
# A missing driver folder is a warning; a DISM failure (e.g. unsigned driver) fails the build.
function Add-VirtIODrivers([string] $ImageRoot, [string] $OsFolder, [string] $ImageLabel) {
  foreach ($Driver in $script:VirtIODriverList) {
    $Path = Join-Path $script:VirtIORoot "$Driver\$OsFolder\amd64"
    if (-not (Test-Path $Path)) {
      Add-BuildWarning "$($ImageLabel): virtio-win has no $Driver\$OsFolder\amd64; driver not added."
      continue
    }
    Write-Host "Add-VirtIODrivers: adding $Driver ($OsFolder) to $ImageLabel."
    Invoke-Dism @("/Image:$ImageRoot", '/Add-Driver', "/Driver:$Path") | Out-Null
    $script:DriversAdded.Add("$($ImageLabel): $Driver\$OsFolder")
  }
}

#region defender

# Microsoft's "Defender update for Windows operating system installation images"
# kit is defender-dism-<arch>.cab plus DefenderUpdateWinImage.ps1. The script
# mounts the WIM itself with the DISM cmdlets (in-process, see Find-Dism), but
# inside the image all it does is copy the cab's Platform and Definition
# Updates folders into ProgramData\Microsoft\Windows Defender, drop
# package-defender.xml into Windows\Temp, and enable Windows-Defender on Server.
# The same is done here to the image that is already mounted.

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

# Verify and expand the package. Returns what it contains, or $null (with a warning) if it can't be used.
function Initialize-DefenderUpdate([string] $Path) {
  $script:DefenderSummary = [ordered]@{ package = $null; platform = $null; engine = $null; signatures = $null; source = $Path; images = $script:DefenderImages }
  if (-not $Path) {
    Add-BuildWarning 'install.DefenderUpdate is on but no -DefenderPackage was given; images keep the Defender platform and definitions from the media.'
    return
  }
  try {
    $Cab = $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
      $Cab = @(Get-ChildItem -LiteralPath $Path -Filter 'defender-dism-*.cab' -File | ForEach-Object FullName) | Select-Object -First 1
      if (-not $Cab) { throw "no defender-dism-*.cab in $Path." }
    }
    if (-not (Test-Path -LiteralPath $Cab -PathType Leaf)) { throw "$Cab not found." }
    if (-not (Test-MicrosoftSignature $Cab)) { throw "$Cab is not validly signed by Microsoft." }

    $Root = Join-Path $WorkingDir 'DefenderPackage'
    if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Invoke-Native expand.exe @($Cab, '-F:*', $Root) | Out-Null

    [xml] $Xml = Get-Content -Raw -LiteralPath (Join-Path $Root 'package-defender.xml')
    $Platform = @(Get-ChildItem (Join-Path $Root 'Platform') -Directory)
    if ($Platform.Count -ne 1 -or -not (Test-Path (Join-Path $Root 'Definition Updates\Updates\mpengine.dll'))) { throw "unexpected layout in $Cab." }

    $Package = [PSCustomObject]@{
      Root       = $Root
      Arch       = "$($Xml.packageinfo.arch)"
      Package    = "$($Xml.packageinfo.versions.defender)"
      Platform   = "$($Xml.packageinfo.versions.platform)"
      Engine     = "$($Xml.packageinfo.versions.engine)"
      Signatures = "$($Xml.packageinfo.versions.signatures)"
    }
    foreach ($Name in 'package', 'platform', 'engine', 'signatures') { $script:DefenderSummary[$Name] = $Package.$Name }
    Write-Host "Initialize-DefenderUpdate: $Cab is package $($Package.Package) ($($Package.Arch)): platform $($Package.Platform), engine $($Package.Engine), security intelligence $($Package.Signatures)."
    $Package
  }
  catch {
    Add-BuildWarning "Defender update package $Path can't be used, images keep the Defender version from the media: $_"
  }
}

# highest file version among the files that exist, as a string ($null if none)
function Get-MaxFileVersion([string[]] $Paths) {
  $Versions = @(foreach ($Path in $Paths) {
      if (Test-Path -LiteralPath $Path) {
        $Info = (Get-Item -LiteralPath $Path).VersionInfo
        [version] ('{0}.{1}.{2}.{3}' -f $Info.FileMajorPart, $Info.FileMinorPart, $Info.FileBuildPart, $Info.FilePrivatePart)
      }
    })
  if ($Versions) { "$(@($Versions | Sort-Object)[-1])" }
}

# Defender versions an image will start with: the newest platform (inbox or under
# ProgramData\...\Platform), engine and security intelligence (Default = inbox, Updates = kit)
function Get-ImageDefenderVersion([string] $ImageRoot) {
  $Data = Join-Path $ImageRoot 'ProgramData\Microsoft\Windows Defender'
  $Definitions = @('Default', 'Updates' | ForEach-Object { Join-Path $Data "Definition Updates\$_" })
  [PSCustomObject]@{
    platform   = Get-MaxFileVersion (@(Join-Path $ImageRoot 'Program Files\Windows Defender\MsMpEng.exe') +
      @(Get-ChildItem (Join-Path $Data 'Platform') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'MsMpEng.exe' }))
    engine     = Get-MaxFileVersion @($Definitions | ForEach-Object { Join-Path $_ 'mpengine.dll' })
    signatures = Get-MaxFileVersion @($Definitions | ForEach-Object { Join-Path $_ 'mpavdlta.vdm' })
  }
}

# Apply the Defender package to a mounted image. Images the kit doesn't support
# are skipped with a warning; a failure while copying fails the build, so a
# half-copied platform folder is never committed.
function Add-DefenderUpdate([string] $ImageRoot, $Image, [string] $ImageLabel) {
  $Package = $script:Defender
  $Before = Get-ImageDefenderVersion $ImageRoot
  $Result = [ordered]@{ image = $ImageLabel; status = 'skipped'; before = $Before; after = $null }
  $script:DefenderImages.Add($Result)

  # the kit's own checks: matching architecture, Windows 10 1607 (with the September 2018 update) or later
  $Arch = switch ([int] $Image.Architecture) { 0 { 'x86' } 9 { 'amd64' } 12 { 'arm64' } default { "unknown ($_)" } }
  $Version = [version] $Image.Version
  $MinimumRevision = @{ 14393 = 2515; 15063 = 1356; 16299 = 699; 17134 = 320 }
  $Supported = $Version.Major -gt 10 -or ($Version.Major -eq 10 -and ($Version.Minor -gt 0 -or $Version.Build -ge 17763 -or
      ($MinimumRevision.ContainsKey($Version.Build) -and $Version.Revision -ge $MinimumRevision[$Version.Build])))
  if ($Package.Arch -notlike "$Arch*") { Add-BuildWarning "$($ImageLabel): Defender package is $($Package.Arch), image is $Arch; Defender not updated."; return }
  if (-not $Supported) { Add-BuildWarning "$($ImageLabel): Defender update kit doesn't support Windows $Version; Defender not updated."; return }

  $Wanted = [PSCustomObject]@{ platform = $Package.Platform; engine = $Package.Engine; signatures = $Package.Signatures }
  if (-not @('platform', 'engine', 'signatures' | Where-Object { -not $Before.$_ -or [version] $Before.$_ -lt [version] $Wanted.$_ })) {
    Write-Host "Add-DefenderUpdate: $ImageLabel already has Defender $($Package.Package) or newer; nothing to do."
    $Result.status = 'current'
    $Result.after = $Before
    return
  }

  # Server: Defender is an optional feature; the kit enables it if it is off
  if ($Image.InstallationType -like 'Server*') {
    $Feature = Invoke-Dism @("/Image:$ImageRoot", '/Get-FeatureInfo', '/FeatureName:Windows-Defender') -AllowFailure
    $State = @($Feature.Output | Where-Object { $_ -match '^\s*State\s*:\s*(\S+)' } | ForEach-Object { $Matches[1] })
    if ($Feature.ExitCode -ne 0 -or -not $State) { Add-BuildWarning "$($ImageLabel): no Windows-Defender feature in this image; Defender not updated."; return }
    if ($State[0] -ne 'Enabled') {
      Write-Host "Add-DefenderUpdate: enabling Windows-Defender in $ImageLabel (was $($State[0]))."
      $Enable = Invoke-Dism @("/Image:$ImageRoot", '/Enable-Feature', '/FeatureName:Windows-Defender') -AllowFailure
      if ($Enable.ExitCode -notin 0, 3010) { Add-BuildWarning "$($ImageLabel): enabling Windows-Defender failed (exit $($Enable.ExitCode)); Defender not updated."; return }
    }
  }

  Write-Host "Add-DefenderUpdate: updating Defender in $ImageLabel from platform $($Before.platform), engine $($Before.engine), security intelligence $($Before.signatures)."
  $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $Data = Join-Path $ImageRoot 'ProgramData\Microsoft\Windows Defender'
  # new files inherit Defender's ACLs from the destination folders, as with the kit's Copy-Item
  foreach ($Folder in 'Definition Updates\Updates', 'Platform') {
    Invoke-Native robocopy.exe @((Join-Path $Package.Root $Folder), (Join-Path $Data $Folder), '/E', '/R:3', '/W:5', '/NP', '/NFL', '/NDL') -SuccessExitCodes (0..7) | Out-Null
  }
  Copy-Item (Join-Path $Package.Root 'package-defender.xml') (Join-Path $ImageRoot 'Windows\Temp') -Force

  # check what landed rather than trusting the copy
  $After = Get-ImageDefenderVersion $ImageRoot
  $Result.after = $After
  foreach ($Name in 'platform', 'engine', 'signatures') {
    if (-not $After.$Name -or [version] $After.$Name -lt [version] $Wanted.$Name) {
      throw "Add-DefenderUpdate: $ImageLabel has $Name $($After.$Name) after the update, expected $($Wanted.$Name)."
    }
  }
  $Result.status = 'updated'
  Write-Host "Add-DefenderUpdate: $ImageLabel now has platform $($After.platform), engine $($After.engine), security intelligence $($After.signatures) ($([math]::Round($Stopwatch.Elapsed.TotalSeconds)) s)."
}

#endregion

# $VirtIOOsFolder: add virtio-win drivers for this OS folder (empty: none)
function Set-BootImage([string] $BootWim, $BootConfig, [string] $VirtIOOsFolder) {
  $LabConfig = Get-ConfigValue $BootConfig 'LabConfig'
  $Values = @(if ($LabConfig) { $LabConfig.PSObject.Properties | Where-Object { $_.Value } })
  if (-not $Values -and -not $VirtIOOsFolder) { Write-Host 'Set-BootImage: no LabConfig bypasses or drivers to add; leaving boot.wim alone.'; return }

  $Index = Get-SetupBootIndex $BootWim
  Write-Host "Set-BootImage: mounting boot.wim index $Index (LabConfig: $($Values.Name -join ', '); drivers: $VirtIOOsFolder)."

  # adding drivers needs a full mount; a registry edit alone doesn't
  Mount-Wim -ImageFile $BootWim -Index $Index -Optimize:(-not $VirtIOOsFolder)
  $Saved = $false
  try {
    if ($Values) {
      $Hive = Mount-OfflineHive $MountDir 'SYSTEM'
      try {
        foreach ($Value in $Values) {
          Invoke-Native reg.exe @('add', "$Hive\Setup\LabConfig", '/v', $Value.Name, '/t', 'REG_DWORD', '/d', '1', '/f') | Out-Null
        }
      }
      finally {
        Dismount-OfflineHive $Hive
      }
    }
    if ($VirtIOOsFolder) {
      Add-VirtIODrivers -ImageRoot $MountDir -OsFolder $VirtIOOsFolder -ImageLabel "boot.wim[$Index]"
    }
    Dismount-Wim -Commit
    $Saved = $true
  }
  finally {
    if (-not $Saved) {
      try { Dismount-Wim } catch { Write-Warning "Set-BootImage: discard failed: $_" }
    }
  }
}

#endregion

#region media

# Copy autounattend.xml to the media. When install.wim has several images the
# hard-coded /IMAGE/INDEX is removed so Setup asks which edition to install
# instead of silently installing index 1.
function Set-Unattend([string] $Source, [string] $MediaRoot, [int] $ImageCount) {
  $Destination = Join-Path $MediaRoot 'autounattend.xml'
  [xml] $Xml = Get-Content -Raw -Path $Source

  if ($ImageCount -gt 1) {
    $Ns = New-Object System.Xml.XmlNamespaceManager $Xml.NameTable
    $Ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    foreach ($Node in @($Xml.SelectNodes('//u:ImageInstall/u:OSImage/u:InstallFrom', $Ns))) {
      Write-Host "Set-Unattend: $ImageCount images in install.wim - removing InstallFrom so Setup prompts for the edition."
      $Node.ParentNode.RemoveChild($Node) | Out-Null
    }
  }

  $Xml.Save($Destination)
}

function Find-Oscdimg {
  $Candidates = @(
    (Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
  ) | Where-Object { $_ -and (Test-Path $_) }

  if (-not $Candidates) { throw 'Find-Oscdimg: oscdimg.exe not found. Install the Windows ADK Deployment Tools.' }
  @($Candidates)[0]
}

function New-IsoImage([string] $Source, [string] $OutputFile, [string] $Label, [bool] $NoPrompt) {
  $Oscdimg = Find-Oscdimg

  $BiosFile = Join-Path $Source 'boot\etfsboot.com'
  $EfiFile = Join-Path $Source 'efi\microsoft\boot\efisys.bin'
  if ($NoPrompt -and (Test-Path (Join-Path $Source 'efi\microsoft\boot\efisys_noprompt.bin'))) {
    $EfiFile = Join-Path $Source 'efi\microsoft\boot\efisys_noprompt.bin'
  }
  foreach ($File in $BiosFile, $EfiFile) { if (-not (Test-Path $File)) { throw "New-IsoImage: boot file missing: $File" } }

  # UDF label: letters, digits, underscore; 32 chars max
  $Label = ($Label -replace '[^A-Za-z0-9_]', '_')
  if (-not $Label) { $Label = 'WINDOWS' }
  if ($Label.Length -gt 32) { $Label = $Label.Substring(0, 32) }

  if (Test-Path $OutputFile) { Remove-Item $OutputFile -Force }

  # Build the argument string by hand: -bootdata needs embedded quotes, which
  # Windows PowerShell mangles when passing an array to a native command.
  # Every path is quoted, so spaces work without relying on 8.3 short names.
  $Arguments = "-m -o -h -u2 -udfver102 -l$Label " +
    "-bootdata:2#p0,e,b`"$BiosFile`"#pEF,e,b`"$EfiFile`" " +
    "`"$Source`" `"$OutputFile`""

  Write-Host "New-IsoImage: oscdimg.exe $Arguments"

  $StdOut = Join-Path $WorkingDir 'oscdimg.out.log'
  $StdErr = Join-Path $WorkingDir 'oscdimg.err.log'
  $Process = Start-Process -FilePath $Oscdimg -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr

  # oscdimg reports progress on stderr; keep only the last lines
  Get-Content $StdOut, $StdErr -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '% complete' } | Select-Object -Last 15 | Write-Host

  if ($Process.ExitCode -ne 0) { throw "New-IsoImage: oscdimg.exe failed with exit code $($Process.ExitCode)." }
  if (-not (Test-Path $OutputFile)) { throw "New-IsoImage: oscdimg.exe reported success but $OutputFile does not exist." }
}

# Mount the finished ISO and check it has the expected images. Returns the image list.
function Test-IsoImage([string] $Path, [int] $ExpectedImageCount) {
  $DiskImage = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly -PassThru
  try {
    $Volume = Get-IsoVolume $DiskImage $Path

    $Root = "$($Volume.DriveLetter):\"
    foreach ($Required in 'sources\boot.wim', 'autounattend.xml', 'bootmgr', 'efi\boot\bootx64.efi') {
      if (-not (Test-Path (Join-Path $Root $Required))) { throw "Test-IsoImage: $Required missing from output ISO." }
    }

    # exactly one of install.wim / install.esd
    $Install = @('sources\install.wim', 'sources\install.esd' | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ })
    if ($Install.Count -ne 1) { throw "Test-IsoImage: expected one of install.wim or install.esd in output ISO, found $($Install.Count)." }

    $Images = @(Get-WindowsImage -ImagePath $Install[0] | ForEach-Object {
        $Detail = Get-WindowsImage -ImagePath $Install[0] -Index $_.ImageIndex
        [PSCustomObject]@{ Index = $Detail.ImageIndex; Name = $Detail.ImageName; Version = $Detail.Version; Size = $Detail.ImageSize }
      })

    if ($Images.Count -ne $ExpectedImageCount) {
      throw "Test-IsoImage: expected $ExpectedImageCount image(s) in output $(Split-Path -Leaf $Install[0]), found $($Images.Count)."
    }
    $Images
  }
  finally {
    Dismount-DiskImage -ImagePath $Path | Out-Null
  }
}

#endregion

$ExitCode = 1
$script:Dism = Find-Dism
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$IsoName = [System.IO.Path]::GetFileNameWithoutExtension($IsoPath)
Start-Transcript -Path (Join-Path $LogDir "Customize-$($IsoName -replace '[^\w.-]', '')-$(Get-Date -Format yyyyMMdd-HHmmss).log") | Out-Null

try {
  $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $GitVersion = try { git -c safe.directory='*' -C $PSScriptRoot rev-parse --short HEAD 2>$null } catch { 'unknown' }
  Write-Host "Customize-Iso: version $GitVersion, started $(Get-Date -Format o)."
  Write-Host "Customize-Iso: input $IsoPath, output $OutPath, working directory $WorkingDir."

  $IsoPath = (Resolve-Path $IsoPath).Path
  $Config = Get-Content -Raw $ConfigFile | ConvertFrom-Json
  if (-not (Test-Path $Autounattend)) { throw "Autounattend file not found: $Autounattend" }
  if ($WinREWimPath -and -not (Test-Path $WinREWimPath)) { throw "WinRE file not found: $WinREWimPath" }
  if ($VirtIOIsoPath -and -not (Test-Path $VirtIOIsoPath)) { throw "virtio-win ISO not found: $VirtIOIsoPath" }

  # DISM logs and scratch space live with the build, not on C:
  New-Item -ItemType Directory -Force -Path $WorkingDir, $MountDir, $DismScratch | Out-Null
  Write-Host "Customize-Iso: using $($script:Dism) ($((Get-Item $script:Dism).VersionInfo.ProductVersion))."

  # recover from a previous run that died part way through
  Clear-StaleMounts
  foreach ($Path in $ScratchPath, $StagingIso) {
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force }
  }

  # rough space check: media copy + mounted image + export + output ISO
  $IsoSize = (Get-Item $IsoPath).Length
  $Free = (Get-Volume -DriveLetter ((Resolve-Path $WorkingDir).Path[0])).SizeRemaining
  $Needed = ($IsoSize * 3) + 20GB
  if ($Free -lt $Needed) {
    throw "Not enough free space for $WorkingDir`: $([math]::Round($Free / 1GB)) GB free, about $([math]::Round($Needed / 1GB)) GB needed."
  }

  Write-Host 'Customize-Iso: copying ISO contents.'
  $VolumeLabel = Copy-IsoContents -Path $IsoPath -Destination $ScratchPath

  $InstallWim = Join-Path $ScratchPath 'sources\install.wim'
  $InstallEsd = Join-Path $ScratchPath 'sources\install.esd'
  $BootWim = Join-Path $ScratchPath 'sources\boot.wim'

  if (-not (Test-Path $InstallWim) -and (Test-Path $InstallEsd)) {
    Write-Host 'Customize-Iso: converting install.esd to install.wim so it can be serviced.'
    foreach ($Image in @(Get-WindowsImage -ImagePath $InstallEsd)) {
      Invoke-Dism @('/Export-Image', "/SourceImageFile:$InstallEsd", "/SourceIndex:$($Image.ImageIndex)", "/DestinationImageFile:$InstallWim", '/Compress:max') | Out-Null
    }
    Remove-Item $InstallEsd -Force
  }
  foreach ($Wim in $InstallWim, $BootWim) { if (-not (Test-Path $Wim)) { throw "Missing $Wim in $IsoPath." } }

  $ImageCount = @(Get-WindowsImage -ImagePath $InstallWim).Count

  # boot.wim gets the drivers for the OS on this media (from the first image)
  $VirtIOLabel = $null
  $BootVirtIOFolder = $null
  if ($VirtIOIsoPath) {
    $VirtIOLabel = Mount-VirtIOIso
    $First = Get-WindowsImage -ImagePath $InstallWim -Index 1
    $BootVirtIOFolder = Get-VirtIOOsFolder $First.Version $First.InstallationType
  }

  Write-Host 'Customize-Iso: adding autounattend.xml and post-install stubs.'
  Set-Unattend -Source $Autounattend -MediaRoot $ScratchPath -ImageCount $ImageCount
  $OemPath = Join-Path $ScratchPath 'sources\$OEM$\$1'
  New-Item -ItemType Directory -Force -Path $OemPath | Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'stub-scripts\*') $OemPath -Recurse -Force

  # Defender update for every image: best effort, so a missing or bad package is a warning
  if (Get-ConfigValue $Config.install 'DefenderUpdate' $true) { $script:Defender = Initialize-DefenderUpdate $DefenderPackage }

  Write-Host 'Customize-Iso: customizing install.wim.'
  # returns the final install image path (install.wim or install.esd)
  $InstallImage = @(Set-InstallImage -InstallWim $InstallWim -Config $Config)[-1]
  if ($script:Defender) { Remove-Item $script:Defender.Root -Recurse -Force }

  Write-Host 'Customize-Iso: customizing boot.wim.'
  Set-BootImage -BootWim $BootWim -BootConfig (Get-ConfigValue $Config 'boot') -VirtIOOsFolder $BootVirtIOFolder

  Write-Host 'Customize-Iso: building ISO.'
  New-IsoImage -Source $ScratchPath -OutputFile $StagingIso -Label $VolumeLabel `
    -NoPrompt ([bool](Get-ConfigValue (Get-ConfigValue $Config 'iso') 'NoPrompt' $true))

  Write-Host 'Customize-Iso: verifying ISO.'
  $Images = @(Test-IsoImage -Path $StagingIso -ExpectedImageCount $ImageCount)

  # publish: drop the old manifest first so a manifest only ever describes a complete ISO
  $ManifestPath = "$OutPath.json"
  $ChecksumPath = "$OutPath.sha256.txt"
  New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
  foreach ($Path in $ManifestPath, $ChecksumPath) { if (Test-Path $Path) { Remove-Item $Path -Force } }

  $Checksum = (Get-FileHash -Algorithm SHA256 $StagingIso).Hash.ToLowerInvariant()

  # move beside the destination, then rename over it, so the published ISO is never half-written
  $Temporary = "$OutPath.partial"
  Move-Item $StagingIso $Temporary -Force
  Move-Item $Temporary $OutPath -Force

  Set-Content -Encoding ascii -NoNewline -Path $ChecksumPath -Value $Checksum
  [PSCustomObject]@{
    source      = $IsoPath
    built       = (Get-Date -Format o)
    version     = $GitVersion
    fingerprint = $Fingerprint
    checksum    = $Checksum
    format      = [System.IO.Path]::GetExtension($InstallImage).TrimStart('.')
    images      = @($Images)
    removed     = @($script:Removed)
    virtio      = $VirtIOLabel
    drivers     = @($script:DriversAdded)
    defender    = $script:DefenderSummary
    warnings    = @($script:Warnings)
    elapsed     = [math]::Round($Stopwatch.Elapsed.TotalMinutes, 1)
  } | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -Path $ManifestPath

  Write-Host "Customize-Iso: wrote $OutPath ($([math]::Round((Get-Item $OutPath).Length / 1GB, 2)) GB, $($Images.Count) image(s), $($script:Warnings.Count) warning(s))."

  # the build succeeded - reclaim the space
  Remove-Item $ScratchPath -Recurse -Force

  Write-Host "Customize-Iso: completed in $([math]::Round($Stopwatch.Elapsed.TotalMinutes, 1)) minutes."
  $ExitCode = 0
}
catch {
  Write-Host "Customize-Iso: FAILED: $_"
  @(($_.ScriptStackTrace -split '\r?\n') -replace '^', '  at: ') | Write-Host
}
finally {
  # leave nothing mounted or loaded, whatever happened
  foreach ($Key in @($script:LoadedHives)) {
    try { Dismount-OfflineHive $Key } catch { Write-Warning "cleanup: $_" }
  }
  try { Clear-StaleMounts } catch { Write-Warning "cleanup: $_" }
  foreach ($Path in $IsoPath, $StagingIso) {
    try {
      if ((Test-Path $Path) -and (Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue).Attached) {
        Dismount-DiskImage -ImagePath $Path | Out-Null
      }
    }
    catch { Write-Warning "cleanup: $_" }
  }
  if ($script:VirtIOMountedHere) {
    try { Dismount-DiskImage -ImagePath $VirtIOIsoPath | Out-Null } catch { Write-Warning "cleanup: $_" }
  }
  Stop-Transcript | Out-Null
}

exit $ExitCode
