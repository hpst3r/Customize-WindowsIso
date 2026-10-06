#Requires -Version 5.1

<#
.SYNOPSIS
Checks an installed test VM against what its ISO promised. Runs inside the guest as
SYSTEM (sent by Test-IsoOnPve.ps1 through the QEMU guest agent).

.DESCRIPTION
-ExpectedFile is JSON written by Test-IsoOnPve.ps1 from the ISO's manifest and its
profile in config.json. Prints one JSON object: { checks: [ { name, result, detail } ],
facts: { ... } }, result being Pass, Fail, Warn or Info, and saves it beside -ExpectedFile
as results.json.
#>
param ([Parameter(Mandatory)] [string] $ExpectedFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Expected = Get-Content -Raw $ExpectedFile | ConvertFrom-Json
$CiDir = Split-Path $ExpectedFile
$Checks = [System.Collections.Generic.List[object]]::new()
$Facts = [ordered]@{}

function Get-Value($Object, [string] $Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}
function Add-Check([string] $Name, [string] $Result, [string] $Detail = '') {
  $Checks.Add([PSCustomObject]@{ name = $Name; result = $Result; detail = $Detail })
}
# run a check; an exception in it is a failure of that check, not of the run
function Invoke-Check([string] $Name, [scriptblock] $Block) {
  try { & $Block } catch { Add-Check $Name 'Fail' "check threw: $_" }
}
function Test-Version([string] $Actual, [string] $Minimum) {
  try { [version] $Actual -ge [version] $Minimum } catch { $false }
}

$Os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$Caption = (Get-CimInstance Win32_OperatingSystem).Caption
$IsServer = $Os.InstallationType -ne 'Client'
$Facts.caption = $Caption
$Facts.build = "$($Os.CurrentBuild).$($Os.UBR)"
$Facts.displayVersion = Get-Value $Os 'DisplayVersion'
$Facts.installationType = $Os.InstallationType
$Facts.editionId = $Os.EditionID

# the local admin from .postinstall\specialize\10-create-user.ps1, logged on by autologon;
# its hive is loaded while it is logged on, otherwise load it from the profile
$AdminName = Get-Value $Expected 'adminUser' 'admin'
$Admin = Get-LocalUser -Name $AdminName -ErrorAction SilentlyContinue
$AdminHive = $null
$LoadedAdminHive = $false
if ($Admin) {
  if (Test-Path "Registry::HKEY_USERS\$($Admin.SID)") { $AdminHive = "Registry::HKEY_USERS\$($Admin.SID)" }
  else {
    $ProfilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($Admin.SID)" -ErrorAction SilentlyContinue).ProfileImagePath
    if ($ProfilePath -and (Test-Path "$ProfilePath\NTUSER.DAT")) {
      & reg.exe load 'HKU\CI_ADMIN' "$ProfilePath\NTUSER.DAT" | Out-Null
      if ($LASTEXITCODE -eq 0) { $AdminHive = 'Registry::HKEY_USERS\CI_ADMIN'; $LoadedAdminHive = $true }
    }
  }
}
$Facts.adminLoggedOn = $AdminHive -and -not $LoadedAdminHive

#region first logon

Invoke-Check 'post-install: specialize scripts' {
  $Marker = Join-Path $CiDir 'specialize-complete.json'
  if (Test-Path $Marker) { Add-Check 'post-install: specialize scripts' 'Pass' "finished $((Get-Content -Raw $Marker | ConvertFrom-Json).completed)" }
  else { Add-Check 'post-install: specialize scripts' 'Fail' 'specialize-complete.json is missing: the specialize stub or its scripts did not run to the end' }
}

Invoke-Check 'post-install: first-logon scripts' {
  $Marker = Join-Path $CiDir 'oobe-complete.json'
  $Transcript = Join-Path $CiDir 'oobe-transcript.log'
  # (still open when the CI media runs the checks at the end of first logon)
  $Lines = @(if (Test-Path $Transcript) {
      $Stream = [IO.File]::Open($Transcript, 'Open', 'Read', 'ReadWrite')
      try { (New-Object IO.StreamReader $Stream).ReadToEnd() -split '\r?\n' } finally { $Stream.Dispose() }
    })
  $Errors = @($Lines | Where-Object { $_ -match '^Error executing script' })
  $Warnings = @($Lines | Where-Object { $_ -match '^WARNING:' })
  if (-not (Test-Path $Marker)) { Add-Check 'post-install: first-logon scripts' 'Fail' 'oobe-complete.json is missing: the first-logon scripts did not run to the end' }
  elseif ($Errors) { Add-Check 'post-install: first-logon scripts' 'Fail' ($Errors -join ' | ') }
  else { Add-Check 'post-install: first-logon scripts' 'Pass' "finished $((Get-Content -Raw $Marker | ConvertFrom-Json).completed)" }
  if ($Warnings) { Add-Check 'post-install: script warnings' 'Warn' ($Warnings -join ' | ') }

  # non-terminating errors don't stop a script (so the stub reports success), but they are
  # printed: "<Command> : <message>" followed by "At <script>:<line> char:<n>"
  $Records = @(for ($i = 1; $i -lt $Lines.Count; $i++) {
      if ($Lines[$i] -match '^At (.+\.ps1):(\d+) char:') {
        $Where = "$(Split-Path -Leaf $Matches[1]):$($Matches[2])"
        # the message may wrap over a few lines; its first line is "<Command> : <message>"
        $Message = @($Lines[[Math]::Max(0, $i - 4)..($i - 1)] | Where-Object { $_ -match '^\S.* : ' } | Select-Object -Last 1)
        "$($Where): $(if ($Message) { $Message[0].Trim() } else { $Lines[$i - 1].Trim() })"
      }
    })
  if ($Records) {
    $Unique = @($Records | Select-Object -Unique)
    Add-Check 'post-install: script errors (non-terminating)' 'Warn' "$($Records.Count) error record(s): $(($Unique | Select-Object -First 5) -join ' | ')"
  }
}

#endregion

#region OS

Invoke-Check 'os: edition' {
  $Want = "$($Expected.edition)" -replace '\s*\(Desktop Experience\)$', ''
  $WantType = if ($Expected.edition -like 'Windows Server*') { if ($Expected.edition -like '*(Desktop Experience)') { 'Server' } else { 'Server Core' } } else { 'Client' }
  # (Insider builds say "Windows 11 Pro Insider Preview")
  if ($Caption -notlike "*$Want*") { Add-Check 'os: edition' 'Fail' "installed '$Caption', expected '$($Expected.edition)'" }
  elseif ($Os.InstallationType -ne $WantType) { Add-Check 'os: edition' 'Fail' "installation type $($Os.InstallationType), expected $WantType" }
  else { Add-Check 'os: edition' 'Pass' "$Caption ($($Os.InstallationType))" }
}

Invoke-Check 'os: build' {
  # the image's version is what Setup applied; nothing updates it before first logon
  $Want = [version] $Expected.version
  $Have = "$($Want.Major).$($Want.Minor).$($Os.CurrentBuild).$($Os.UBR)"
  if ($Have -eq "$Want") { Add-Check 'os: build' 'Pass' $Have }
  elseif ([version] $Have -gt $Want) { Add-Check 'os: build' 'Warn' "$Have, newer than the image's $Want (updated after install?)" }
  else { Add-Check 'os: build' 'Fail' "$Have, expected $Want" }
}

Invoke-Check 'os: local admin' {
  if (-not $Admin) { Add-Check 'os: local admin' 'Fail' "user '$AdminName' does not exist"; return }
  $InGroup = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID -eq $Admin.SID })
  if ($InGroup) { Add-Check 'os: local admin' 'Pass' "$AdminName is an administrator" } else { Add-Check 'os: local admin' 'Fail' "$AdminName is not in Administrators" }
}

Invoke-Check 'os: WinRE' {
  $Info = (& reagentc.exe /info) -join "`n"
  if ($Info -match 'Windows RE status:\s+Enabled') { Add-Check 'os: WinRE' 'Pass' 'enabled' } else { Add-Check 'os: WinRE' 'Fail' 'reagentc /info: WinRE is not enabled' }
}

Invoke-Check 'os: Secure Boot / TPM' {
  $SecureBoot = try { Confirm-SecureBootUEFI } catch { $null }
  $Tpm = try { (Get-Tpm).TpmPresent } catch { $null }
  $Facts.secureBoot = $SecureBoot
  $Facts.tpm = $Tpm
  Add-Check 'os: Secure Boot / TPM' 'Info' "Secure Boot: $SecureBoot, TPM: $Tpm"
}

#endregion

#region VirtIO, drivers, network

Invoke-Check 'virtio: boot disk on vioscsi' {
  $Controller = @(Get-CimInstance Win32_SCSIController | Where-Object { $_.Name -match 'VirtIO SCSI' })
  $SystemDisk = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) | Get-Disk
  $Facts.systemDisk = "$($SystemDisk.FriendlyName) ($($SystemDisk.BusType))"
  # vioscsi disks show up as SAS
  if ($Controller -and "$($SystemDisk.BusType)" -in 'SAS', 'SCSI') { Add-Check 'virtio: boot disk on vioscsi' 'Pass' "$($Controller[0].Name); system disk $($SystemDisk.FriendlyName) ($($SystemDisk.BusType))" }
  elseif ($Controller) { Add-Check 'virtio: boot disk on vioscsi' 'Warn' "controller present, system disk bus $($SystemDisk.BusType)" }
  else { Add-Check 'virtio: boot disk on vioscsi' 'Fail' 'no VirtIO SCSI controller' }
}

Invoke-Check 'drivers: from the image' {
  $Want = @(Get-Value $Expected 'drivers' @())
  if (-not $Want) { Add-Check 'drivers: from the image' 'Info' 'none expected'; return }
  $Installed = @(Get-WindowsDriver -Online | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.OriginalFileName) })
  $Missing = @($Want | Where-Object { $Installed -notcontains $_ })
  if ($Missing) { Add-Check 'drivers: from the image' 'Fail' "missing: $($Missing -join ', ')" } else { Add-Check 'drivers: from the image' 'Pass' ($Want -join ', ') }
}

Invoke-Check 'network: adapter' {
  $Adapter = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
  $Address = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })
  $Facts.ipv4 = @($Address | ForEach-Object IPAddress)
  if (-not $Adapter) { Add-Check 'network: adapter' 'Fail' 'no adapter is up' }
  elseif (-not $Address) { Add-Check 'network: adapter' 'Fail' "$($Adapter[0].InterfaceDescription) is up but has no IPv4 address" }
  else { Add-Check 'network: adapter' 'Pass' "$($Adapter[0].InterfaceDescription), $($Address[0].IPAddress)" }
}

Invoke-Check 'network: internet' {
  $Response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 30
  if ($Response.Content -match 'Microsoft Connect Test') { Add-Check 'network: internet' 'Pass' 'msftconnecttest.com reachable' } else { Add-Check 'network: internet' 'Fail' 'unexpected response from msftconnecttest.com' }
}

Invoke-Check 'virtio: guest tools' {
  $Service = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
  $Package = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
      # the all-in-one installer, or its drivers MSI installed on its own
      Where-Object { (Get-Value $_ 'DisplayName') -like 'Virtio-win*' })
  if ($Service -and $Service.Status -eq 'Running' -and $Package) { Add-Check 'virtio: guest tools' 'Pass' "$($Package[0].DisplayName) $($Package[0].DisplayVersion), QEMU-GA running" }
  else { Add-Check 'virtio: guest tools' 'Fail' "guest tools package: $([bool]$Package), QEMU-GA: $(if ($Service) { $Service.Status } else { 'missing' })" }
}

#endregion

#region profile: AppX, capabilities, registry

Invoke-Check 'profile: AppX removed' {
  $Patterns = @(Get-Value $Expected 'appx' @())
  if (-not $Patterns) { Add-Check 'profile: AppX removed' 'Info' 'none configured'; return }
  $Provisioned = try { @(Get-AppxProvisionedPackage -Online) } catch { $null }
  if ($null -eq $Provisioned) { Add-Check 'profile: AppX removed' 'Info' 'no AppX support (Server Core)'; return }
  $Present = @($Provisioned | Where-Object { $P = $_; @($Patterns | Where-Object { $P.DisplayName -like $_ -or $P.PackageName -like $_ }).Count })
  $ForUser = @(Get-AppxPackage -AllUsers | Where-Object { $P = $_; @($Patterns | Where-Object { $P.Name -like $_ }).Count } | ForEach-Object Name | Sort-Object -Unique)
  if ($Present) { Add-Check 'profile: AppX removed' 'Fail' "still provisioned: $(($Present | ForEach-Object DisplayName) -join ', ')" }
  else { Add-Check 'profile: AppX removed' 'Pass' "none of $($Patterns.Count) provisioned" }
  if ($ForUser) { Add-Check 'profile: AppX for the user' 'Warn' "installed for a user anyway (pushed by Windows/Store after setup?): $($ForUser -join ', ')" }
}

Invoke-Check 'profile: capabilities removed' {
  $Patterns = @(Get-Value $Expected 'capabilities' @())
  if (-not $Patterns) { Add-Check 'profile: capabilities removed' 'Info' 'none configured'; return }
  $Installed = @(Get-WindowsCapability -Online | Where-Object State -eq 'Installed' | ForEach-Object Name)
  $Present = @($Installed | Where-Object { $N = $_; @($Patterns | Where-Object { $N -like $_ }).Count })
  if ($Present) { Add-Check 'profile: capabilities removed' 'Fail' "installed: $($Present -join ', ')" } else { Add-Check 'profile: capabilities removed' 'Pass' "none of $($Patterns.Count) installed" }
}

function Get-RegData([string] $Path, [string] $Name) {
  $Key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $Key) { return $null }
  if ($Key.GetValueNames() -notcontains $Name) { return $null }
  [PSCustomObject]@{ Kind = $Key.GetValueKind($Name); Data = $Key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') }
}
$KindNames = @{ REG_DWORD = 'DWord'; REG_QWORD = 'QWord'; REG_SZ = 'String'; REG_EXPAND_SZ = 'ExpandString'; REG_MULTI_SZ = 'MultiString'; REG_BINARY = 'Binary' }

# one registry group against one root; returns the problems
function Test-RegistryValues($Values, [hashtable] $Roots) {
  foreach ($Value in $Values) {
    $Root = $Roots[$Value.Hive]
    if (-not $Root) { continue }
    $Path = "$Root\$($Value.Key)"
    $Name = Get-Value $Value 'Name'
    $Where = "$($Value.Hive)\$($Value.Key)$(if ($Name) { "\$Name" })"
    if (Get-Value $Value 'Delete' $false) {
      $Exists = if ($Name) { $null -ne (Get-RegData $Path $Name) } else { Test-Path -LiteralPath $Path }
      if ($Exists) { "$Where should be deleted but exists" }
      continue
    }
    $Actual = Get-RegData $Path $Name
    if (-not $Actual) { "$Where is missing"; continue }
    if ("$($Actual.Kind)" -ne $KindNames[$Value.Type]) { "$Where is $($Actual.Kind), expected $($Value.Type)"; continue }
    if ("$(@($Actual.Data) -join ',')" -ne "$(@($Value.Data) -join ',')") { "$Where = $($Actual.Data), expected $($Value.Data)" }
  }
}

Invoke-Check 'profile: registry' {
  $Groups = @(Get-Value $Expected 'registry' @())
  if (-not $Groups) { Add-Check 'profile: registry' 'Info' 'no registry groups'; return }
  $DefaultHive = 'HKU\CI_DEFAULT'
  & reg.exe load $DefaultHive "$env:SystemDrive\Users\Default\NTUSER.DAT" | Out-Null
  try {
    foreach ($Group in $Groups) {
      # machine values and the Default profile must be as configured; the logged-on user's
      # copy is informational, since Windows rewrites some of them at first logon
      $Problems = @(Test-RegistryValues $Group.Values @{ SOFTWARE = 'HKLM:\SOFTWARE'; SYSTEM = 'HKLM:\SYSTEM'; DEFAULTUSER = 'Registry::HKEY_USERS\CI_DEFAULT' })
      if ($Problems) { Add-Check "registry '$($Group.Name)'" 'Fail' ($Problems -join '; ') }
      else { Add-Check "registry '$($Group.Name)'" 'Pass' "$(@($Group.Values).Count) value(s)" }
      if ($AdminHive -and @($Group.Values | Where-Object Hive -eq 'DEFAULTUSER')) {
        $UserProblems = @(Test-RegistryValues $Group.Values @{ DEFAULTUSER = $AdminHive })
        if ($UserProblems) { Add-Check "registry '$($Group.Name)' for $AdminName" 'Warn' ($UserProblems -join '; ') }
      }
    }
  }
  finally {
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    & reg.exe unload $DefaultHive | Out-Null
  }
}

#endregion

#region software: WinGet, Office, Defender

Invoke-Check 'winget: App Installer' {
  # the build records the bundle version (e.g. 2026.917.151.0), which is what is provisioned;
  # the package installed for a user has the app's own version (e.g. 1.29.379.0)
  $Want = Get-Value $Expected 'winget'
  if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) -or $Os.InstallationType -eq 'Server Core') {
    Add-Check 'winget: App Installer' 'Info' 'no AppX on Server Core'; return
  }
  $Installed = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Sort-Object { [version] $_.Version } -Descending)
  $Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller' | Sort-Object { [version] $_.Version } -Descending)
  $Facts.appInstaller = "provisioned $(if ($Provisioned) { $Provisioned[0].Version } else { 'none' }), installed $(if ($Installed) { $Installed[0].Version } else { 'none' })"
  if (-not $Want) { Add-Check 'winget: App Installer' 'Info' "not provisioned by the build; $($Facts.appInstaller)"; return }
  if (-not $Provisioned) { Add-Check 'winget: App Installer' 'Fail' "not provisioned; $($Facts.appInstaller)" }
  elseif (-not (Test-Version $Provisioned[0].Version $Want)) { Add-Check 'winget: App Installer' 'Fail' "provisioned $($Provisioned[0].Version), older than the build's $Want" }
  elseif (-not $Installed) { Add-Check 'winget: App Installer' 'Fail' "provisioned $($Provisioned[0].Version) but not installed for any user" }
  else { Add-Check 'winget: App Installer' 'Pass' $Facts.appInstaller }
}

Invoke-Check 'winget: software installed' {
  $Want = @(Get-Value $Expected 'software' @())
  if (-not $Want) { Add-Check 'winget: software installed' 'Info' 'none expected'; return }
  $Roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
  # per-user installs (winget's default scope for e.g. VS Code)
  if ($AdminHive) { $Roots += "$AdminHive\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" }
  $Names = @(Get-ItemProperty $Roots -ErrorAction SilentlyContinue | ForEach-Object { Get-Value $_ 'DisplayName' } | Where-Object { $_ })
  $Missing = @($Want | Where-Object { $W = $_; -not @($Names | Where-Object { $_ -like "$W*" }).Count })
  if ($Missing) { Add-Check 'winget: software installed' 'Fail' "not installed (winget install failed?): $($Missing -join ', ')" } else { Add-Check 'winget: software installed' 'Pass' ($Want -join ', ') }
}

Invoke-Check 'office: Microsoft 365 Apps' {
  $Want = Get-Value $Expected 'office'
  $C2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
  $Version = Get-Value $C2r 'VersionToReport'
  $Facts.office = $Version
  if (-not $Want) {
    if ($Version) { Add-Check 'office: Microsoft 365 Apps' 'Fail' "installed ($Version) on an image that shouldn't get it" } else { Add-Check 'office: Microsoft 365 Apps' 'Pass' 'not installed, as expected' }
    return
  }
  if (-not $Version) { Add-Check 'office: Microsoft 365 Apps' 'Fail' 'not installed'; return }
  $Problems = @()
  if (-not (Test-Version $Version $Want.version)) { $Problems += "version $Version, older than the media's $($Want.version)" }
  if ("$(Get-Value $C2r 'ProductReleaseIds')" -notmatch [regex]::Escape($Want.product)) { $Problems += "products $(Get-Value $C2r 'ProductReleaseIds'), expected $($Want.product)" }
  if ($Want.channelId -and "$(Get-Value $C2r 'UpdateChannel')$(Get-Value $C2r 'CDNBaseUrl')" -notmatch $Want.channelId) { $Problems += "channel $(Get-Value $C2r 'CDNBaseUrl'), expected $($Want.channel)" }
  if ($Problems) { Add-Check 'office: Microsoft 365 Apps' 'Fail' ($Problems -join '; ') } else { Add-Check 'office: Microsoft 365 Apps' 'Pass' "$Version, $($Want.product), $($Want.channel)" }
}

Invoke-Check 'defender: platform and engine' {
  $Want = Get-Value $Expected 'defender'
  $Status = try { Get-MpComputerStatus } catch { $null }
  if (-not $Status) { Add-Check 'defender: platform and engine' $(if ($Want) { 'Fail' } else { 'Info' }) 'Get-MpComputerStatus failed (Defender not running?)'; return }
  $Facts.defender = "platform $($Status.AMProductVersion), engine $($Status.AMEngineVersion), signatures $($Status.AntivirusSignatureVersion)"
  if (-not $Want) { Add-Check 'defender: platform and engine' 'Info' $Facts.defender; return }
  $Problems = @()
  if (-not (Test-Version $Status.AMProductVersion $Want.platform)) { $Problems += "platform $($Status.AMProductVersion) < $($Want.platform)" }
  if (-not (Test-Version $Status.AMEngineVersion $Want.engine)) { $Problems += "engine $($Status.AMEngineVersion) < $($Want.engine)" }
  if ($Problems) { Add-Check 'defender: platform and engine' 'Fail' ($Problems -join '; ') } else { Add-Check 'defender: platform and engine' 'Pass' $Facts.defender }
}

#endregion

Invoke-Check 'events: critical' {
  $Since = (Get-CimInstance Win32_OperatingSystem).InstallDate
  $Critical = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1; StartTime = $Since } -ErrorAction SilentlyContinue)
  Add-Check 'events: critical' $(if ($Critical) { 'Warn' } else { 'Pass' }) $(if ($Critical) { (@($Critical | Select-Object -First 5 | ForEach-Object { "$($_.ProviderName) $($_.Id): $(($_.Message -split "`n")[0])" }) -join ' | ') } else { 'none since install' })
}

if ($LoadedAdminHive) {
  [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  & reg.exe unload 'HKU\CI_ADMIN' | Out-Null
}

$Result = [PSCustomObject]@{ checks = $Checks; facts = [PSCustomObject] $Facts }
$Json = $Result | ConvertTo-Json -Depth 5
Set-Content -Encoding utf8 -Path (Join-Path $CiDir 'results.json') -Value $Json
$Json
