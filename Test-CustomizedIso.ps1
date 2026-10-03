#Requires -Version 5.1 -RunAsAdministrator

<#
.SYNOPSIS
Checks that a customized ISO actually contains what config.json asks for.

.DESCRIPTION
Mounts the ISO read-only and checks:

- the media: boot files, autounattend.xml, one install.wim/esd
- autounattend.xml: no /IMAGE/INDEX (InstallFrom) when there are several editions,
  otherwise the same InstallFrom as the autounattend.xml template
- the $OEM$ post-install stubs, compared with stub-scripts\
- for every image in install.wim/esd (dism /Mount-Image /ReadOnly):
  - WinRE (Windows\System32\Recovery\Winre.wim) is present
  - none of the configured AppX packages, capabilities or packages is present
  - every value of the enabled Registry groups is set (or deleted) in the image's hives
  - the drivers the manifest says were added are installed (dism /Get-Drivers)
- boot.wim's Setup image: the LabConfig values from config.json, and its drivers

Nothing is changed: images are mounted read-only and discarded, hives are only
queried with reg.exe. Writes a text and a JSON report to -OutputDirectory.

Run it elevated, as SYSTEM if your session restricts loading registry hives or
servicing mounted images (reg load / dism /Image fail), e.g. from a temporary
scheduled task - see README.md. If a hive can't be loaded, it stops with a
message saying so.

Exit code is 0 if every check passed (warnings allowed) and 1 if any failed or
the test could not run.

.EXAMPLE
.\Test-CustomizedIso.ps1 -IsoPath Y:\Images\Customized\WindowsServer2025.iso -OutputDirectory Y:\IsoBuild\Logs
#>
param (
  [Parameter(Mandatory = $true)]
  [string] $IsoPath,
  # defaults: config.json and autounattend.xml next to this script
  [string] $ConfigFile,
  [string] $Autounattend,
  # default: <IsoPath>.json if it exists; lists the drivers that should be in each image
  [string] $ManifestPath,
  # driver .inf base names (e.g. vioscsi) expected in every image and in boot.wim; overrides the manifest
  [string[]] $ExpectDrivers,
  # where the reports go; default: logs\ next to this script
  [string] $OutputDirectory,
  # scratch space for the mount point (and exported ESD indexes); default: %TEMP%\Test-CustomizedIso-<pid>
  [string] $WorkingDir
)

# $PSScriptRoot is empty in parameter defaults in Windows PowerShell
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.json' }
if (-not $Autounattend) { $Autounattend = Join-Path $PSScriptRoot 'autounattend.xml' }
if (-not $ManifestPath -and (Test-Path "$IsoPath.json")) { $ManifestPath = "$IsoPath.json" }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'logs' }
if (-not $WorkingDir) { $WorkingDir = Join-Path $env:TEMP "Test-CustomizedIso-$PID" }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$MountDir = Join-Path $WorkingDir 'Mount'
$HiveFiles = @{
  SOFTWARE    = 'Windows\System32\config\SOFTWARE'
  SYSTEM      = 'Windows\System32\config\SYSTEM'
  DEFAULTUSER = 'Users\Default\NTUSER.DAT'
}
$script:Checks = [System.Collections.Generic.List[object]]::new()
$script:LoadedHives = [System.Collections.Generic.List[string]]::new()
$script:Mounted = $false

function Get-ConfigValue($Object, [string] $Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}

# Result: Pass, Fail, Warn or Info
function Add-Check([string] $Scope, [string] $Check, [string] $Result, [string] $Detail = '') {
  $script:Checks.Add([PSCustomObject]@{ Scope = $Scope; Check = $Check; Result = $Result; Detail = $Detail })
  $Line = "[$($Result.ToUpperInvariant())] $($Scope): $Check$(if ($Detail) { " - $Detail" })"
  if ($Result -eq 'Fail') { Write-Warning $Line } else { Write-Host $Line }
}

# as in Customize-Iso.ps1: capture output, relax $ErrorActionPreference around 2>&1
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
  finally { $ErrorActionPreference = $PreviousPreference }
  $Output = @($Output | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*\[[= ]*\d+(\.\d+)?%[= ]*\]\s*$' })
  if ($SuccessExitCodes -notcontains $ExitCode -and -not $AllowFailure) {
    throw "'$FilePath $($ArgumentList -join ' ')' failed with exit code $($ExitCode): $(($Output | Select-Object -Last 10) -join ' | ')"
  }
  [PSCustomObject]@{ ExitCode = $ExitCode; Output = $Output }
}

function Find-Dism {
  $Adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe"
  if (Test-Path $Adk) { return $Adk }
  Join-Path $env:SystemRoot 'System32\dism.exe'
}

function Invoke-Dism([string[]] $Arguments, [switch] $AllowFailure) {
  Invoke-Native $script:Dism ($Arguments + @('/English', "/LogPath:$(Join-Path $WorkingDir 'dism.log')")) -SuccessExitCodes @(0, 3010) -AllowFailure:$AllowFailure
}

function Mount-ReadOnly([string] $ImageFile, [int] $Index) {
  Invoke-Dism @('/Mount-Image', "/ImageFile:$ImageFile", "/Index:$Index", "/MountDir:$MountDir", '/ReadOnly') | Out-Null
  $script:Mounted = $true
}

function Dismount-ReadOnly {
  if ($script:Mounted) {
    Invoke-Dism @('/Unmount-Image', "/MountDir:$MountDir", '/Discard') | Out-Null
    $script:Mounted = $false
  }
}

#region registry

function Mount-Hive([string] $Hive) {
  $Key = "HKLM\CWIV_$($PID)_$Hive"
  $File = Join-Path $MountDir $HiveFiles[$Hive]
  if (-not (Test-Path $File)) { throw "hive file not found: $File" }
  $Result = Invoke-Native reg.exe @('load', $Key, $File) -AllowFailure
  if ($Result.ExitCode -ne 0) {
    throw "could not load the $Hive hive ($File): $($Result.Output -join ' '). Loading hives needs SeRestorePrivilege; run this elevated, as SYSTEM if your session restricts it (see README.md)."
  }
  $script:LoadedHives.Add($Key)
  $Key
}

function Dismount-Hive([string] $Key) {
  for ($Attempt = 1; $Attempt -le 10; $Attempt++) {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if ((Invoke-Native reg.exe @('unload', $Key) -AllowFailure).ExitCode -eq 0) {
      $script:LoadedHives.Remove($Key) | Out-Null
      return
    }
    Start-Sleep -Seconds 3
  }
  throw "failed to unload $Key"
}

# A value as reg.exe shows it: Type and Data text, or $null if the value (or key) doesn't exist
function Get-RegValue([string] $Key, [string] $Name) {
  $Result = Invoke-Native reg.exe @('query', $Key, '/v', $Name) -AllowFailure
  if ($Result.ExitCode -ne 0) { return $null }
  foreach ($Line in $Result.Output) {
    if ($Line -match "^\s+$([regex]::Escape($Name))\s+(REG_[A-Z_]+)\s*(.*)$") {
      return [PSCustomObject]@{ Type = $Matches[1]; Data = $Matches[2].Trim() }
    }
  }
  $null
}

# Does reg.exe's text for a value match the configured Data?
function Test-RegData([string] $Type, [string] $Actual, $Expected) {
  switch ($Type) {
    { $_ -in 'REG_DWORD', 'REG_QWORD' } {
      $Number = if ($Actual -match '^0x([0-9a-fA-F]+)$') { [Convert]::ToUInt64($Matches[1], 16) } else { return $false }
      return $Number -eq [uint64]$Expected
    }
    'REG_MULTI_SZ' { return $Actual -eq (@($Expected) -join '\0') }
    'REG_BINARY' { return $Actual -eq ("$Expected" -replace '[^0-9a-fA-F]', '') }
    default { return $Actual -ceq "$Expected" }
  }
}

function Test-ImageRegistry([string] $Scope, [object[]] $Groups) {
  $Groups = @($Groups | Where-Object { Get-ConfigValue $_ 'Enabled' $true })
  if (-not $Groups) { Add-Check $Scope 'registry' 'Info' 'no registry groups enabled'; return }

  $Hives = @{}
  try {
    foreach ($HiveName in @($Groups | ForEach-Object { $_.Values } | ForEach-Object { $_.Hive } | Sort-Object -Unique)) {
      if (-not $HiveFiles.ContainsKey($HiveName)) { throw "unknown hive '$HiveName' in config" }
      $Hives[$HiveName] = Mount-Hive $HiveName
    }
    foreach ($Group in $Groups) {
      $Problems = [System.Collections.Generic.List[string]]::new()
      foreach ($Value in $Group.Values) {
        $Key = "$($Hives[$Value.Hive])\$($Value.Key)"
        $Name = Get-ConfigValue $Value 'Name'
        $Where = "$($Value.Hive)\$($Value.Key)$(if ($Name) { "\$Name" })"
        if (Get-ConfigValue $Value 'Delete' $false) {
          $Exists = if ($Name) { $null -ne (Get-RegValue $Key $Name) } else { (Invoke-Native reg.exe @('query', $Key) -AllowFailure).ExitCode -eq 0 }
          if ($Exists) { $Problems.Add("$Where should be deleted but exists") }
          continue
        }
        $Actual = Get-RegValue $Key $Name
        if (-not $Actual) { $Problems.Add("$Where is missing") }
        elseif ($Actual.Type -ne $Value.Type) { $Problems.Add("$Where is $($Actual.Type), expected $($Value.Type)") }
        elseif (-not (Test-RegData $Actual.Type $Actual.Data $Value.Data)) { $Problems.Add("$Where = $($Actual.Data), expected $($Value.Data)") }
      }
      if ($Problems.Count) { Add-Check $Scope "registry '$($Group.Name)'" 'Fail' ($Problems -join '; ') }
      else { Add-Check $Scope "registry '$($Group.Name)'" 'Pass' "$(@($Group.Values).Count) value(s)" }
    }
  }
  finally {
    foreach ($Key in @($Hives.Values)) { Dismount-Hive $Key }
  }
}

#endregion

#region image checks

function Get-ProvisionedAppx {
  $Result = Invoke-Dism @("/Image:$MountDir", '/Get-ProvisionedAppxPackages') -AllowFailure
  # Server Core has no AppX servicing provider
  if ($Result.ExitCode -eq 87 -and ($Result.Output -match 'option is unknown')) { return $null }
  if ($Result.ExitCode -ne 0) { throw "dism /Get-ProvisionedAppxPackages failed with exit code $($Result.ExitCode): $(($Result.Output | Select-Object -Last 5) -join ' | ')" }
  $Current = @{}
  # the comma keeps an empty list from unrolling to $null (which means "no AppX support")
  return , @(foreach ($Line in $Result.Output) {
      if ($Line -match '^\s*(DisplayName|PackageName)\s*:\s*(.+?)\s*$') { $Current[$Matches[1]] = $Matches[2] }
      if ($Current.ContainsKey('PackageName') -and $Current.ContainsKey('DisplayName')) {
        [PSCustomObject]@{ DisplayName = $Current.DisplayName; PackageName = $Current.PackageName }
        $Current = @{}
      }
    })
}

function Get-InstalledFromTable([string] $Command) {
  foreach ($Line in (Invoke-Dism @("/Image:$MountDir", $Command, '/Format:Table')).Output) {
    $Columns = @($Line -split '\|' | ForEach-Object { $_.Trim() })
    if ($Columns.Count -ge 2 -and $Columns[1] -eq 'Installed') { $Columns[0] }
  }
}

# Original file names (e.g. vioscsi.inf) of the third-party drivers in the mounted image
function Get-DriverInfs {
  @((Invoke-Dism @("/Image:$MountDir", '/Get-Drivers')).Output |
      Where-Object { $_ -match '^\s*Original File Name\s*:\s*(.+?)\s*$' } | ForEach-Object { $Matches[1].ToLowerInvariant() })
}

# Manifest entries look like "[1] Windows 11 Pro: vioscsi\w11" or "boot.wim[2]: vioscsi\w11"
function Get-ExpectedDrivers([string] $LabelLike) {
  if ($ExpectDrivers) { return @($ExpectDrivers) }
  @(foreach ($Entry in @(Get-ConfigValue $script:Manifest 'drivers' @())) {
      if ("$Entry" -match '^(?<label>.+?): (?<driver>[^\\]+)\\' -and $Matches.label -like $LabelLike) { $Matches.driver }
    }) | Sort-Object -Unique
}

function Test-Drivers([string] $Scope, [string[]] $Expected) {
  $Infs = @(Get-DriverInfs)
  if (-not $Expected) {
    Add-Check $Scope 'drivers' 'Info' "none expected; third-party drivers: $(if ($Infs) { $Infs -join ', ' } else { 'none' })"
    return
  }
  $Missing = @($Expected | Where-Object { $Infs -notcontains "$($_.ToLowerInvariant()).inf" })
  if ($Missing) { Add-Check $Scope 'drivers' 'Fail' "missing $($Missing -join ', ') (found: $($Infs -join ', '))" }
  else { Add-Check $Scope 'drivers' 'Pass' ($Expected -join ', ') }
}

function Test-InstallImage([string] $Scope, [int] $Index, $Config) {
  Add-Check $Scope 'WinRE' $(if (Test-Path (Join-Path $MountDir 'Windows\System32\Recovery\Winre.wim')) { 'Pass' } else { 'Fail' }) 'Windows\System32\Recovery\Winre.wim'

  $Packages = Get-ConfigValue $Config.install 'Packages'
  $AppxPatterns = @(Get-ConfigValue $Packages 'AppXPackagesToRemove' @())
  if ($AppxPatterns) {
    $Provisioned = Get-ProvisionedAppx
    if ($null -eq $Provisioned) { Add-Check $Scope 'AppX removed' 'Info' 'image has no AppX support (e.g. Server Core)' }
    else {
      $Present = @($Provisioned | Where-Object { $P = $_; $AppxPatterns | Where-Object { $P.PackageName -like $_ -or $P.DisplayName -like $_ } })
      if ($Present) { Add-Check $Scope 'AppX removed' 'Fail' "still provisioned: $(($Present | ForEach-Object DisplayName) -join ', ')" }
      else { Add-Check $Scope 'AppX removed' 'Pass' "none of $($AppxPatterns.Count) configured package(s) among $(@($Provisioned).Count) provisioned" }
    }
  }
  foreach ($Kind in @(
      @{ Key = 'WindowsCapabilitiesToRemove'; Command = '/Get-Capabilities'; Label = 'capabilities removed' },
      @{ Key = 'WindowsPackagesToRemove'; Command = '/Get-Packages'; Label = 'packages removed' })) {
    $Patterns = @(Get-ConfigValue $Packages $Kind.Key @())
    if (-not $Patterns) { continue }
    $Installed = @(Get-InstalledFromTable $Kind.Command)
    $Present = @($Installed | Where-Object { $Name = $_; $Patterns | Where-Object { $Name -like $_ } })
    if ($Present) { Add-Check $Scope $Kind.Label 'Fail' "still installed: $($Present -join ', ')" }
    else { Add-Check $Scope $Kind.Label 'Pass' "none of $($Patterns.Count) pattern(s) installed" }
  }

  Test-ImageRegistry $Scope @(Get-ConfigValue $Config.install 'Registry' @())
  Test-Drivers $Scope (Get-ExpectedDrivers "[$Index] *")
}

function Test-BootImage([string] $BootWim, $Config) {
  $Images = @(Get-WindowsImage -ImagePath $BootWim)
  $Setup = $Images | Where-Object ImageName -like 'Microsoft Windows Setup*' | Select-Object -Last 1
  $Index = if ($Setup) { $Setup.ImageIndex } elseif ($Images.Count -ge 2) { 2 } else { throw "can't find the Setup image in boot.wim" }
  $Scope = "boot.wim[$Index]"

  Mount-ReadOnly $BootWim $Index
  try {
    $LabConfig = Get-ConfigValue (Get-ConfigValue $Config 'boot') 'LabConfig'
    if ($LabConfig) {
      $Hive = Mount-Hive 'SYSTEM'
      try {
        $Problems = [System.Collections.Generic.List[string]]::new()
        foreach ($Property in @($LabConfig.PSObject.Properties)) {
          $Actual = Get-RegValue "$Hive\Setup\LabConfig" $Property.Name
          $IsOn = $Actual -and $Actual.Type -eq 'REG_DWORD' -and (Test-RegData 'REG_DWORD' $Actual.Data 1)
          if ([bool]$Property.Value -and -not $IsOn) { $Problems.Add("$($Property.Name) should be 1") }
          if (-not [bool]$Property.Value -and $IsOn) { $Problems.Add("$($Property.Name) is 1 but disabled in config") }
        }
        $On = @($LabConfig.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object Name) -join ', '
        if ($Problems.Count) { Add-Check $Scope 'LabConfig' 'Fail' ($Problems -join '; ') }
        else { Add-Check $Scope 'LabConfig' 'Pass' "on: $(if ($On) { $On } else { 'none' })" }
      }
      finally { Dismount-Hive $Hive }
    }
    Test-Drivers $Scope (Get-ExpectedDrivers 'boot.wim*')
  }
  finally { try { Dismount-ReadOnly } catch { Write-Warning "unmount: $_" } }
}

#endregion

$ExitCode = 1
$Started = Get-Date
$RunError = $null
$IsoMountedHere = $false
$CreatedWorkingDir = -not (Test-Path $WorkingDir)
$Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$ReportBase = Join-Path $OutputDirectory "Test-$([System.IO.Path]::GetFileNameWithoutExtension($IsoPath) -replace '[^\w.-]', '')-$($Started.ToString('yyyyMMdd-HHmmss'))"

try {
  if (-not $Identity.IsSystem) {
    Write-Warning "Test-CustomizedIso: running as $($Identity.Name), not SYSTEM. If loading hives or dism /Image fails, run it as SYSTEM (see README.md)."
  }
  $IsoPath = (Resolve-Path $IsoPath).Path
  $Config = Get-Content -Raw $ConfigFile | ConvertFrom-Json
  $script:Manifest = if ($ManifestPath) { Get-Content -Raw $ManifestPath | ConvertFrom-Json } else { $null }
  $script:Dism = Find-Dism
  Write-Host "Test-CustomizedIso: $IsoPath (config $ConfigFile, manifest $(if ($ManifestPath) { $ManifestPath } else { 'none' }), dism $($script:Dism))."

  # a mount point left by a killed run
  New-Item -ItemType Directory -Force -Path $MountDir | Out-Null
  if (@(Get-WindowsImage -Mounted | Where-Object Path -eq $MountDir)) { Invoke-Dism @('/Unmount-Image', "/MountDir:$MountDir", '/Discard') -AllowFailure | Out-Null }

  $DiskImage = Get-DiskImage -ImagePath $IsoPath
  if (-not $DiskImage.Attached) {
    $DiskImage = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -Access ReadOnly -PassThru
    $IsoMountedHere = $true
  }
  $Volume = $null
  for ($i = 0; $i -lt 30 -and -not ($Volume -and $Volume.DriveLetter); $i++) {
    $Volume = $DiskImage | Get-Volume -ErrorAction SilentlyContinue
    if (-not ($Volume -and $Volume.DriveLetter)) { Start-Sleep -Seconds 1 }
  }
  if (-not ($Volume -and $Volume.DriveLetter)) { throw "$IsoPath mounted but no drive letter was assigned." }
  $Root = "$($Volume.DriveLetter):\"

  # media
  $Missing = @('bootmgr', 'efi\boot\bootx64.efi', 'sources\boot.wim', 'autounattend.xml' | Where-Object { -not (Test-Path (Join-Path $Root $_)) })
  Add-Check 'media' 'boot files and autounattend.xml' $(if ($Missing) { 'Fail' } else { 'Pass' }) $(if ($Missing) { "missing: $($Missing -join ', ')" } else { "label $($Volume.FileSystemLabel)" })
  $Install = @('sources\install.wim', 'sources\install.esd' | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ })
  if ($Install.Count -ne 1) { throw "expected one of sources\install.wim or install.esd, found $($Install.Count)." }
  $InstallImage = $Install[0]
  $Images = @(Get-WindowsImage -ImagePath $InstallImage)
  Add-Check 'media' 'install image' 'Info' "$(Split-Path -Leaf $InstallImage): $(($Images | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" }) -join ', ')"
  $ManifestImages = @(Get-ConfigValue $script:Manifest 'images' @())
  if ($script:Manifest -and $ManifestImages.Count -ne $Images.Count) {
    Add-Check 'media' 'images match manifest' 'Fail' "manifest lists $($ManifestImages.Count), ISO has $($Images.Count)"
  }

  # autounattend: several editions -> Setup must ask, so no InstallFrom
  if (Test-Path (Join-Path $Root 'autounattend.xml')) {
    $Ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
    $Count = @(Select-Xml -Path (Join-Path $Root 'autounattend.xml') -XPath '//u:ImageInstall/u:OSImage/u:InstallFrom' -Namespace $Ns).Count
    if ($Images.Count -gt 1) {
      Add-Check 'autounattend' 'InstallFrom vs editions' $(if ($Count) { 'Fail' } else { 'Pass' }) "$($Images.Count) editions, $Count InstallFrom (expected 0 so Setup asks)"
    }
    elseif (Test-Path $Autounattend) {
      $Expected = @(Select-Xml -Path $Autounattend -XPath '//u:ImageInstall/u:OSImage/u:InstallFrom' -Namespace $Ns).Count
      Add-Check 'autounattend' 'InstallFrom vs editions' $(if ($Count -eq $Expected) { 'Pass' } else { 'Fail' }) "1 edition, $Count InstallFrom (template has $Expected)"
    }
    else { Add-Check 'autounattend' 'InstallFrom vs editions' 'Info' "1 edition, $Count InstallFrom (no template to compare)" }
  }

  # $OEM$ stubs, compared with this repo's stub-scripts
  $Oem = Join-Path $Root 'sources\$OEM$\$1'
  $StubRoot = Join-Path $PSScriptRoot 'stub-scripts'
  foreach ($Stub in @(Get-ChildItem $StubRoot -File -Recurse)) {
    $Relative = $Stub.FullName.Substring($StubRoot.Length + 1)
    $OnIso = Join-Path $Oem $Relative
    if (-not (Test-Path $OnIso)) { Add-Check 'OEM stubs' $Relative 'Fail' 'missing from sources\$OEM$\$1' }
    elseif ((Get-FileHash $OnIso).Hash -ne (Get-FileHash $Stub.FullName).Hash) { Add-Check 'OEM stubs' $Relative 'Warn' 'differs from stub-scripts\ (built from another version?)' }
    else { Add-Check 'OEM stubs' $Relative 'Pass' }
  }

  # every image in install.wim/esd; an ESD can't be mounted, so export each index to a WIM first
  foreach ($Image in $Images) {
    $Scope = "[$($Image.ImageIndex)] $($Image.ImageName)"
    $File = $InstallImage
    $Index = $Image.ImageIndex
    if ($InstallImage -like '*.esd') {
      $File = Join-Path $WorkingDir "index$Index.wim"
      if (Test-Path $File) { Remove-Item $File -Force }
      Write-Host "Test-CustomizedIso: exporting $Scope from install.esd to mount it (slow)."
      Invoke-Dism @('/Export-Image', "/SourceImageFile:$InstallImage", "/SourceIndex:$Index", "/DestinationImageFile:$File", '/Compress:fast') | Out-Null
      $Index = 1
    }
    Write-Host "Test-CustomizedIso: mounting $Scope read-only."
    Mount-ReadOnly $File $Index
    try { Test-InstallImage $Scope $Image.ImageIndex $Config }
    finally {
      # a failed unmount must not hide the error that got us here; the final cleanup retries it
      try { Dismount-ReadOnly } catch { Write-Warning "unmount: $_" }
      if ($File -ne $InstallImage) { Remove-Item $File -Force -ErrorAction SilentlyContinue }
    }
  }

  Write-Host 'Test-CustomizedIso: mounting boot.wim read-only.'
  Test-BootImage (Join-Path $Root 'sources\boot.wim') $Config

  $ExitCode = if (@($script:Checks | Where-Object Result -eq 'Fail').Count) { 1 } else { 0 }
}
catch {
  $RunError = "$_"
  if (-not $Identity.IsSystem) { $RunError += ' (not running as SYSTEM: if this session cannot load hives or service mounted images, run it as SYSTEM - see README.md)' }
  Write-Host "Test-CustomizedIso: ERROR: $RunError"
  @(($_.ScriptStackTrace -split '\r?\n') -replace '^', '  at: ') | Write-Host
}
finally {
  foreach ($Key in @($script:LoadedHives)) { try { Dismount-Hive $Key } catch { Write-Warning "cleanup: $_" } }
  try { Dismount-ReadOnly } catch { Write-Warning "cleanup: $_" }
  if ($IsoMountedHere) { try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch { Write-Warning "cleanup: $_" } }
  # keep the scratch folder (dism.log) if something went wrong, and never delete one we did not create
  if ($CreatedWorkingDir -and -not $script:Mounted -and -not $RunError -and (Test-Path $WorkingDir)) { Remove-Item $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue }

  $Counts = @('Pass', 'Fail', 'Warn', 'Info' | ForEach-Object { $R = $_; "$(@($script:Checks | Where-Object Result -eq $R).Count) $($R.ToLowerInvariant())" }) -join ', '
  $Verdict = if ($RunError) { 'ERROR' } elseif ($ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
  $Text = @(
    "Test-CustomizedIso: $Verdict - $IsoPath"
    "Run $($Started.ToString('yyyy-MM-dd HH:mm')) as $($Identity.Name) on $env:COMPUTERNAME; config $ConfigFile"
    "Checks: $Counts"
    $(if ($RunError) { "Error: $RunError" })
    ''
    @($script:Checks | ForEach-Object { "[$($_.Result.ToUpperInvariant())] $($_.Scope): $($_.Check)$(if ($_.Detail) { " - $($_.Detail)" })" })
  ) | Where-Object { $null -ne $_ }
  $Utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText("$ReportBase.txt", ($Text -join "`r`n"), $Utf8)
  [System.IO.File]::WriteAllText("$ReportBase.json", ([PSCustomObject]@{
        iso      = $IsoPath
        result   = $Verdict
        started  = $Started.ToString('o')
        ended    = (Get-Date).ToString('o')
        user     = $Identity.Name
        isSystem = $Identity.IsSystem
        config   = $ConfigFile
        manifest = $ManifestPath
        error    = $RunError
        checks   = @($script:Checks)
      } | ConvertTo-Json -Depth 4), $Utf8)
  Write-Host "Test-CustomizedIso: $Verdict ($Counts). Report: $ReportBase.txt / .json"
}

exit $ExitCode
