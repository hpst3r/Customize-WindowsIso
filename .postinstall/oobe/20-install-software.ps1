# WinGet isn't available on Server Core (no App Installer), so there's nothing to install with
if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType -eq 'Server Core') {
  Write-Host 'Server Core: no WinGet; skipping the software installs.'
  return
}
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Warning 'winget is not available; skipping the software installs.'
  return
}

& winget install google.chrome --accept-source-agreements --accept-package-agreements --disable-interactivity
& winget install microsoft.visualstudiocode --accept-source-agreements --accept-package-agreements --disable-interactivity
