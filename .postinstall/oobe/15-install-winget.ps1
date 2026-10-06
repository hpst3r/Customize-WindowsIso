$progressPreference = 'silentlyContinue'

# WinGet needs App Installer (AppX), which Server Core doesn't have
if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType -eq 'Server Core') {
  Write-Host 'Server Core: WinGet is not supported; skipping.'
  return
}

# without the internet, Install-Module stops at an interactive "NuGet provider is
# required" prompt and first logon hangs there, so check first
try {
  $null = Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2/' -UseBasicParsing -TimeoutSec 30
}
catch {
  Write-Warning "PowerShell Gallery unreachable ($($_.Exception.Message)); skipping the WinGet PowerShell module."
  return
}

Write-Host "Installing WinGet PowerShell module from PSGallery..."
try {
  Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
  Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -ErrorAction Stop | Out-Null
}
catch {
  Write-Warning "Couldn't install the WinGet PowerShell module: $_"
  return
}
Write-Host "Using Repair-WinGetPackageManager cmdlet to bootstrap WinGet..."
Repair-WinGetPackageManager -AllUsers
Write-Host "Done."
