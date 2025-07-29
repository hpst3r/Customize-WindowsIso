function Set-GeckoExtension {
  param (
    [Parameter(Mandatory)]
    [string]$ExtensionId
    ,
    [Parameter(Mandatory)]
    [ValidateSet(
      'allowed',
      'blocked',
      'force_installed',
      'normal_installed'
    )]
    [string]$InstallationMode
    ,
    [string]$InstallUrl = $null
  )

  $PolicyPath = "HKLM:\SOFTWARE\Policies\Mozilla\Firefox"
  $ValueName = "ExtensionSettings"

  # Ensure registry path exists
  if (-not (Test-Path $PolicyPath)) {
    New-Item -Path $PolicyPath -Force | Out-Null
  }

  # Read existing JSON from registry property

  $ExistingJson = (Get-ItemProperty -Path $PolicyPath -Name $ValueName).$ValueName

  # Attempt to deserialize. Create a new object if we don't have valid JSON at ExtensionSettings.
  try {

    if ($ExistingJson) {

      $Obj = $ExistingJson | ConvertFrom-Json -ErrorAction Stop

      # convert PSObjects from JSON to hashtables
      $Settings = @{}
      foreach ($Key in $Obj.PSObject.Properties.Name) {

        $Settings[$Key] = @{}
        
        foreach ($Prop in $Obj.$Key.PSObject.Properties.Name) {
          $Settings[$Key][$Prop] = $Obj.$Key.$Prop
        } # foreach

      } # foreach

    } # if
    else { $Settings = @{} } # if no existing JSON, use an empty hashtable

  } # try
  catch {

    Write-Warning "Existing ExtensionSettings do not contain valid JSON. Starting over."
    $Settings = @{}

  }

  # For simplicity, recreate the extension object with desired parameters

  $Settings[$ExtensionId] = @{
    installation_mode = $InstallationMode
  }
  if ($InstallationMode -eq "force_installed" -and $InstallUrl) {

    $Settings[$ExtensionId].install_url = $InstallUrl

  } else {

    Write-Warning "Extension $($ExtensionId) is being force_installed, but no install URL was specified. Installation will fail!"

  }

  $Json = $Settings | ConvertTo-Json -Depth 99 -Compress

  Set-ItemProperty -Path $PolicyPath -Name $ValueName -Value $Json

  Write-Host "Extension settings updated for '$($ExtensionId)'."

}

Set-GeckoExtension `
  -ExtensionId 'uBlock0@raymondhill.net' `
  -InstallationMode 'force_installed' `
  -InstallUrl 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi'

# Set-GeckoExtension `
#   -ExtensionId '{d634138d-c276-4fc8-924b-40a0ea21d284}' `
#   -InstallationMode 'force_installed' `
#   -InstallUrl 'https://addons.mozilla.org/firefox/downloads/latest/1password-x-password-manager/latest.xpi'
