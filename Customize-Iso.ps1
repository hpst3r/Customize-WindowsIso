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
  # move the ISO being replaced (and its sidecars) to <name>.previous.iso instead of deleting it
  [switch] $KeepPrevious,
  # optional: a JSON file with "DriverSets": [ ... ] (see DriverSets.ps1), e.g.
  # runner-config.json. Each set's drivers go into boot.wim, install.wim and/or WinRE.
  [string] $DriverSetsFile,
  # optional shorthand for one virtio-iso driver set added to boot, install and winre
  [string] $VirtIOIsoPath,
  # comma-separated driver folders from the virtio-win ISO
  [string] $VirtIODrivers = 'vioscsi,viostor,NetKVM'
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
# Winre.wim is mounted from inside the mounted install image
$MountREDir = Join-Path $WorkingDir 'MountRE'
$DismScratch = Join-Path $WorkingDir 'DismScratch'
$StagingIso = Join-Path $WorkingDir 'staging.iso'

# state tracked so the finally block can clean up whatever is still open
$script:LoadedHives = [System.Collections.Generic.List[string]]::new()
$script:Warnings = [System.Collections.Generic.List[string]]::new()
$script:Removed = [System.Collections.Generic.List[string]]::new()
$script:DriversAdded = [System.Collections.Generic.List[string]]::new()
# enabled driver sets, each with Root/Label/MountedHere once opened (Open-DriverSets)
$script:DriverSets = @()

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
function Mount-Wim([string] $ImageFile, [int] $Index, [switch] $Optimize, [string] $Path = $MountDir) {
  $Arguments = @('/Mount-Image', "/ImageFile:$ImageFile", "/Index:$Index", "/MountDir:$Path")
  if ($Optimize) { $Arguments += '/Optimize' }
  Invoke-Dism $Arguments | Out-Null
}

function Dismount-Wim([switch] $Commit, [string] $Path = $MountDir) {
  $Mode = if ($Commit) { '/Commit' } else { '/Discard' }
  Invoke-Dism @('/Unmount-Image', "/MountDir:$Path", $Mode) | Out-Null
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
# changes, and drop stale mount points. Safe to call at any time, including
# while other DISM work (another build, uupdump's converter) runs on this machine.
function Clear-StaleMounts {
  $AllMounted = @(Get-WindowsImage -Mounted)
  $Mounted = @($AllMounted | Where-Object { $_.Path -like "$($WorkingDir)*" })
  # nested mounts first: Winre.wim in MountRE lives inside the image mounted at Mount
  $Mounted = @($Mounted | Sort-Object { $Image = $_; -not @($Mounted | Where-Object { $Image.ImagePath -like "$($_.Path)\*" }) })
  foreach ($Image in $Mounted) {
    Write-Host "Clear-StaleMounts: discarding mounted image at $($Image.Path) (status $($Image.MountStatus))."
    $Result = Invoke-Dism @('/Unmount-Image', "/MountDir:$($Image.Path)", '/Discard') -AllowFailure
    if ($Result.ExitCode -ne 0) { Write-Warning "Clear-StaleMounts: dismount failed for $($Image.Path): $($Result.Output -join ' | ')" }
  }

  # /Cleanup-Mountpoints is machine-wide: run mid-commit by another process, it removed
  # that build's mount record and its save failed (0x80070057). Only run it when
  # nothing outside this working directory is mounted.
  $Foreign = @($AllMounted | Where-Object { $_.Path -notlike "$($WorkingDir)*" })
  if ($Foreign) {
    Write-Host "Clear-StaleMounts: $($Foreign.Count) other image(s) mounted on this machine; skipping /Cleanup-Mountpoints."
  }
  else {
    Invoke-Dism @('/Cleanup-Mountpoints') -AllowFailure | Out-Null
  }
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

      $OsFolder = Get-DriverOsFolder $Detail.Version $Detail.InstallationType
      Add-DriverSets -ImageRoot $MountDir -Target 'install' -OsFolder $OsFolder -ImageLabel $Label
      # before the install image is saved: Winre.wim is a file inside it
      Set-WinREDrivers -ImageRoot $MountDir -OsFolder $OsFolder -ImageLabel $Label

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

#region drivers

# OS folder for driver sets, as on the virtio-win ISO: <driver>\<w11|w10|2k25|2k22|2k19>\amd64
function Get-DriverOsFolder([version] $Version, [string] $InstallationType) {
  if ($InstallationType -like 'Server*') {
    if ($Version.Build -ge 26100) { return '2k25' }
    if ($Version.Build -ge 20348) { return '2k22' }
    return '2k19'
  }
  if ($Version.Build -ge 22000) { return 'w11' }
  'w10'
}

# enabled driver sets that add drivers to $Target (boot, install, winre)
function Get-TargetDriverSets([string] $Target) {
  @($script:DriverSets | Where-Object { $_.Targets -contains $Target })
}

# Attach virtio-win ISOs (unless they already are) and note each set's root
function Open-DriverSets {
  foreach ($Set in $script:DriverSets) {
    $Set | Add-Member -NotePropertyMembers @{ Root = $null; Label = $Set.Name; MountedHere = $false; PerOs = $false }
    if ($Set.Type -eq 'virtio-iso') {
      $DiskImage = Get-DiskImage -ImagePath $Set.Path
      if (-not $DiskImage.Attached) {
        $DiskImage = Mount-DiskImage -ImagePath $Set.Path -StorageType ISO -Access ReadOnly -PassThru
        $Set.MountedHere = $true
      }
      $Volume = Get-IsoVolume $DiskImage $Set.Path
      $Set.Root = "$($Volume.DriveLetter):\"
      $Set.Label = $Volume.FileSystemLabel
      $Detail = "$($Set.Label) at $($Set.Root), drivers $($Set.Drivers -join ', ')"
    }
    else {
      $Set.Root = $Set.Path
      # per-OS layout: <Path>\<w11|2k22|...>, used instead of the whole folder
      $Set.PerOs = [bool](@(Get-ChildItem -LiteralPath $Set.Path -Directory | Where-Object { $DriverOsFolders -contains $_.Name }).Count)
      $Detail = if ($Set.PerOs) { 'per-OS subfolders' } else { 'whole folder' }
    }
    Write-Host "Open-DriverSets: '$($Set.Name)' ($($Set.Type)) from $($Set.Path): $Detail; targets $($Set.Targets -join ', ')."
  }
}

function Close-DriverSets {
  foreach ($Set in @($script:DriverSets | Where-Object { $_.PSObject.Properties['MountedHere'] -and $_.MountedHere })) {
    try { Dismount-DiskImage -ImagePath $Set.Path | Out-Null; $Set.MountedHere = $false } catch { Write-Warning "cleanup: $_" }
  }
}

# Add the drivers of every set targeting $Target to a mounted image.
# A missing driver folder is a warning; a DISM failure (e.g. unsigned driver) fails the build.
function Add-DriverSets([string] $ImageRoot, [string] $Target, [string] $OsFolder, [string] $ImageLabel) {
  foreach ($Set in (Get-TargetDriverSets $Target)) {
    if ($Set.Type -eq 'virtio-iso') {
      foreach ($Driver in $Set.Drivers) {
        $Path = Join-Path $Set.Root "$Driver\$OsFolder\amd64"
        if (-not (Test-Path $Path)) {
          Add-BuildWarning "$($ImageLabel): $($Set.Name) ($($Set.Label)) has no $Driver\$OsFolder\amd64; driver not added."
          continue
        }
        Write-Host "Add-DriverSets: adding $($Set.Name) $Driver ($OsFolder) to $ImageLabel."
        Invoke-Dism @("/Image:$ImageRoot", '/Add-Driver', "/Driver:$Path") | Out-Null
        $script:DriversAdded.Add("$($ImageLabel): $($Set.Name) $Driver\$OsFolder")
      }
      continue
    }

    $Path = $Set.Root
    if ($Set.PerOs) {
      $Path = Join-Path $Set.Root $OsFolder
      if (-not (Test-Path -LiteralPath $Path)) {
        Add-BuildWarning "$($ImageLabel): driver set $($Set.Name) has no $OsFolder subfolder; drivers not added."
        continue
      }
    }
    Write-Host "Add-DriverSets: adding $($Set.Name) ($Path, recursive) to $ImageLabel."
    $Result = Invoke-Dism @("/Image:$ImageRoot", '/Add-Driver', "/Driver:$Path", '/Recurse')
    # "Installing 1 of 3 - <path>\x.inf: The driver package was successfully installed."
    $Infs = @($Result.Output | ForEach-Object { if ($_ -match '^Installing \d+ of \d+ - (.+?\.inf): ') { $Matches[1] } })
    foreach ($Inf in $Infs) {
      $Relative = if ($Inf.StartsWith($Set.Root, [System.StringComparison]::OrdinalIgnoreCase)) { $Inf.Substring($Set.Root.Length).TrimStart('\') } else { $Inf }
      $script:DriversAdded.Add("$($ImageLabel): $($Set.Name) $Relative")
    }
    if (-not $Infs) { $script:DriversAdded.Add("$($ImageLabel): $($Set.Name) $Path") }
  }
}

# Add the driver sets targeting winre to the Winre.wim inside a mounted install
# image. Runs before the install image is saved; Winre.wim is mounted to a second
# mount directory and must be dismounted before the install image is.
function Set-WinREDrivers([string] $ImageRoot, [string] $OsFolder, [string] $ImageLabel) {
  if (-not (Get-TargetDriverSets 'winre')) { return }

  $Winre = Join-Path $ImageRoot 'Windows\System32\Recovery\Winre.wim'
  if (-not (Test-Path -LiteralPath $Winre)) {
    Add-BuildWarning "$($ImageLabel): no Windows\System32\Recovery\Winre.wim; drivers not added to WinRE."
    return
  }
  $Label = "$ImageLabel WinRE"

  # Winre.wim is hidden+system; make sure it is writable and put the attributes back after
  $Item = Get-Item -LiteralPath $Winre -Force
  $Attributes = $Item.Attributes
  $SizeBefore = $Item.Length
  $Item.Attributes = 'Normal'
  try {
    New-Item -ItemType Directory -Force -Path $MountREDir | Out-Null
    Write-Host "Set-WinREDrivers: mounting $Label."
    Mount-Wim -ImageFile $Winre -Index 1 -Path $MountREDir
    $Saved = $false
    try {
      Add-DriverSets -ImageRoot $MountREDir -Target 'winre' -OsFolder $OsFolder -ImageLabel $Label
      Dismount-Wim -Commit -Path $MountREDir
      $Saved = $true
    }
    finally {
      if (-not $Saved) {
        Write-Warning "Set-WinREDrivers: discarding changes to $Label."
        try { Dismount-Wim -Path $MountREDir } catch { Write-Warning "Set-WinREDrivers: discard failed: $_" }
      }
    }

    # saving appends to the WIM; a fresh export drops the orphaned data
    $SizeSaved = (Get-Item -LiteralPath $Winre -Force).Length
    $Exported = Join-Path $WorkingDir 'winre.export.wim'
    if (Test-Path $Exported) { Remove-Item $Exported -Force }
    Invoke-Dism @('/Export-Image', "/SourceImageFile:$Winre", '/SourceIndex:1', "/DestinationImageFile:$Exported", '/Compress:max') | Out-Null
    Copy-Item $Exported $Winre -Force
    Remove-Item $Exported -Force
    Write-Host "Set-WinREDrivers: $Label is $([math]::Round((Get-Item -LiteralPath $Winre -Force).Length / 1MB)) MB (was $([math]::Round($SizeBefore / 1MB)) MB; $([math]::Round($SizeSaved / 1MB)) MB before export)."
  }
  finally {
    (Get-Item -LiteralPath $Winre -Force).Attributes = $Attributes
  }
}

#endregion

# $DriverOsFolder: add the driver sets targeting boot, for this OS folder (empty: none)
function Set-BootImage([string] $BootWim, $BootConfig, [string] $DriverOsFolder) {
  $LabConfig = Get-ConfigValue $BootConfig 'LabConfig'
  $Values = @(if ($LabConfig) { $LabConfig.PSObject.Properties | Where-Object { $_.Value } })
  if (-not $Values -and -not $DriverOsFolder) { Write-Host 'Set-BootImage: no LabConfig bypasses or drivers to add; leaving boot.wim alone.'; return }

  $Index = Get-SetupBootIndex $BootWim
  Write-Host "Set-BootImage: mounting boot.wim index $Index (LabConfig: $($Values.Name -join ', '); drivers: $DriverOsFolder)."

  # adding drivers needs a full mount; a registry edit alone doesn't
  Mount-Wim -ImageFile $BootWim -Index $Index -Optimize:(-not $DriverOsFolder)
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
    if ($DriverOsFolder) {
      Add-DriverSets -ImageRoot $MountDir -Target 'boot' -OsFolder $DriverOsFolder -ImageLabel "boot.wim[$Index]"
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
# With $DiskPickerDir (iso.DiskPicker), the media copy loses its disk settings, so
# Setup asks for a disk if it is ever started without the picker, and the answer
# file the picker hands to Setup is written to $DiskPickerDir in two halves split
# where <InstallTo> goes (see winpe\diskpicker.cmd).
function Set-Unattend([string] $Source, [string] $MediaRoot, [int] $ImageCount, [string] $DiskPickerDir) {
  $Destination = Join-Path $MediaRoot 'autounattend.xml'
  [xml] $Xml = Get-Content -Raw -Path $Source
  $Ns = New-Object System.Xml.XmlNamespaceManager $Xml.NameTable
  $Ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

  if ($ImageCount -gt 1) {
    foreach ($Node in @($Xml.SelectNodes('//u:ImageInstall/u:OSImage/u:InstallFrom', $Ns))) {
      Write-Host "Set-Unattend: $ImageCount images in install.wim - removing InstallFrom so Setup prompts for the edition."
      $Node.ParentNode.RemoveChild($Node) | Out-Null
    }
  }

  if ($DiskPickerDir) {
    $SetupPath = "//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']"
    $OSImage = @($Xml.SelectNodes("$SetupPath/u:ImageInstall/u:OSImage", $Ns))
    if ($OSImage.Count -ne 1) { throw "Set-Unattend: the disk picker needs one windowsPE Microsoft-Windows-Setup ImageInstall/OSImage in $Source, found $($OSImage.Count)." }
    # the picker partitions the disk itself
    Write-Host 'Set-Unattend: disk picker - removing DiskConfiguration and InstallTo; the picker sets the target disk at install time.'
    foreach ($Node in @($Xml.SelectNodes("$SetupPath/u:DiskConfiguration", $Ns)) + @($OSImage[0].SelectNodes('u:InstallTo | u:InstallToAvailablePartition', $Ns))) {
      $Node.ParentNode.RemoveChild($Node) | Out-Null
    }
  }

  $Xml.Save($Destination)

  if ($DiskPickerDir) {
    $Marker = '@@DISKPICKER_INSTALLTO@@'
    $InstallTo = $Xml.CreateElement('InstallTo', 'urn:schemas-microsoft-com:unattend')
    $InstallTo.InnerText = $Marker
    $OSImage[0].AppendChild($InstallTo) | Out-Null
    $Template = Join-Path $DiskPickerDir 'unattend-template.xml'
    $Xml.Save($Template)
    $Parts = @([IO.File]::ReadAllText($Template) -split [regex]::Escape($Marker))
    if ($Parts.Count -ne 2) { throw "Set-Unattend: could not split the disk picker answer file at its InstallTo." }
    # the halves are joined with cmd's copy /b, so no BOM in the second half
    $Utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $DiskPickerDir 'unattend-head.xml'), $Parts[0], $Utf8)
    [IO.File]::WriteAllText((Join-Path $DiskPickerDir 'unattend-tail.xml'), $Parts[1], $Utf8)
    Remove-Item $Template
  }
}

# The disk picker (iso.DiskPicker): put winpe\diskpicker.cmd and the answer file
# halves from Set-Unattend into the Setup image of boot.wim, and start it from
# winpeshl.ini. The Setup image's shell is winpeshl.exe, which runs winpeshl.ini
# when there is one and X:\setup.exe otherwise; the picker runs Setup itself.
# Separate from Set-BootImage at the cost of a second mount, so that neither
# needs to know about the other.
function Add-DiskPicker([string] $BootWim, [string] $StagingDir, [int] $MinSizeGB) {
  $Source = Join-Path $PSScriptRoot 'winpe'
  # cmd.exe needs CRLF line endings and no BOM, whatever git did to the checkout
  foreach ($Name in 'diskpicker.cmd', 'winpeshl.ini') {
    $Text = [IO.File]::ReadAllText((Join-Path $Source $Name)) -replace "`r?`n", "`r`n"
    if ($Text -match '[^\x00-\x7F]') { throw "Add-DiskPicker: winpe\$Name must be plain ASCII." }
    [IO.File]::WriteAllText((Join-Path $StagingDir $Name), $Text, [System.Text.Encoding]::ASCII)
  }
  [IO.File]::WriteAllText((Join-Path $StagingDir 'settings.cmd'), "set `"DP_MIN_GB=$MinSizeGB`"`r`n", [System.Text.Encoding]::ASCII)

  $Index = Get-SetupBootIndex $BootWim
  Write-Host "Add-DiskPicker: adding the disk picker to boot.wim index $Index (automatic install when exactly one disk has $MinSizeGB GB or more)."
  Mount-Wim -ImageFile $BootWim -Index $Index -Optimize
  $Saved = $false
  try {
    $System32 = Join-Path $MountDir 'Windows\System32'
    foreach ($Required in 'winpeshl.exe', 'diskpart.exe', 'wpeutil.exe', 'reg.exe') {
      if (-not (Test-Path (Join-Path $System32 $Required))) { throw "Add-DiskPicker: boot.wim[$Index] has no $Required." }
    }
    if (-not (Test-Path (Join-Path $MountDir 'setup.exe')) -and -not (Test-Path (Join-Path $MountDir 'sources\setup.exe'))) {
      throw "Add-DiskPicker: boot.wim[$Index] has no setup.exe."
    }
    if (Test-Path (Join-Path $System32 'winpeshl.ini')) { throw "Add-DiskPicker: boot.wim[$Index] already has a winpeshl.ini." }

    # without winpeshl.exe as the shell, winpeshl.ini is never read and Setup starts
    # as usual - showing its disk page, since the media answer file has no disk
    $Hive = Mount-OfflineHive $MountDir 'SYSTEM'
    try { $Shell = "$((Invoke-Native reg.exe @('query', "$Hive\Setup", '/v', 'CmdLine') -AllowFailure).Output)" }
    finally { Dismount-OfflineHive $Hive }
    if ($Shell -notmatch 'winpeshl\.exe') {
      Add-BuildWarning "boot.wim[$Index]: the shell is not winpeshl.exe ($Shell), so the disk picker won't run; Setup will ask for the disk."
    }

    $Target = Join-Path $MountDir 'DiskPicker'
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    foreach ($Name in 'diskpicker.cmd', 'settings.cmd', 'unattend-head.xml', 'unattend-tail.xml') {
      Copy-Item (Join-Path $StagingDir $Name) $Target
    }
    Copy-Item (Join-Path $StagingDir 'winpeshl.ini') $System32
    Dismount-Wim -Commit
    $Saved = $true
  }
  finally {
    if (-not $Saved) {
      try { Dismount-Wim } catch { Write-Warning "Add-DiskPicker: discard failed: $_" }
    }
  }
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

# Keep the ISO being replaced as <name>.previous.iso, with $Path's .json/.sha256.txt as
# <name>.previous.iso.json/.sha256.txt, replacing any older previous copy. $Iso is the old
# ISO, already renamed out of the way. A client on the share may have the old previous
# copy open, which blocks deleting it; that only costs keeping this one, so it is a warning.
function Save-PreviousOutput([string] $Path, [string] $Iso) {
  $Previous = Join-Path (Split-Path $Path) ([System.IO.Path]::GetFileNameWithoutExtension($Path) + '.previous' + [System.IO.Path]::GetExtension($Path))

  try {
    if (Test-Path $Previous) { Remove-Item $Previous -Force }
    Move-Item $Iso $Previous
  }
  catch {
    Add-BuildWarning "could not replace $Previous (open on the share?), so the ISO being replaced was not kept: $_"
    return
  }
  foreach ($Suffix in '.json', '.sha256.txt') {
    try {
      if (Test-Path "$Previous$Suffix") { Remove-Item "$Previous$Suffix" -Force }
      if (Test-Path "$Path$Suffix") { Move-Item "$Path$Suffix" "$Previous$Suffix" }
    }
    catch { Add-BuildWarning "could not keep $Path$Suffix as $Previous$($Suffix): $_" }
  }
  Write-Host "Save-PreviousOutput: kept the ISO being replaced as $Previous."
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

  # driver sets: from -DriverSetsFile (runner-config.json style, or a bare array) and/or -VirtIOIsoPath.
  # Get-DriverSets fails on a configured set whose path is missing.
  . (Join-Path $PSScriptRoot 'DriverSets.ps1')
  $script:DriverSets = @()
  if ($DriverSetsFile) {
    $SetsConfig = Get-Content -Raw $DriverSetsFile | ConvertFrom-Json
    if ($SetsConfig -is [array]) { $SetsConfig = [PSCustomObject]@{ DriverSets = $SetsConfig } }
    $script:DriverSets += @(Get-DriverSets $SetsConfig)
  }
  if ($VirtIOIsoPath) {
    $script:DriverSets += @(Get-DriverSets ([PSCustomObject]@{ VirtIO = [PSCustomObject]@{ IsoPath = $VirtIOIsoPath; Drivers = @($VirtIODrivers -split ',') } }))
  }

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
  Open-DriverSets
  $BootDriverFolder = $null
  if (Get-TargetDriverSets 'boot') {
    $First = Get-WindowsImage -ImagePath $InstallWim -Index 1
    $BootDriverFolder = Get-DriverOsFolder $First.Version $First.InstallationType
  }

  # iso.DiskPicker: pick the target disk in WinPE instead of wiping disk 0
  $IsoConfig = Get-ConfigValue $Config 'iso'
  $DiskPicker = [bool](Get-ConfigValue $IsoConfig 'DiskPicker' $false)
  $DiskPickerDir = $null
  if ($DiskPicker) {
    $DiskPickerDir = Join-Path $WorkingDir 'DiskPicker'
    if (Test-Path $DiskPickerDir) { Remove-Item $DiskPickerDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $DiskPickerDir | Out-Null
  }

  Write-Host 'Customize-Iso: adding autounattend.xml and post-install stubs.'
  Set-Unattend -Source $Autounattend -MediaRoot $ScratchPath -ImageCount $ImageCount -DiskPickerDir $DiskPickerDir
  $OemPath = Join-Path $ScratchPath 'sources\$OEM$\$1'
  New-Item -ItemType Directory -Force -Path $OemPath | Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'stub-scripts\*') $OemPath -Recurse -Force

  Write-Host 'Customize-Iso: customizing install.wim.'
  # returns the final install image path (install.wim or install.esd)
  $InstallImage = @(Set-InstallImage -InstallWim $InstallWim -Config $Config)[-1]

  Write-Host 'Customize-Iso: customizing boot.wim.'
  Set-BootImage -BootWim $BootWim -BootConfig (Get-ConfigValue $Config 'boot') -DriverOsFolder $BootDriverFolder
  if ($DiskPicker) {
    Add-DiskPicker -BootWim $BootWim -StagingDir $DiskPickerDir -MinSizeGB ([int](Get-ConfigValue $IsoConfig 'DiskPickerMinSizeGB' 50))
  }

  Write-Host 'Customize-Iso: building ISO.'
  New-IsoImage -Source $ScratchPath -OutputFile $StagingIso -Label $VolumeLabel `
    -NoPrompt ([bool](Get-ConfigValue (Get-ConfigValue $Config 'iso') 'NoPrompt' $true))

  Write-Host 'Customize-Iso: verifying ISO.'
  $Images = @(Test-IsoImage -Path $StagingIso -ExpectedImageCount $ImageCount)

  # publish
  $ManifestPath = "$OutPath.json"
  $ChecksumPath = "$OutPath.sha256.txt"
  New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null

  $Checksum = (Get-FileHash -Algorithm SHA256 $StagingIso).Hash.ToLowerInvariant()

  # move beside the destination, then rename into place, so the published ISO is never half-written
  $Temporary = "$OutPath.partial"
  Move-Item $StagingIso $Temporary -Force

  # Rename the old ISO out of the way first. A client on the share that has it open
  # blocks this, and then the build fails with the old ISO and its sidecars untouched.
  $Replaced = "$OutPath.replaced"
  if (Test-Path $Replaced) { Remove-Item $Replaced -Force }
  if (Test-Path $OutPath) {
    try { Move-Item $OutPath $Replaced }
    catch {
      Remove-Item $Temporary -Force -ErrorAction SilentlyContinue
      throw "could not replace $OutPath (open by a client on the share?): $_"
    }
    if ($KeepPrevious) { Save-PreviousOutput -Path $OutPath -Iso $Replaced }
  }

  # drop the old manifest first so a manifest only ever describes a complete ISO
  foreach ($Path in $ManifestPath, $ChecksumPath) { if (Test-Path $Path) { Remove-Item $Path -Force } }
  Move-Item $Temporary $OutPath
  try { if (Test-Path $Replaced) { Remove-Item $Replaced -Force } } catch { Add-BuildWarning "could not delete $($Replaced): $_" }

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
    virtio      = @($script:DriverSets | Where-Object Type -eq 'virtio-iso' | ForEach-Object Label) | Select-Object -First 1
    driverSets  = @($script:DriverSets | ForEach-Object { [PSCustomObject]@{ name = $_.Name; type = $_.Type; path = $_.Path; label = $_.Label; targets = @($_.Targets) } })
    drivers     = @($script:DriversAdded)
    diskpicker  = $DiskPicker
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
  Close-DriverSets
  Stop-Transcript | Out-Null
}

exit $ExitCode
