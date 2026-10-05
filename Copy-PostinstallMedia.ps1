#Requires -Version 5.1

<#
.SYNOPSIS
Copies the post-install media (.postinstall, office, virtio) to the root of a USB or Ventoy drive.

.DESCRIPTION
The source is the folder New-PostinstallIso.ps1 keeps (runner-config.json's
PostinstallFolder, e.g. \\server\Customized\postinstall) or postinstall.iso.
Each of the three folders is mirrored: only changed files are copied, and files
no longer in the source are deleted from that folder. Nothing else on the drive
(Ventoy ISOs, other folders) is touched.

Installing Microsoft 365 Apps at first logon is fastest from an SSD; on a slow
USB stick, -SkipOffice leaves office\ off and machines download Office instead.

.EXAMPLE
.\Copy-PostinstallMedia.ps1 -Source \\server\Customized\postinstall -Destination E:\
#>
param (
  [Parameter(Mandatory)] [string] $Source,
  # the drive root (or a folder standing in for one)
  [Parameter(Mandatory)] [string] $Destination,
  # don't copy office\ (and remove it from the destination)
  [switch] $SkipOffice
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Mounted = $null
try {
  if ($Source -like '*.iso') {
    $Mounted = (Resolve-Path $Source).Path
    $Image = Mount-DiskImage -ImagePath $Mounted -StorageType ISO -Access ReadOnly -PassThru
    $Volume = $null
    for ($i = 0; $i -lt 30 -and -not ($Volume -and $Volume.DriveLetter); $i++) {
      $Volume = $Image | Get-Volume -ErrorAction SilentlyContinue
      if (-not ($Volume -and $Volume.DriveLetter)) { Start-Sleep -Seconds 1 }
    }
    if (-not ($Volume -and $Volume.DriveLetter)) { throw "$Source mounted but no drive letter was assigned." }
    $Source = "$($Volume.DriveLetter):\"
  }
  if (-not (Test-Path (Join-Path $Source '.postinstall'))) { throw "$Source has no .postinstall folder." }
  if (-not (Test-Path $Destination -PathType Container)) { throw "$Destination not found." }

  $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  foreach ($Name in '.postinstall', 'virtio', 'office') {
    $From = Join-Path $Source $Name
    $To = Join-Path $Destination $Name
    if (($Name -eq 'office' -and $SkipOffice) -or -not (Test-Path $From)) {
      if (Test-Path $To) { Write-Host "Removing $To."; Remove-Item -LiteralPath $To -Recurse -Force }
      continue
    }
    Write-Host "Copying $Name to $To..."
    # /MT: several files at once, which matters for Office's large files on fast drives
    $Output = & robocopy.exe $From $To /MIR /MT:8 /R:2 /W:5 /NFL /NDL /NJH /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> $To failed with exit code $($LASTEXITCODE): $(($Output | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' | ')" }
  }
  Write-Host "Done in $([math]::Round($Stopwatch.Elapsed.TotalMinutes, 1)) minutes."
}
finally {
  if ($Mounted) { Dismount-DiskImage -ImagePath $Mounted | Out-Null }
}
