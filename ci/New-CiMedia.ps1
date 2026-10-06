#Requires -Version 5.1

<#
.SYNOPSIS
Builds the post-install ISO the install tests attach: the repo's .postinstall with
ci\postinstall laid over it, plus the VirtIO guest tools and Microsoft 365 Apps.

.DESCRIPTION
The CI overlay replaces the "Press Enter" pauses with completion markers and records a
transcript of the first-logon scripts; everything else is the real post-install media.
The VirtIO ISO and the Office kit are the ones runner-config.json uses. Only rebuilt when
something changed (New-PostinstallIso.ps1's fingerprint). Prints the ISO's path.
#>
param ([string] $ConfigFile = (Join-Path $PSScriptRoot 'ci-config.json'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Ci = Get-Content -Raw $ConfigFile | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Pve.ps1')
$Repo = Split-Path $PSScriptRoot
$Runner = Get-Content -Raw $Ci.RunnerConfigFile | ConvertFrom-Json

$VirtIO = @(Get-CiValue $Runner 'DriverSets' @() | Where-Object { $_.Type -eq 'virtio-iso' -and (Get-CiValue $_ 'Enabled' $true) } | ForEach-Object Path) | Select-Object -First 1
$Office = Join-Path (Get-CiValue (Get-CiValue $Runner 'Office') 'CacheDirectory' (Join-Path (Split-Path $Runner.WorkingDirectory) 'Cache\office')) 'current'

$Source = Join-Path $Ci.WorkDirectory 'ci-postinstall-source'
if (Test-Path $Source) { Remove-Item -LiteralPath $Source -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Source | Out-Null
# the same scripts the runner puts on the real media (runner-config PostinstallSource)
$PostinstallSource = Get-CiValue $Runner 'PostinstallSource' ''
if (-not $PostinstallSource) { $PostinstallSource = Join-Path $Repo '.postinstall' }
Copy-Item (Join-Path $PostinstallSource '*') $Source -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'postinstall\*') $Source -Recurse -Force

$OutPath = Join-Path $Ci.WorkDirectory 'ci-postinstall.iso'
$Arguments = @{ Source = $Source; OutPath = $OutPath }
if ($VirtIO) { $Arguments.VirtIOIsoPath = $VirtIO }
if (Test-Path (Join-Path $Office 'setup.exe')) { $Arguments.OfficePath = $Office } else { Write-Warning "no Office kit in $Office; the CI media has no office\ (clients will install from the CDN)." }
& (Join-Path $Repo 'New-PostinstallIso.ps1') @Arguments | Write-Host
if ($LASTEXITCODE -ne 0) { throw "New-PostinstallIso.ps1 failed ($LASTEXITCODE)." }
$OutPath
