# Installs the VirtIO guest tools (remaining drivers and the QEMU guest agent) on QEMU/KVM
# virtual machines. Does nothing on other hardware.
#
# Looks in \virtio on any drive (postinstall-client.iso or postinstall-server.iso, built by
# New-PostinstallIso.ps1 -VirtIOIsoPath) or at the root of an attached virtio-win ISO.
# Installs the drivers (virtio-win-gt-x64.msi) and the guest agent (qemu-ga-x86_64.msi) one
# after the other: in the all-in-one virtio-win-guest-tools.exe, a failing guest agent rolls
# the drivers back too and the machine loses its network (seen on Insider 29xxx, where the
# agent's VSS provider doesn't register). Media without the MSIs get the all-in-one installer.
#
# Upstream builds of the installers are unsigned (the drivers inside are WHQL-signed), so they
# run only if validly signed, or unsigned and matching the .sha256 file that
# New-PostinstallIso.ps1 writes next to them.

# Red Hat / QEMU PCI vendor IDs
$VirtIODevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object InstanceId -match 'VEN_(1AF4|1B36)')
if (-not $VirtIODevices) {
  Write-Host 'No VirtIO devices found; skipping the VirtIO guest tools.'
  return
}

# the first drive with $Name in \virtio or at its root (or below, for the virtio-win ISO's guest-agent\)
function Find-Installer([string] $Name, [string] $IsoSubfolder = '') {
  Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { "$($_.Root)virtio\$Name", "$($_.Root)$IsoSubfolder$Name" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
}

function Test-Trusted([string] $Path) {
  $Signature = Get-AuthenticodeSignature $Path
  if ($Signature.Status -eq 'Valid') { return $true }
  if ($Signature.Status -eq 'NotSigned' -and (Test-Path "$Path.sha256")) {
    return (Get-FileHash -Algorithm SHA256 $Path).Hash -eq (Get-Content -Raw "$Path.sha256").Trim()
  }
  Write-Warning "$Path is $($Signature.Status) and does not match a known checksum; not running it."
  $false
}

# the lines before "Return value 3" in an MSI log: usually the reason it failed
function Write-MsiFailure([string] $LogPath) {
  $Lines = @(Get-Content $LogPath -ErrorAction SilentlyContinue)
  $At = [Array]::FindIndex([string[]] $Lines, [Predicate[string]] { param ($Line) $Line -match 'Return value 3' })
  if ($At -ge 0) {
    Write-Host "  $(Split-Path -Leaf $LogPath):"
    $Lines[[Math]::Max(0, $At - 12)..$At] | ForEach-Object { Write-Host "    $_" }
  }
}

# 3010: installed, reboot required
function Install-Msi([string] $Path, [string] $Label) {
  if (-not (Test-Trusted $Path)) { return $false }
  $Log = Join-Path $env:TEMP "$([IO.Path]::GetFileNameWithoutExtension($Path)).log"
  Write-Host "Installing $Label from $Path..."
  $Process = Start-Process -FilePath msiexec.exe -ArgumentList '/i', "`"$Path`"", '/qn', '/norestart', '/l*v', "`"$Log`"" -Wait -PassThru
  if ($Process.ExitCode -in 0, 3010) { Write-Host "$Label installed (exit code $($Process.ExitCode))."; return $true }
  Write-Warning "$Label failed to install (exit code $($Process.ExitCode)). Log: $Log"
  Write-MsiFailure $Log
  $false
}

$Drivers = Find-Installer 'virtio-win-gt-x64.msi'
$Agent = Find-Installer 'qemu-ga-x86_64.msi' 'guest-agent\'
if ($Drivers -and $Agent) {
  if (-not (Install-Msi $Drivers 'VirtIO drivers')) { return }
  if (-not (Install-Msi $Agent 'QEMU guest agent')) {
    # the agent registers a VSS provider; a VSS service that can't start is the usual cause
    Get-Service VSS, swprv -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  service $($_.Name): $($_.Status), start $($_.StartType)" }
  }
  return
}

# older media: only the all-in-one installer
$Installer = Find-Installer 'virtio-win-guest-tools.exe'
if (-not $Installer) {
  Write-Warning 'VirtIO devices found, but the VirtIO guest tools are not on any drive. Attach postinstall-client.iso or postinstall-server.iso.'
  return
}
if (-not (Test-Trusted $Installer)) { return }

Write-Host "Installing VirtIO guest tools from $Installer..."
# the installer (a WiX bundle) logs itself and each package it installs next to this log
$Log = Join-Path $env:TEMP 'virtio-win-guest-tools.log'
$Process = Start-Process -FilePath $Installer -ArgumentList '/install', '/quiet', '/norestart', '/log', "`"$Log`"" -Wait -PassThru
if ($Process.ExitCode -in 0, 3010) {
  Write-Host "VirtIO guest tools installed (exit code $($Process.ExitCode))."
}
else {
  Write-Warning "VirtIO guest tools installer failed with exit code $($Process.ExitCode). Logs: $env:TEMP\virtio-win-guest-tools*.log"
  Get-Content $Log -ErrorAction SilentlyContinue | Where-Object { $_ -match 'error|failed' } | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }
  foreach ($PackageLog in @(Get-ChildItem $env:TEMP -Filter 'virtio-win-guest-tools_*.log' -ErrorAction SilentlyContinue)) { Write-MsiFailure $PackageLog.FullName }
}
