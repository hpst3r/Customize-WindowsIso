#Requires -Version 5.1

<#
.SYNOPSIS
Builds postinstall.iso: a small, non-bootable ISO with the .postinstall folder at its root.

.DESCRIPTION
For virtual machines: attach it as a second CD-ROM next to a customized Windows
ISO and the specialize/OOBE stubs find .postinstall on it, the same way they
would on a USB stick or Ventoy drive.

With -FolderPath, the same tree is also kept as a folder (.postinstall, office,
virtio), for copying to the root of USB/Ventoy drives with Copy-PostinstallMedia.ps1.

The ISO is only rebuilt when the contents of .postinstall (or the virtio-win ISO,
or the Office build) change. Exit code is 0 on success (or when already up to
date) and 1 on failure.

The scripts in .postinstall may contain credentials in plain text; anyone who
can read the ISO can read them.

.EXAMPLE
.\New-PostinstallIso.ps1 -OutPath Y:\Images\Customized\postinstall.iso
#>
param (
  # default: .postinstall next to this script
  [string] $Source,
  # default: postinstall.iso next to this script
  [string] $OutPath,
  # optional: a virtio-win ISO. Its virtio-win-guest-tools.exe is added as
  # virtio\virtio-win-guest-tools.exe for the OOBE script that installs it.
  [string] $VirtIOIsoPath,
  # optional: a Microsoft 365 Apps kit (OfficeKit.ps1's cache\current: setup.exe, Office\Data),
  # added as office\ for .postinstall\oobe\06-start-office-install.ps1
  [string] $OfficePath,
  # optional: also keep the ISO's contents in this folder (the ISO is built from it)
  [string] $FolderPath,
  [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Source) { $Source = Join-Path $PSScriptRoot '.postinstall' }
if (-not $OutPath) { $OutPath = Join-Path $PSScriptRoot 'postinstall.iso' }

$Staging = "$OutPath.staging"
$MarkerName = 'postinstall-media.txt'
$ExitCode = 1

# make $To an exact copy of $From; robocopy only copies what changed
function Sync-Folder([string] $From, [string] $To) {
  $Output = & robocopy.exe $From $To /MIR /R:2 /W:5 /NFL /NDL /NJH /NJS /NP
  # 0-7: success (with or without changes); 8 and up: something failed
  if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> $To failed with exit code $($LASTEXITCODE): $(($Output | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' | ')" }
}

try {
  if (-not (Test-Path $Source -PathType Container)) { throw "New-PostinstallIso: source folder not found: $Source" }
  $Source = (Resolve-Path $Source).Path

  if ($VirtIOIsoPath -and -not (Test-Path $VirtIOIsoPath)) { throw "New-PostinstallIso: virtio-win ISO not found: $VirtIOIsoPath" }
  $OfficeVersion = $null
  if ($OfficePath) {
    $OfficeBuild = @(Get-ChildItem (Join-Path $OfficePath 'Office\Data') -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d+\.\d+\.\d+\.\d+$')
    if (-not (Test-Path (Join-Path $OfficePath 'setup.exe')) -or $OfficeBuild.Count -ne 1) {
      throw "New-PostinstallIso: $OfficePath is not a Microsoft 365 Apps kit (setup.exe and one build under Office\Data)."
    }
    $OfficeVersion = $OfficeBuild[0].Name
  }

  # fingerprint: relative path and content hash of every file, plus the virtio-win ISO and Office build
  $Files = @(Get-ChildItem $Source -Recurse -File -Force | Sort-Object FullName)
  $Entries = @($Files | ForEach-Object { "$($_.FullName.Substring($Source.Length)):$((Get-FileHash -Algorithm SHA256 $_.FullName).Hash)" })
  if ($VirtIOIsoPath) {
    $Item = Get-Item $VirtIOIsoPath
    $Entries += "virtio:$($Item.Length):$($Item.LastWriteTimeUtc.Ticks)"
  }
  if ($OfficePath) { $Entries += "office:$($OfficeVersion):$((Get-FileHash -Algorithm SHA256 (Join-Path $OfficePath 'setup.exe')).Hash)" }
  if ($FolderPath) { $Entries += "folder:$FolderPath" }
  $Sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $Fingerprint = -join ($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($Entries -join '|'))) | ForEach-Object { $_.ToString('x2') })
  }
  finally { $Sha.Dispose() }

  $ManifestPath = "$OutPath.json"
  $UpToDate = -not $Force -and (Test-Path $OutPath) -and (Test-Path $ManifestPath) -and
    ((Get-Content -Raw $ManifestPath | ConvertFrom-Json).fingerprint -eq $Fingerprint) -and
    (-not $FolderPath -or (Test-Path (Join-Path $FolderPath '.postinstall')))

  if ($UpToDate) {
    Write-Host "New-PostinstallIso: $OutPath is up to date."
  }
  else {
    $Oscdimg = @(
      (Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
      "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $Oscdimg) { throw 'New-PostinstallIso: oscdimg.exe not found. Install the Windows ADK Deployment Tools.' }

    # the tree that becomes the ISO: the published folder, updated in place, or a scratch copy
    $Tree = if ($FolderPath) { $FolderPath } else { $Staging }
    if (-not $FolderPath -and (Test-Path $Staging)) { Remove-Item $Staging -Recurse -Force }
    # the folder is mirrored (anything else in it is deleted), so only ever one this script made
    $Marker = Join-Path $Tree $MarkerName
    if ($FolderPath -and @(Get-ChildItem -LiteralPath $FolderPath -Force -ErrorAction SilentlyContinue).Count -and -not (Test-Path $Marker)) {
      throw "New-PostinstallIso: $FolderPath already has other files in it; give -FolderPath an empty or new folder."
    }
    New-Item -ItemType Directory -Force -Path $Tree, (Split-Path $OutPath) | Out-Null
    Set-Content -Encoding ascii -Path $Marker -Value 'Post-install media built by New-PostinstallIso.ps1. Everything here is replaced on each build; copy .postinstall, office and virtio to the root of a USB/Ventoy drive with Copy-PostinstallMedia.ps1.'
    Get-ChildItem -LiteralPath $Tree -Force | Where-Object Name -notin '.postinstall', 'office', 'virtio', $MarkerName | Remove-Item -Recurse -Force

    # the stubs look for <drive>:\.postinstall, so the folder itself goes at the ISO root
    Sync-Folder $Source (Join-Path $Tree '.postinstall')

    $VirtIOLabel = $null
    $VirtIODir = Join-Path $Tree 'virtio'
    if (Test-Path $VirtIODir) { Remove-Item $VirtIODir -Recurse -Force }
    if ($VirtIOIsoPath) {
      # a mount is machine-wide: wait until no build (Customize-Iso.ps1's driver sets) is using
      # the virtio-win ISO, so neither detaches it from under the other
      $VirtIOMutex = New-Object System.Threading.Mutex($false, 'Global\Customize-WindowsIso-VirtIOIso')
      try { if (-not $VirtIOMutex.WaitOne([TimeSpan]::FromHours(3))) { throw 'New-PostinstallIso: the virtio-win ISO stayed in use by another process for 3 hours.' } }
      catch [System.Threading.AbandonedMutexException] { }
      $DiskImage = Get-DiskImage -ImagePath $VirtIOIsoPath
      $MountedHere = -not $DiskImage.Attached
      if ($MountedHere) { $DiskImage = Mount-DiskImage -ImagePath $VirtIOIsoPath -StorageType ISO -Access ReadOnly -PassThru }
      try {
        $Volume = $null
        for ($i = 0; $i -lt 30 -and -not ($Volume -and $Volume.DriveLetter); $i++) {
          $Volume = $DiskImage | Get-Volume -ErrorAction SilentlyContinue
          if (-not ($Volume -and $Volume.DriveLetter)) { Start-Sleep -Seconds 1 }
        }
        if (-not ($Volume -and $Volume.DriveLetter)) { throw "New-PostinstallIso: $VirtIOIsoPath mounted but no drive letter was assigned." }

        $Root = "$($Volume.DriveLetter):\"
        if (-not (Test-Path "$Root\virtio-win-guest-tools.exe")) { throw "New-PostinstallIso: virtio-win-guest-tools.exe not found on $VirtIOIsoPath." }
        New-Item -ItemType Directory -Force -Path $VirtIODir | Out-Null
        $VirtIOLabel = $Volume.FileSystemLabel
        # the bundle, and its two MSIs for installing the drivers and the guest agent separately
        # (a failing guest agent makes the bundle roll back the drivers too, network included)
        foreach ($Relative in 'virtio-win-guest-tools.exe', 'virtio-win-gt-x64.msi', 'guest-agent\qemu-ga-x86_64.msi') {
          $File = Join-Path $Root $Relative
          if (-not (Test-Path $File)) { Write-Warning "New-PostinstallIso: $Relative not found on $VirtIOIsoPath."; continue }
          # upstream (Fedora) builds of the installers are unsigned; RHEL builds are signed.
          # Either is fine, but a signature that no longer matches means the file was modified.
          $Signature = Get-AuthenticodeSignature $File
          if ($Signature.Status -notin 'Valid', 'NotSigned') {
            throw "New-PostinstallIso: $Relative has a bad signature ($($Signature.Status)); refusing to use it."
          }
          $Leaf = Split-Path -Leaf $Relative
          Copy-Item $File $VirtIODir -Force
          # the OOBE script checks an unsigned installer against this before running it
          $Hash = (Get-FileHash -Algorithm SHA256 (Join-Path $VirtIODir $Leaf)).Hash.ToLowerInvariant()
          Set-Content -Encoding ascii -NoNewline -Path (Join-Path $VirtIODir "$Leaf.sha256") -Value $Hash
          Write-Host "New-PostinstallIso: added $Leaf from $VirtIOLabel ($($Signature.Status), sha256 $Hash)."
        }
      }
      finally {
        if ($MountedHere) { Dismount-DiskImage -ImagePath $VirtIOIsoPath | Out-Null }
        try { $VirtIOMutex.ReleaseMutex() } catch { }
        $VirtIOMutex.Dispose()
      }
    }

    $OfficeDir = Join-Path $Tree 'office'
    if ($OfficePath) {
      Sync-Folder $OfficePath $OfficeDir
      Write-Host "New-PostinstallIso: added Microsoft 365 Apps $OfficeVersion."
    }
    elseif (Test-Path $OfficeDir) { Remove-Item $OfficeDir -Recurse -Force }

    $Partial = "$OutPath.partial"
    if (Test-Path $Partial) { Remove-Item $Partial -Force }

    # -h: include hidden files; -u2: UDF only, readable by Windows Setup and WinPE
    $Arguments = "-m -o -h -u2 -udfver102 -lPOSTINSTALL `"$Tree`" `"$Partial`""
    Write-Host "New-PostinstallIso: oscdimg.exe $Arguments"
    $Process = Start-Process -FilePath $Oscdimg -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput "$Staging.out.log" -RedirectStandardError "$Staging.err.log"
    if ($Process.ExitCode -ne 0) {
      throw "New-PostinstallIso: oscdimg.exe failed with exit code $($Process.ExitCode): $((Get-Content "$Staging.err.log" -ErrorAction SilentlyContinue | Select-Object -Last 5) -join ' | ')"
    }

    # publish: old manifest first, so a manifest only ever describes a complete ISO
    if (Test-Path $ManifestPath) { Remove-Item $ManifestPath -Force }
    Move-Item $Partial $OutPath -Force
    [PSCustomObject]@{
      built       = (Get-Date -Format o)
      fingerprint = $Fingerprint
      virtio      = $VirtIOLabel
      sha256      = (Get-FileHash -Algorithm SHA256 $OutPath).Hash.ToLowerInvariant()
      office      = $OfficeVersion
      # not $(if ...): an empty result serializes as {} instead of null
      folder      = if ($FolderPath) { $FolderPath } else { $null }
      files       = @($Files | ForEach-Object { ".postinstall$($_.FullName.Substring($Source.Length))" })
    } | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 -Path $ManifestPath

    Write-Host "New-PostinstallIso: wrote $OutPath ($($Files.Count) files$(if ($OfficeVersion) { ", Microsoft 365 Apps $OfficeVersion" }), $([math]::Round((Get-Item $OutPath).Length / 1GB, 2)) GB)."
  }
  $ExitCode = 0
}
catch {
  Write-Host "New-PostinstallIso: FAILED: $_"
}
finally {
  foreach ($Path in $Staging, "$Staging.out.log", "$Staging.err.log") {
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force -ErrorAction Continue }
  }
}

exit $ExitCode
