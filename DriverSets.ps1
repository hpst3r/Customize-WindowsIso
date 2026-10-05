# Driver set configuration, shared by runner.ps1 and Customize-Iso.ps1 (dot-sourced).
# Callers define Get-ConfigValue.
#
# A driver set: { Name, Type, Path, Drivers, Targets, Enabled }
#   Type    virtio-iso: a virtio-win ISO; Drivers lists its driver folders and the
#                       OS folder (w11, 2k22, 2k25) is picked per image
#           folder:     a folder of drivers (e.g. exported with pnputil), added
#                       recursively. If it has OS subfolders (w10, w11, 2k19, 2k22,
#                       2k25), only the one matching the image is used.
#   Targets any of boot (boot.wim Setup), install (every install.wim image),
#           winre (Winre.wim inside each install image). Default: all three.
#   Enabled false skips the set. A set with an empty Path is also off.

$DriverSetTypes = @('virtio-iso', 'folder')
$DriverSetTargets = @('boot', 'install', 'winre')
$DriverOsFolders = @('w10', 'w11', '2k19', '2k22', '2k25')

# Enabled driver sets from a config object with DriverSets (or the older VirtIO
# block), normalized and validated. Throws on misconfiguration, including a
# configured Path that doesn't exist - building without the drivers would
# produce images that can't see their disks.
function Get-DriverSets($Config) {
  $Sets = @(Get-ConfigValue $Config 'DriverSets' @())
  $VirtIO = Get-ConfigValue $Config 'VirtIO'
  if (-not ($Config -and $Config.PSObject.Properties['DriverSets']) -and $VirtIO) {
    # before DriverSets: one virtio-win ISO, added everywhere
    $Sets = @([PSCustomObject]@{
        Name    = 'VirtIO'
        Type    = 'virtio-iso'
        Path    = Get-ConfigValue $VirtIO 'IsoPath' ''
        Drivers = @(Get-ConfigValue $VirtIO 'Drivers' @('vioscsi', 'viostor', 'NetKVM'))
        Targets = $DriverSetTargets
      })
  }

  $Names = @{}
  foreach ($Set in $Sets) {
    $Name = "$(Get-ConfigValue $Set 'Name' '')"
    if (-not $Name) { throw "Get-DriverSets: every driver set needs a Name." }
    if ($Names.ContainsKey($Name)) { throw "Get-DriverSets: duplicate driver set name '$Name'." }
    $Names[$Name] = $true

    if (-not (Get-ConfigValue $Set 'Enabled' $true)) { continue }
    $Path = "$(Get-ConfigValue $Set 'Path' '')"
    if (-not $Path) { continue }

    $Type = "$(Get-ConfigValue $Set 'Type' '')".ToLowerInvariant()
    if ($DriverSetTypes -notcontains $Type) { throw "Get-DriverSets: driver set '$Name' has Type '$Type'; valid: $($DriverSetTypes -join ', ')." }

    $Targets = @(@(Get-ConfigValue $Set 'Targets' $DriverSetTargets) | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
    foreach ($Target in $Targets) {
      if ($DriverSetTargets -notcontains $Target) { throw "Get-DriverSets: driver set '$Name' has target '$Target'; valid: $($DriverSetTargets -join ', ')." }
    }
    if (-not $Targets) { throw "Get-DriverSets: driver set '$Name' has no Targets." }

    $Drivers = @()
    if ($Type -eq 'virtio-iso') {
      $Drivers = @(@(Get-ConfigValue $Set 'Drivers' @('vioscsi', 'viostor', 'NetKVM')) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
      if (-not $Drivers) { throw "Get-DriverSets: driver set '$Name' (virtio-iso) has no Drivers." }
      if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Get-DriverSets: driver set '$Name': virtio-win ISO $Path does not exist. Put one there, or set Enabled to false." }
    }
    elseif (-not (Test-Path -LiteralPath $Path -PathType Container)) {
      throw "Get-DriverSets: driver set '$Name': folder $Path does not exist. Create it, or set Enabled to false."
    }

    [PSCustomObject]@{
      Name    = $Name
      Type    = $Type
      Path    = (Get-Item -LiteralPath $Path).FullName
      Drivers = $Drivers
      Targets = $Targets
    }
  }
}

# Identifies a set's contents, so replacing the ISO or changing the folder rebuilds
function Get-DriverSetFingerprint($Set) {
  $Identity = "set:$($Set.Name):$($Set.Type):$($Set.Targets -join ','):$($Set.Drivers -join ',')"
  if ($Set.Type -eq 'virtio-iso') {
    $Item = Get-Item -LiteralPath $Set.Path
    return "$($Identity):$($Item.Length):$($Item.LastWriteTimeUtc.Ticks)"
  }
  # folder: relative path, size and timestamp of every file (hashing driver packs is slow)
  $Root = $Set.Path.TrimEnd('\')
  $Entries = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
      "$($_.FullName.Substring($Root.Length)):$($_.Length):$($_.LastWriteTimeUtc.Ticks)"
    })
  $Sha = [System.Security.Cryptography.SHA256]::Create()
  try { $Hash = -join ($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Entries -join '|')) | ForEach-Object { $_.ToString('x2') }) }
  finally { $Sha.Dispose() }
  "$($Identity):$($Entries.Count):$Hash"
}
