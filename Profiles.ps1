# Customization profiles, shared by Customize-Iso.ps1 and Test-CustomizedIso.ps1 (dot-sourced).
# Callers define Get-ConfigValue.
#
# A profile says what is removed from an image and which registry groups are applied:
#   { Description, Extends, Packages: { AppXPackagesToRemove, WindowsCapabilitiesToRemove,
#     WindowsPackagesToRemove }, Registry: [ groups ] }
#   Extends   another profile to start from: its package patterns are added to, and its
#             registry groups are replaced by name (or added) by this profile's.
#
# install.ProfileRules picks a profile per image (each edition in install.wim), first match wins:
#   { IsoName, ImageName, InstallationType, Profile }
#   IsoName           the source ISO's file name, e.g. "WindowsServer2025.iso"
#   ImageName         the edition, e.g. "Windows 11 Pro", "Windows Server 2025 Datacenter"
#   InstallationType  "Client", "Server" or "Server Core"
# Conditions are wildcards (case-insensitive); a rule without conditions matches everything.
# An image that no rule matches fails the build rather than getting an unintended profile.
#
# Configs from before profiles (install.Packages / install.Registry) are one profile,
# "default", used for every image.

$ProfilePackageKeys = @('AppXPackagesToRemove', 'WindowsCapabilitiesToRemove', 'WindowsPackagesToRemove')
$ProfileRuleConditions = @('IsoName', 'ImageName', 'InstallationType')

# Profiles and rules from config.json's install section, with Extends resolved.
# Throws on misconfiguration: an unknown profile, an Extends loop, a rule without a profile.
function Initialize-InstallProfiles($Config) {
  $Install = Get-ConfigValue $Config 'install'
  $Defined = Get-ConfigValue $Install 'Profiles'
  $RuleConfig = @(Get-ConfigValue $Install 'ProfileRules' @())

  if (-not $Defined) {
    # before profiles: the install section itself is the only profile
    $Defined = [PSCustomObject]@{
      default = [PSCustomObject]@{
        Description = 'install.Packages and install.Registry'
        Packages    = Get-ConfigValue $Install 'Packages' ([PSCustomObject]@{})
        Registry    = @(Get-ConfigValue $Install 'Registry' @())
      }
    }
    $RuleConfig = @([PSCustomObject]@{ Profile = 'default' })
  }

  $Raw = @{}
  foreach ($Property in @($Defined.PSObject.Properties)) { $Raw[$Property.Name] = $Property.Value }
  if (-not $Raw.Count) { throw 'install.Profiles is empty.' }

  $Resolved = @{}
  foreach ($Name in @($Raw.Keys)) { $Resolved[$Name] = Resolve-InstallProfile $Name $Raw $Resolved @() }

  $Rules = @(foreach ($Rule in $RuleConfig) {
      $Target = "$(Get-ConfigValue $Rule 'Profile' '')"
      if (-not $Target) { throw "install.ProfileRules: a rule has no Profile ($($Rule | ConvertTo-Json -Compress))." }
      if (-not $Resolved.ContainsKey($Target)) { throw "install.ProfileRules: unknown profile '$Target' (defined: $(@($Raw.Keys | Sort-Object) -join ', '))." }
      $Unknown = @($Rule.PSObject.Properties.Name | Where-Object { $_ -ne 'Profile' -and $_ -notin $ProfileRuleConditions })
      if ($Unknown) { throw "install.ProfileRules: unknown condition(s) $($Unknown -join ', ') (valid: $($ProfileRuleConditions -join ', '))." }
      $Rule
    })
  # one profile and no rules: it applies to everything
  if (-not $Rules -and $Resolved.Count -eq 1) { $Rules = @([PSCustomObject]@{ Profile = @($Resolved.Keys)[0] }) }
  if (-not $Rules) { throw 'install.ProfileRules is empty; with several profiles, rules must say which image gets which.' }

  [PSCustomObject]@{ Profiles = $Resolved; Rules = $Rules }
}

# One profile with its Extends chain applied: package patterns are the union, registry
# groups are the parent's with same-named groups replaced and new ones appended.
function Resolve-InstallProfile([string] $Name, [hashtable] $Raw, [hashtable] $Resolved, [string[]] $Chain) {
  if ($Resolved.ContainsKey($Name)) { return $Resolved[$Name] }
  if (-not $Raw.ContainsKey($Name)) { throw "install.Profiles: '$($Chain[-1])' extends unknown profile '$Name'." }
  if ($Chain -contains $Name) { throw "install.Profiles: Extends loop: $(($Chain + $Name) -join ' -> ')." }

  $Definition = $Raw[$Name]
  $Parent = $null
  $Extends = "$(Get-ConfigValue $Definition 'Extends' '')"
  if ($Extends) { $Parent = Resolve-InstallProfile $Extends $Raw $Resolved ($Chain + $Name) }

  $OwnPackages = Get-ConfigValue $Definition 'Packages'
  $Packages = [ordered]@{}
  foreach ($Key in $ProfilePackageKeys) {
    $Inherited = if ($Parent) { @($Parent.Packages.$Key) } else { @() }
    $Packages[$Key] = @(@($Inherited) + @(Get-ConfigValue $OwnPackages $Key @()) | Where-Object { $_ } | Select-Object -Unique)
  }

  $Registry = [System.Collections.Generic.List[object]]::new()
  if ($Parent) { foreach ($Group in $Parent.Registry) { $Registry.Add($Group) } }
  foreach ($Group in @(Get-ConfigValue $Definition 'Registry' @())) {
    $Existing = @($Registry | Where-Object { $_.Name -eq $Group.Name })
    foreach ($Old in $Existing) { $Registry.Remove($Old) | Out-Null }
    $Registry.Add($Group)
  }

  # (not $Profile: that's PowerShell's automatic $PROFILE)
  $Result = [PSCustomObject]@{
    Name        = $Name
    Description = "$(Get-ConfigValue $Definition 'Description' '')"
    Extends     = $Extends
    Packages    = [PSCustomObject]$Packages
    Registry    = @($Registry)
  }
  $Resolved[$Name] = $Result
  $Result
}

# The profile for one image: the first rule whose conditions all match.
function Select-ImageProfile($State, [string] $IsoName, [string] $ImageName, [string] $InstallationType) {
  $Values = @{ IsoName = $IsoName; ImageName = $ImageName; InstallationType = $InstallationType }
  foreach ($Rule in $State.Rules) {
    $Matched = $true
    foreach ($Condition in $ProfileRuleConditions) {
      $Pattern = Get-ConfigValue $Rule $Condition
      if ($null -ne $Pattern -and $Values[$Condition] -notlike $Pattern) { $Matched = $false; break }
    }
    if ($Matched) { return $State.Profiles[$Rule.Profile] }
  }
  throw "No install.ProfileRules entry matches '$ImageName' ($InstallationType) from $IsoName."
}
