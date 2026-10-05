# Microsoft 365 Apps for the post-install media, dot-sourced by runner.ps1.
# Callers define Get-ConfigValue and Test-MicrosoftSignature.
#
# The cache's current\ folder is the office\ folder of the post-install media:
#   setup.exe       the Office Deployment Tool (ODT)
#   Office\Data\    one build of Microsoft 365 Apps, as setup.exe /download leaves it
#   kit.json        what it is: version, channel, edition, languages
# .postinstall\office\configuration.xml says what to download (and later install), and
# .postinstall\oobe\06-start-office-install.ps1 installs it at first logon.

$OfficeSetupUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
$OfficeReleasesUrl = 'https://clients.config.office.net/releases/v1.0/OfficeReleases'

# Channel, edition and languages from an ODT configuration.xml: what a download depends on
function Get-OfficeDownloadIdentity([string] $ConfigurationFile) {
  [xml] $Xml = Get-Content -Raw $ConfigurationFile
  $Add = $Xml.Configuration.Add
  if (-not $Add) { throw "$ConfigurationFile has no Configuration/Add element." }
  $Languages = @($Add.SelectNodes('Product/Language') | ForEach-Object { $_.ID.ToLowerInvariant() } | Sort-Object -Unique)
  if (-not $Languages) { throw "$ConfigurationFile has no Product/Language." }
  [PSCustomObject]@{
    Channel   = "$(if ($Add.Channel) { $Add.Channel } else { 'Current' })"
    Edition   = "$(if ($Add.OfficeClientEdition) { $Add.OfficeClientEdition } else { '64' })"
    Languages = $Languages
  }
}

# A downloaded kit: setup.exe signed by Microsoft and exactly one build under Office\Data. Throws otherwise.
function Get-OfficeKit([string] $Directory) {
  $Setup = Join-Path $Directory 'setup.exe'
  if (-not (Test-Path $Setup)) { throw "$Directory has no setup.exe." }
  if (-not (Test-MicrosoftSignature $Setup)) { throw "$Setup is not validly signed by Microsoft." }
  $Data = Join-Path $Directory 'Office\Data'
  $Builds = @(Get-ChildItem -LiteralPath $Data -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d+\.\d+\.\d+\.\d+$')
  if ($Builds.Count -ne 1) { throw "$Data holds $($Builds.Count) builds; expected 1." }
  $Version = $Builds[0].Name
  $Cab = @(Get-ChildItem -LiteralPath $Data -Filter "v*_$Version.cab" -File)
  if (-not $Cab) { throw "$Data has no v*_$Version.cab." }
  foreach ($File in $Cab) { if (-not (Test-MicrosoftSignature $File.FullName)) { throw "$($File.FullName) is not validly signed by Microsoft." } }
  $State = Get-Content -Raw (Join-Path $Directory 'kit.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
  [PSCustomObject]@{
    Root      = $Directory
    Version   = $Version
    Channel   = Get-ConfigValue $State 'channel'
    Edition   = Get-ConfigValue $State 'edition'
    Languages = @(Get-ConfigValue $State 'languages' @())
    Setup     = (Get-Item $Setup).VersionInfo.FileVersion
    SizeGB    = [math]::Round((Get-ChildItem -LiteralPath $Directory -Recurse -File | Measure-Object Length -Sum).Sum / 1GB, 2)
  }
}

# The newest build on a channel, from Microsoft's release feed
function Get-OfficeLatestVersion([string] $Channel) {
  $Releases = Invoke-RestMethod -Uri $OfficeReleasesUrl -UseBasicParsing -TimeoutSec 120
  $Match = @($Releases | Where-Object { $_.channelId -eq $Channel -or $_.channel -eq $Channel -or @($_.alternateNames) -contains $Channel })
  if ($Match.Count -ne 1) { throw "channel '$Channel' matches $($Match.Count) entries in $OfficeReleasesUrl." }
  if ("$($Match[0].latestVersion)" -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "no latestVersion for channel '$Channel'." }
  "$($Match[0].latestVersion)"
}

# The ODT itself, refreshed when Microsoft's copy changes; returns the cached setup.exe
function Update-OfficeSetup([string] $Cache) {
  $Setup = Join-Path $Cache 'setup.exe'
  $StateFile = Join-Path $Cache 'setup.json'
  $Head = Invoke-WebRequest -Uri $OfficeSetupUrl -Method Head -UseBasicParsing -TimeoutSec 120
  $Remote = [ordered]@{ etag = "$($Head.Headers['ETag'])"; lastModified = "$($Head.Headers['Last-Modified'])"; length = "$($Head.Headers['Content-Length'])" }
  $State = Get-Content -Raw $StateFile -ErrorAction SilentlyContinue | ConvertFrom-Json
  $Changed = @($Remote.Keys | Where-Object { "$(Get-ConfigValue $State $_)" -ne $Remote[$_] })
  if ($Changed -or -not (Test-Path $Setup)) {
    $New = "$Setup.new"
    Invoke-WebRequest -Uri $OfficeSetupUrl -OutFile $New -UseBasicParsing -TimeoutSec 600
    if (-not (Test-MicrosoftSignature $New)) { Remove-Item $New -Force; throw "the downloaded setup.exe is not validly signed by Microsoft." }
    Move-Item $New $Setup -Force
    [PSCustomObject] $Remote | ConvertTo-Json | Set-Content -Encoding utf8 -Path $StateFile
    Write-Host "runner: Office Deployment Tool $((Get-Item $Setup).VersionInfo.FileVersion) downloaded."
  }
  $Setup
}

# Refresh the cached Microsoft 365 Apps build if the channel has a newer one (or the
# configuration asks for a different channel, edition or languages), then return the
# cached kit (or $null). Best effort: a failed refresh keeps the cached kit.
function Update-OfficeKit([string] $Cache, [string] $ConfigurationFile) {
  $Current = Join-Path $Cache 'current'
  New-Item -ItemType Directory -Force -Path $Cache | Out-Null

  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Identity = Get-OfficeDownloadIdentity $ConfigurationFile
    $Setup = Update-OfficeSetup $Cache
    $Latest = Get-OfficeLatestVersion $Identity.Channel

    $Kit = try { Get-OfficeKit $Current } catch { $null }
    $Same = $Kit -and $Kit.Version -eq $Latest -and $Kit.Channel -eq $Identity.Channel -and $Kit.Edition -eq $Identity.Edition -and
      (@($Kit.Languages) -join ',') -eq ($Identity.Languages -join ',')

    if ($Same) {
      # a newer ODT doesn't need a new download
      if ((Get-FileHash $Setup).Hash -ne (Get-FileHash (Join-Path $Current 'setup.exe')).Hash) { Copy-Item $Setup (Join-Path $Current 'setup.exe') -Force }
      Write-Host "runner: Microsoft 365 Apps $Latest ($($Identity.Channel)) is current."
    }
    else {
      Write-Host "runner: downloading Microsoft 365 Apps $Latest ($($Identity.Channel), $($Identity.Edition)-bit, $($Identity.Languages -join ', ')); cached: $(if ($Kit) { $Kit.Version } else { 'none' })."
      $New = Join-Path $Cache 'new'
      if (Test-Path $New) { Remove-Item $New -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $New | Out-Null
      Copy-Item $Setup $New

      # the same configuration, pinned to this build and pointed at new\
      [xml] $Xml = Get-Content -Raw $ConfigurationFile
      $Xml.Configuration.Add.SetAttribute('SourcePath', $New)
      $Xml.Configuration.Add.SetAttribute('Version', $Latest)
      $Xml.Configuration.Add.SetAttribute('Channel', $Identity.Channel)
      $DownloadXml = Join-Path $Cache 'download.xml'
      $Xml.Save($DownloadXml)

      $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
      $Process = Start-Process -FilePath (Join-Path $New 'setup.exe') -ArgumentList '/download', "`"$DownloadXml`"" -WorkingDirectory $Cache -PassThru -WindowStyle Hidden
      $null = $Process.Handle
      if (-not $Process.WaitForExit(3 * 3600 * 1000)) { $Process.Kill(); throw 'setup.exe /download did not finish in 3 hours.' }
      if ($Process.ExitCode -ne 0) { throw "setup.exe /download exited with $($Process.ExitCode)." }

      [PSCustomObject]@{
        version    = $Latest
        channel    = $Identity.Channel
        edition    = $Identity.Edition
        languages  = $Identity.Languages
        downloaded = (Get-Date -Format o)
      } | ConvertTo-Json | Set-Content -Encoding utf8 -Path (Join-Path $New 'kit.json')
      # verify before it replaces a good cached kit
      $Kit = Get-OfficeKit $New

      $Old = "$Current.old"
      if (Test-Path $Old) { Remove-Item $Old -Recurse -Force }
      if (Test-Path $Current) { Rename-Item $Current (Split-Path -Leaf $Old) }
      Rename-Item $New (Split-Path -Leaf $Current)
      if (Test-Path $Old) { Remove-Item $Old -Recurse -Force }
      Write-Host "runner: Microsoft 365 Apps $Latest downloaded ($($Kit.SizeGB) GB in $([math]::Round($Stopwatch.Elapsed.TotalMinutes, 1)) minutes)."
    }
  }
  catch {
    Write-Warning "runner: couldn't refresh Microsoft 365 Apps: $_ Using the cached build, if any."
  }

  try {
    $Kit = Get-OfficeKit $Current
    Write-Host "runner: post-install media gets Microsoft 365 Apps $($Kit.Version) ($($Kit.Channel), $($Kit.SizeGB) GB)."
    $Kit
  }
  catch {
    Write-Warning "runner: no usable Microsoft 365 Apps build in $Cache ($_); machines will download Office at first logon."
  }
}
