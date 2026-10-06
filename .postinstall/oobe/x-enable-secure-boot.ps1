# Turns Secure Boot back on at the end of first logon, on Dell PCs installed with it off (e.g.
# from Ventoy). It takes effect at the next restart.
#
# Uses cctk.exe from Dell Command | Configure without installing it: a copy of its X86_64 folder
# in dell\X86_64 on the post-install drive (Copy-PostinstallMedia.ps1 -DellCctk), or an
# installed Command | Configure. cctk.exe must be signed by Dell.
#
# Does nothing on other makes, when Secure Boot is already on, or when Windows booted in legacy
# BIOS mode (Secure Boot needs UEFI; turning it on would make the disk unbootable). If Legacy
# Option ROMs block it, they're turned off first. If a BIOS setup (admin) password is set, it's
# asked for here (never stored or logged); without a console, the script skips instead.
# BitLocker, if already protecting the system drive, is suspended for one restart so the
# Secure Boot change doesn't trigger recovery.
#
# Afterwards the Ventoy drive only boots on this PC if Ventoy's key is enrolled (or Secure
# Boot is turned off again).

$System = Get-CimInstance Win32_ComputerSystem
if ($System.Manufacturer -notmatch '^Dell') {
  Write-Host "Not a Dell ($($System.Manufacturer)); leaving Secure Boot alone."
  return
}

try { $SecureBootOn = Confirm-SecureBootUEFI -ErrorAction Stop }
catch [System.PlatformNotSupportedException] {
  Write-Warning 'Windows booted in legacy BIOS mode. Secure Boot needs UEFI, so it was left off.'
  return
}
catch {
  Write-Warning "Couldn't read the Secure Boot state ($_); leaving it alone."
  return
}
if ($SecureBootOn) {
  Write-Host 'Secure Boot is already on.'
  return
}

$Cctk = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'dell\X86_64\cctk.exe' }) +
  @("${env:ProgramFiles(x86)}\Dell\Command Configure\X86_64\cctk.exe", "$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Cctk) {
  Write-Warning 'Secure Boot is off, but cctk.exe is not in dell\X86_64 on any drive. Turn Secure Boot on in the BIOS setup (F2).'
  return
}
$Signature = Get-AuthenticodeSignature -LiteralPath $Cctk
if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(^|, )O=Dell') {
  Write-Warning "$Cctk is not validly signed by Dell ($($Signature.Status)); not running it."
  return
}

$Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
$script:SetupPassword = $null

# cctk's output and exit code; the arguments may hold the password, so they're never printed
function Invoke-Cctk([string[]] $Arguments) {
  $Output = @(& $Cctk @Arguments 2>&1 | ForEach-Object { "$_" })
  [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = (($Output | Where-Object { $_.Trim() }) -join ' ').Trim() }
}

# set one BIOS option, asking for the setup password if the BIOS wants it
function Set-BiosOption([string] $Option) {
  for ($Attempt = 1; $Attempt -le 4; $Attempt++) {
    $Arguments = @("--$Option")
    if ($script:SetupPassword) { $Arguments += "--ValSetupPwd=$($script:SetupPassword)" }
    $Result = Invoke-Cctk $Arguments
    # 65: setup password required; 58: wrong setup password
    if ($Result.ExitCode -notin 65, 58) { return $Result }
    if (-not $Interactive -or $Attempt -eq 4) { return $Result }
    if ($Result.ExitCode -eq 58) { Write-Warning 'That BIOS setup password is not correct.' }
    $Secure = Read-Host -AsSecureString 'BIOS setup (admin) password, to turn Secure Boot on (Enter to skip)'
    $Bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { $script:SetupPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr) }
    if (-not $script:SetupPassword) { return $Result }
  }
}

Write-Host "Secure Boot is off on this $($System.Model); turning it on with $Cctk..."
$Result = Set-BiosOption 'SecureBoot=Enabled'
# 120: needs UEFI boot mode and Legacy Option ROMs off. Windows booted in UEFI (checked above),
# so it's the option ROMs.
if ($Result.ExitCode -eq 120) {
  Write-Host 'Legacy Option ROMs are on, which Secure Boot does not allow; turning them off first.'
  $Orom = Set-BiosOption 'LegacyOrom=Disabled'
  if ($Orom.ExitCode -eq 0) { $Result = Set-BiosOption 'SecureBoot=Enabled' }
  else { $Result = $Orom }
}
$script:SetupPassword = $null

if ($Result.ExitCode -eq 0) {
  $BitLocker = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
  if ($BitLocker -and $BitLocker.ProtectionStatus -eq 'On') {
    Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 | Out-Null
    Write-Host 'BitLocker is suspended for one restart so the change does not ask for the recovery key.'
  }
  Write-Host 'Secure Boot is set to turn on at the next restart.' -ForegroundColor Green
}
else {
  # 64: not a Dell; 140: BIOS without WMI-ACPI support (needs a BIOS update)
  Write-Warning "cctk could not turn Secure Boot on (exit code $($Result.ExitCode)): $($Result.Output) Turn it on in the BIOS setup (F2)."
}
