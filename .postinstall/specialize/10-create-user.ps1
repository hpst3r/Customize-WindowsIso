# Create a local admin user and set autologon
$Username = 'admin'
$FullName = 'IT Local Account'
$PasswordString = 'YourSecurePasswordHere'
$Password = ConvertTo-SecureString $PasswordString -AsPlainText -Force

if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $Username -Password $Password -FullName $FullName
    Add-LocalGroupMember -Group 'Administrators' -Member $Username
}

$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $RegPath -Name 'AutoAdminLogon' -Value '1'
Set-ItemProperty -Path $RegPath -Name 'DefaultUserName' -Value $Username
Set-ItemProperty -Path $RegPath -Name 'DefaultPassword' -Value $PasswordString
#Set-ItemProperty -Path $RegPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME