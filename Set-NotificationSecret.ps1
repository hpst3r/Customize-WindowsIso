#Requires -Version 5.1 -RunAsAdministrator

<#
.SYNOPSIS
Stores (or removes) a secret for Send-BuildNotification.ps1: the SMTP password
or the ntfy access token.

.DESCRIPTION
The secret is encrypted with DPAPI in LocalMachine scope and saved in
notify.secrets.json next to notify.json. Any process on this machine can decrypt
it (that is what lets the SYSTEM task use it), but the file is useless on another
machine. The file's permissions are limited to SYSTEM and Administrators.

The value is never printed or logged. Run this on the machine that runs the
weekly task.

.EXAMPLE
.\Set-NotificationSecret.ps1 -Name SmtpPassword        # prompts for the value

.EXAMPLE
.\Set-NotificationSecret.ps1 -Name NtfyToken -Remove
#>
param (
  [Parameter(Mandatory = $true)]
  [ValidateSet('SmtpPassword', 'NtfyToken')]
  [string] $Name,
  # prompted for if omitted
  [securestring] $Value,
  [switch] $Remove,
  # default: notify.json next to this script; secrets go in notify.secrets.json beside it
  [string] $ConfigFile
)

if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'notify.json' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Directory = Split-Path ([System.IO.Path]::GetFullPath($ConfigFile))
$Path = Join-Path $Directory ([System.IO.Path]::GetFileNameWithoutExtension($ConfigFile) + '.secrets.json')

$Secrets = [ordered]@{}
if (Test-Path $Path) {
  $Existing = Get-Content -Raw $Path | ConvertFrom-Json
  foreach ($Property in @($Existing.PSObject.Properties)) { $Secrets[$Property.Name] = $Property.Value }
}

if ($Remove) {
  $Secrets.Remove($Name)
  Write-Host "Set-NotificationSecret: removed $Name from $Path."
}
else {
  if (-not $Value) { $Value = Read-Host -AsSecureString "Value for $Name" }
  $Bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try { $Plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr) }
  finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr) }
  if (-not $Plain) { throw "Set-NotificationSecret: empty value; use -Remove to delete $Name." }

  Add-Type -AssemblyName System.Security
  $Blob = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($Plain), $null, 'LocalMachine')
  $Plain = $null
  $Secrets[$Name] = [Convert]::ToBase64String($Blob)
  Write-Host "Set-NotificationSecret: stored $Name in $Path (DPAPI, LocalMachine scope)."
}

# write beside the target, lock it down, then swap it in
New-Item -ItemType Directory -Force -Path $Directory | Out-Null
$Temporary = "$Path.tmp"
[System.IO.File]::WriteAllText($Temporary, ([PSCustomObject]$Secrets | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
$Acl = New-Object System.Security.AccessControl.FileSecurity
$Acl.SetAccessRuleProtection($true, $false)
foreach ($Sid in 'S-1-5-18', 'S-1-5-32-544') {
  $Identity = New-Object System.Security.Principal.SecurityIdentifier $Sid
  $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($Identity, 'FullControl', 'Allow')))
}
[System.IO.File]::SetAccessControl($Temporary, $Acl)
Move-Item $Temporary $Path -Force
