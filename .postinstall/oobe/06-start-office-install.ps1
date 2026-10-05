# Starts the Microsoft 365 Apps install in the background, so it runs while the other
# post-install scripts do; y-wait-for-office.ps1 waits for it to finish.
#
# Only on images whose profile asks for it (config.json's OfficeOnFirstLogon registry group
# sets HKLM\SOFTWARE\Customize-WindowsIso\Postinstall InstallOffice = 1), and only if Office
# isn't installed already.
#
# Installs from office\ on the post-install media (USB/Ventoy drive or postinstall-client.iso; fastest
# from an SSD), falling back to Microsoft's CDN for anything missing there. Without office\ on
# any drive, setup.exe is downloaded and Office comes from the CDN.
# What gets installed: .postinstall\office\configuration.xml.

$Marker = Get-ItemProperty 'HKLM:\SOFTWARE\Customize-WindowsIso\Postinstall' -Name InstallOffice -ErrorAction SilentlyContinue
if (-not $Marker -or $Marker.InstallOffice -ne 1) {
  Write-Host 'This image is not set up to get Microsoft 365 Apps; skipping.'
  return
}
$Installed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -Name VersionToReport -ErrorAction SilentlyContinue).VersionToReport
if ($Installed) {
  Write-Host "Microsoft 365 Apps $Installed is already installed; skipping."
  return
}

$Template = Join-Path (Split-Path $PSScriptRoot) 'office\configuration.xml'
if (-not (Test-Path $Template)) {
  Write-Warning "$Template not found; not installing Microsoft 365 Apps."
  return
}

$WorkDir = Join-Path $env:ProgramData 'Customize-WindowsIso\office'
$LogDir = Join-Path $WorkDir 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Test-MicrosoftSigned([string] $Path) {
  $Signature = Get-AuthenticodeSignature -LiteralPath $Path
  $Signature.Status -eq 'Valid' -and $Signature.SignerCertificate.Subject -match '(^|, )O=Microsoft Corporation(,|$)'
}

# office\ with setup.exe and one build under Office\Data, on any drive
$Source = $null
$Version = $null
foreach ($Root in @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Root)) {
  $Candidate = Join-Path $Root 'office'
  if (-not (Test-Path (Join-Path $Candidate 'setup.exe'))) { continue }
  $Build = @(Get-ChildItem (Join-Path $Candidate 'Office\Data') -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d+\.\d+\.\d+\.\d+$' | Sort-Object { [version] $_.Name })
  if (-not $Build) { continue }
  if (-not (Test-MicrosoftSigned (Join-Path $Candidate 'setup.exe'))) {
    Write-Warning "$Candidate\setup.exe is not validly signed by Microsoft; ignoring $Candidate."
    continue
  }
  $Source = $Candidate
  $Version = $Build[-1].Name
  break
}

if ($Source) {
  $Setup = Join-Path $Source 'setup.exe'
  $From = "$Source (build $Version)"
}
else {
  Write-Host 'No office\ folder on any drive; downloading the Office Deployment Tool. Office will come from the internet.'
  $Setup = Join-Path $WorkDir 'setup.exe'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $Setup -UseBasicParsing
  }
  catch {
    Write-Warning "Couldn't download the Office Deployment Tool: $_ Not installing Microsoft 365 Apps."
    return
  }
  if (-not (Test-MicrosoftSigned $Setup)) {
    Write-Warning "The downloaded setup.exe is not validly signed by Microsoft; not running it."
    return
  }
  $From = "Microsoft's CDN"
}

# the template, pointed at the local build (with the CDN for anything missing) and logging here
[xml] $Xml = Get-Content -Raw $Template
$Add = $Xml.Configuration.Add
foreach ($Name in 'SourcePath', 'Version', 'AllowCdnFallback') { $Add.RemoveAttribute($Name) }
if ($Source) {
  $Add.SetAttribute('SourcePath', $Source)
  $Add.SetAttribute('Version', $Version)
  $Add.SetAttribute('AllowCdnFallback', 'TRUE')
}
foreach ($Node in @($Xml.Configuration.SelectNodes('Logging'))) { $Xml.Configuration.RemoveChild($Node) | Out-Null }
$Logging = $Xml.CreateElement('Logging')
$Logging.SetAttribute('Level', 'Standard')
$Logging.SetAttribute('Path', $LogDir)
$Xml.Configuration.AppendChild($Logging) | Out-Null
$Configuration = Join-Path $WorkDir 'configuration.xml'
$Xml.Save($Configuration)

Write-Host "Installing Microsoft 365 Apps from $From in the background..."
$Process = Start-Process -FilePath $Setup -ArgumentList '/configure', "`"$Configuration`"" -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru
# without touching Handle, ExitCode stays empty after the process exits
$null = $Process.Handle

# for y-wait-for-office.ps1: the stub runs every script in this session
$global:OfficeInstall = [PSCustomObject]@{ Process = $Process; Started = Get-Date; From = $From; LogDir = $LogDir }
