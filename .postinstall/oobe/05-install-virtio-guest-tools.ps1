# Installs the VirtIO guest tools (remaining drivers, QEMU guest agent, SPICE agent) on
# QEMU/KVM virtual machines. Does nothing on other hardware.
#
# Looks for virtio-win-guest-tools.exe in \virtio on any drive (postinstall.iso built by
# New-PostinstallIso.ps1 -VirtIOIsoPath) or at the root of an attached virtio-win ISO.
#
# Upstream builds of the installer are unsigned (the drivers inside are WHQL-signed), so it
# runs only if it is validly signed, or unsigned and matching the .sha256 file that
# New-PostinstallIso.ps1 writes next to it.

# Red Hat / QEMU PCI vendor IDs
$VirtIODevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object InstanceId -match 'VEN_(1AF4|1B36)')
if (-not $VirtIODevices) {
  Write-Host 'No VirtIO devices found; skipping the VirtIO guest tools.'
  return
}

$Installer = Get-PSDrive -PSProvider FileSystem |
  ForEach-Object { "$($_.Root)virtio\virtio-win-guest-tools.exe", "$($_.Root)virtio-win-guest-tools.exe" } |
  Where-Object { Test-Path $_ } |
  Select-Object -First 1

if (-not $Installer) {
  Write-Warning 'VirtIO devices found, but virtio-win-guest-tools.exe is not on any drive. Attach postinstall.iso.'
  return
}

$Signature = Get-AuthenticodeSignature $Installer
$Trusted = $Signature.Status -eq 'Valid'
if (-not $Trusted -and $Signature.Status -eq 'NotSigned' -and (Test-Path "$Installer.sha256")) {
  $Expected = (Get-Content -Raw "$Installer.sha256").Trim()
  $Trusted = (Get-FileHash -Algorithm SHA256 $Installer).Hash -eq $Expected
}
if (-not $Trusted) {
  Write-Warning "$Installer is $($Signature.Status) and does not match a known checksum; not running it."
  return
}

Write-Host "Installing VirtIO guest tools from $Installer..."
$Process = Start-Process -FilePath $Installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru

# 3010: installed, reboot required
if ($Process.ExitCode -in 0, 3010) {
  Write-Host "VirtIO guest tools installed (exit code $($Process.ExitCode))."
}
else {
  Write-Warning "VirtIO guest tools installer failed with exit code $($Process.ExitCode)."
}
