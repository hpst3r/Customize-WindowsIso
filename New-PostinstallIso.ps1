#Requires -Version 5.1

<#
.SYNOPSIS
Builds postinstall.iso: a small, non-bootable ISO with the .postinstall folder at its root.

.DESCRIPTION
For virtual machines: attach it as a second CD-ROM next to a customized Windows
ISO and the specialize/OOBE stubs find .postinstall on it, the same way they
would on a USB stick or Ventoy drive.

The ISO is only rebuilt when the contents of .postinstall change. Exit code is
0 on success (or when already up to date) and 1 on failure.

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
  [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Source) { $Source = Join-Path $PSScriptRoot '.postinstall' }
if (-not $OutPath) { $OutPath = Join-Path $PSScriptRoot 'postinstall.iso' }

$Staging = "$OutPath.staging"
$ExitCode = 1

try {
  if (-not (Test-Path $Source -PathType Container)) { throw "New-PostinstallIso: source folder not found: $Source" }
  $Source = (Resolve-Path $Source).Path

  # fingerprint: relative path and content hash of every file
  $Files = @(Get-ChildItem $Source -Recurse -File -Force | Sort-Object FullName)
  $Entries = $Files | ForEach-Object { "$($_.FullName.Substring($Source.Length)):$((Get-FileHash -Algorithm SHA256 $_.FullName).Hash)" }
  $Sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $Fingerprint = -join ($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($Entries -join '|'))) | ForEach-Object { $_.ToString('x2') })
  }
  finally { $Sha.Dispose() }

  $ManifestPath = "$OutPath.json"
  $UpToDate = -not $Force -and (Test-Path $OutPath) -and (Test-Path $ManifestPath) -and
    ((Get-Content -Raw $ManifestPath | ConvertFrom-Json).fingerprint -eq $Fingerprint)

  if ($UpToDate) {
    Write-Host "New-PostinstallIso: $OutPath is up to date."
  }
  else {
    $Oscdimg = @(
      (Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
      "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $Oscdimg) { throw 'New-PostinstallIso: oscdimg.exe not found. Install the Windows ADK Deployment Tools.' }

    # the stubs look for <drive>:\.postinstall, so the folder itself goes at the ISO root
    if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Staging, (Split-Path $OutPath) | Out-Null
    Copy-Item $Source (Join-Path $Staging '.postinstall') -Recurse -Force

    $Partial = "$OutPath.partial"
    if (Test-Path $Partial) { Remove-Item $Partial -Force }

    # -h: include hidden files; -u2: UDF only, readable by Windows Setup and WinPE
    $Arguments = "-m -o -h -u2 -udfver102 -lPOSTINSTALL `"$Staging`" `"$Partial`""
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
      files       = @($Files | ForEach-Object { ".postinstall$($_.FullName.Substring($Source.Length))" })
    } | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 -Path $ManifestPath

    Write-Host "New-PostinstallIso: wrote $OutPath ($($Files.Count) files)."
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
