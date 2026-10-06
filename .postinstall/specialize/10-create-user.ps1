# Create a local admin user and set autologon
# The password must meet the password policy: on Windows Server that means complexity (three
# of upper case, lower case, digits, symbols). If it doesn't, the account isn't created and
# the first logon stops at the sign-in screen instead of running the post-install scripts.
$Username = 'admin'
$FullName = 'IT Local Account'
$PasswordString = 'YourSecurePasswordHere'
$Password = ConvertTo-SecureString $PasswordString -AsPlainText -Force

if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
    try {
        New-LocalUser -Name $Username -Password $Password -FullName $FullName -ErrorAction Stop
        Add-LocalGroupMember -Group 'Administrators' -Member $Username
    }
    catch {
        Write-Warning "Couldn't create $($Username): $_ (does the password meet the password policy?)"
        return
    }
}

$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $RegPath -Name 'AutoAdminLogon' -Value '1'
Set-ItemProperty -Path $RegPath -Name 'DefaultUserName' -Value $Username
Set-ItemProperty -Path $RegPath -Name 'DefaultPassword' -Value $PasswordString
#Set-ItemProperty -Path $RegPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME