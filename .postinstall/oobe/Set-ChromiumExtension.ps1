function Assert-PolicyKeyExists {
  param (
    [Parameter(Mandatory)]
    [string]$PolicyPath
  )

  if (-not (Test-Path $PolicyPath)) {

    Write-Host "Registry path $($PolicyPath) not found. Creating it..."
    
    $Item = New-Item -Path $PolicyPath -Force

    Write-Verbose ($Item | Format-Table | Out-String)
    
  }

  return [string]$PolicyPath

}

# helper function to add extension ID to Chromium ExtensionInstallForcelist
Function Add-ExtensionToForcelist {
  param (
    [string]$ExtensionID,
    [string]$UpdateUrl,
    [string]$RegistryKey
  )

  if (-not (Test-Path $RegistryKey)) {

    Write-Host `
      "Registry key at $($RegistryKey) does not exist. Creating it."
    
    $Item = New-Item $RegistryKey -Force

    Write-Verbose ($Item | Format-Table | Out-String)

  }

  # see if desired ExtensionID UpdateUrl combo already exists
  # if the extension already exists in the Forcelist, make no changes here.
  foreach ($Value in (Get-ItemProperty $RegistryKey)) {
    
    $AlreadyExists = (Get-ItemProperty $RegistryKey).PSObject.Properties |
      Where-Object Value -like "*$($ExtensionID)*"
    
    if ($AlreadyExists) {
      Write-Host `
        "Extension ID $($ExtensionID) already exists in the force installation list. No changes were made."
      
      return
    }
  }

  # Forcelist property names are int in range 1 thru n. Find the first unused name.
  Function Get-FirstFreeName {
    $i = 0; do { $i++ } while ( $i -in (Get-Item $RegistryKey).Property ); return $i
  }

  $ForcelistEntry = @{
    Name = Get-FirstFreeName
    Value = "$($ExtensionID);$($UpdateUrl)"
    Type = 'string'
  }

  # create the desired Forcelist entry.
  $Item = New-ItemProperty `
    -Path $RegistryKey `
    @ForcelistEntry

  Write-Verbose ($Item | Format-Table | Out-String)

}

Function Add-ChromiumExtension {
  param (
    [string]$ExtensionID,
    [array]$AdditionalKeys,
    [string]$ExtensionsRegistryPath = 'HKLM:\Software\Wow6432Node\Microsoft\Edge\Extensions',
    [string]$ForceInstallListRegistryPath = 'HKLM:\Software\Policies\Microsoft\Edge\ExtensionInstallForcelist',
    [string]$UpdateUrl = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx',
    [boolean]$AddToForceList = $true
  )

  $BrowserPath = (Split-Path $ExtensionsRegistryPath -Parent)

  # if the browser root key does not exist, quit.
  if (-not (Test-Path $BrowserPath)) {

    Write-Host `
      "Registry key at $($BrowserPath) not found. Is this browser installed? Terminating early; no changes were made."

    return

  }

  # if the browser path exists but the extensions path does not, create the Extensions key.
  if (-not (Test-Path $ExtensionsRegistryPath)) {

    Write-Host `
      "Extension parent key at path $($ExtensionsRegistryPath) does not exist. Creating it."
    
    $Item = New-Item $ExtensionsRegistryPath -Force

    Write-Verbose ($Item | Format-Table | Out-String)

  }

  # build path for the extension's registry key
  $KeyPath = (
    Join-Path `
      -Path $ExtensionsRegistryPath `
      -ChildPath $ExtensionID
  )

  # ...and create it, if needed
  if (-not (Test-Path $KeyPath)) {

    Write-Host `
      "Extension $($ExtensionID)'s registry key at $($KeyPath) does not exist. Creating it."

    $Item = New-Item $KeyPath -Force

    Write-Verbose ($Item | Format-Table | Out-String)

  } else {
    Write-Host `
      "Extension $($ExtensionID)'s registry key at $($KeyPath) already exists. No changes were made."
  }

  # if the existing update URL for the extension's registry key does not match
  # what was requested, replace it with what we want
  $ExistingUpdateUrl = (Get-ItemProperty -Path $KeyPath).update_url
  
  if (-not ($ExistingUpdateUrl -eq $UpdateUrl)) {

    Write-Host `
      "Extension $($ExtensionID)'s update_url '$($ExistingUpdateUrl)' does not match requested $($UpdateUrl). Modifying it."

    $Item = New-ItemProperty `
      -Path $KeyPath `
      -Name 'update_url' `
      -Value $UpdateUrl `
      -Force
    
    Write-Verbose ($Item | Format-Table | Out-String)

  } else {
    Write-Host `
      "Extension $($ExtensionID)'s update_url '$($ExistingUpdateUrl)' matches requested $($UpdateUrl). No changes were made."
  }

  if ($AddToForceList) {

    Write-Host `
      "Attempting to add $($ExtensionID) to force install list at $($ForceInstallListRegistryPath)."

    Add-ExtensionToForcelist `
      -ExtensionID $ExtensionID `
      -UpdateUrl $UpdateUrl `
      -RegistryKey $ForceInstallListRegistryPath
    
  }

}

# ubolite
# https://microsoftedge.microsoft.com/addons/detail/ublock-origin-lite/cimighlppcgcoapaliogpjjdehbnofhn
Function Add-EdgeExtension {
  param (
    [string]$ExtensionID,
    [array]$AdditionalKeys,
    [string]$UpdateUrl = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'
  )

  Add-ChromiumExtension `
    -ExtensionID $ExtensionID `
    -ExtensionsRegistryPath 'HKLM:\Software\Wow6432Node\Microsoft\Edge\Extensions' `
    -AddToForceList $true `
    -ForceInstallListRegistryPath 'HKLM:\Software\Policies\Microsoft\Edge\ExtensionInstallForcelist' `
    -UpdateUrl $UpdateUrl

}

# ubolite
# https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=en
# sso
# https://chromewebstore.google.com/detail/microsoft-single-sign-on/ppnbnpeolgkicgegkbkbjmhlideopiji?hl=en
Function Add-ChromeExtension {
  param (
    [string]$ExtensionID,
    [array]$AdditionalKeys,
    [string]$UpdateUrl = 'https://clients2.google.com/service/update2/crx'
  )

  Add-ChromiumExtension `
    -ExtensionID $ExtensionID `
    -ExtensionsRegistryPath 'HKLM:\Software\Google\Chrome\Extensions' `
    -AddToForceList $true `
    -ForceInstallListRegistryPath 'HKLM:\Software\Policies\Google\Chrome\ExtensionInstallForcelist' `
    -UpdateUrl $UpdateUrl

}

# install uBlock Origin Lite for Chrome
Write-Host `
  "`nInstalling uBlock Origin Lite for Google Chrome..." `
  -ForegroundColor Blue

Add-ChromeExtension `
  -ExtensionID 'ddkjiahejlhfcafbddmgiahcphecmpfh'

# install Microsoft SSO extension for Chrome
Write-Host `
  "`nInstalling Microsoft SSO extension for Google Chrome..." `
  -ForegroundColor Blue

Add-ChromeExtension `
  -ExtensionID 'ppnbnpeolgkicgegkbkbjmhlideopiji'

# install 1PW for Chrome
# Write-Host `
#   "`nInstalling 1Password for Google Chrome..." `
#   -ForegroundColor Blue

# Add-ChromeExtension `
#   -ExtensionID 'aeblfdkhhhdcdjpifhhbdiojplfjncoa'

# install uBlock Origin Lite for Edge
Write-Host `
  "`nInstalling uBlock Origin Lite for Microsoft Edge..." `
  -ForegroundColor Blue

Add-EdgeExtension `
  -ExtensionID 'cimighlppcgcoapaliogpjjdehbnofhn'

# install 1Password for Edge
# Write-Host `
#   "`nInstalling 1Password for Microsoft Edge..." `
#   -ForegroundColor Blue

# Add-EdgeExtension `
#   -ExtensionID 'dppgmdbiimibapkepcbdbmkaabgiofem'
