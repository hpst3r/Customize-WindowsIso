# CI only: replaces the sample 10-create-user.ps1, whose placeholder password fails the
# password-complexity policy of Windows Server. Same account and autologon, with a random
# password that meets it (nobody needs it: the test talks to the machine through the serial
# port and the guest agent, and the VM is thrown away).
$Username = 'admin'
$Characters = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$Random = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
$Bytes = New-Object byte[] 20
$Random.GetBytes($Bytes)
$PasswordString = (-join ($Bytes | ForEach-Object { $Characters[$_ % $Characters.Length] })) + 'Aa1!'
$Password = ConvertTo-SecureString $PasswordString -AsPlainText -Force

if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
  New-LocalUser -Name $Username -Password $Password -FullName 'IT Local Account' -ErrorAction Stop | Out-Null
  Add-LocalGroupMember -Group 'Administrators' -Member $Username
}

$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $RegPath -Name 'AutoAdminLogon' -Value '1'
Set-ItemProperty -Path $RegPath -Name 'DefaultUserName' -Value $Username
Set-ItemProperty -Path $RegPath -Name 'DefaultPassword' -Value $PasswordString
