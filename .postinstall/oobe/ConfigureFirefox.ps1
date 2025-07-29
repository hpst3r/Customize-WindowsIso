function Assert-KeyExists {
  param (
    [Parameter(Mandatory)]
    [string]$Path
  )
  
  if (-not (Test-Path $Path)) {

    Write-Host "Registry path $($Path) not found. Creating it..."
    
    $Item = New-Item -Path $Path -Force

    Write-Verbose ($Item | Format-Table | Out-String)
    
  }

  return [string]$Path

}

function Set-Policy {
  param (
    [Parameter(Mandatory)]
    [string]$PolicyPath
    ,
    [Parameter(Mandatory)]
    [string]$PropertyName
    ,
    [Parameter(Mandatory)]
    $DesiredValue
    ,
    [Parameter(Mandatory)]
    [string]$Description
  )

  $PropertyParts = $PropertyName -split '\\', 2

  if ($PropertyParts.Count -gt 1) {

    # if we received a two-part path, e.g., FirefoxHome\SponsoredPocket, split to key and property
    $SubKey = Join-Path -Path $PolicyPath -ChildPath $PropertyParts[0]

    [string]$PolicyPath = Assert-KeyExists -Path $SubKey

    $PropertyName = $PropertyParts[1]

  }

  # get properties of the policy key
  $PolicyProperties = (Get-ItemProperty $PolicyPath)

  # if the property's value is not already set to the desired value, set it.
  $CurrentValue = $PolicyProperties.$PropertyName

  if ($CurrentValue -eq $DesiredValue) {

    Write-Host "Policy '$($PropertyName)' is already set to '$($DesiredValue)'. No changes will be made."

  } else {

    Write-Host "Setting policy '$($PropertyName)' to '$($DesiredValue)' ($($Description))"

    Set-ItemProperty `
      -Path $PolicyPath `
      -Name $PropertyName `
      -Value $DesiredValue

  }

}

# Enforced: HKLM:\SOFTWARE\Policies\Mozilla\Firefox
[string]$PoliciesPath = (Assert-KeyExists -Path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox')

$TrustRootCerts = @(
  # https://mozilla.github.io/policy-templates/#certificates--importenterpriseroots
  @{
    PropertyName = 'Certificates\ImportEnterpriseRoots'
    DesiredValue = 1
    Description  = 'Trust system root certificate authorities.'
  }
)

$EnableEntraSSO = @(
  # https://mozilla.github.io/policy-templates/#windowssso
  @{
    PropertyName = 'WindowsSSO'
    DesiredValue = 1
    Description  = 'Enable Microsoft single sign-on (SSO).'
  }
)

$DisableMiscFeatures = @(
  
  # https://mozilla.github.io/policy-templates/#disableformhistory
  @{
    PropertyName = 'DisableFormHistory'
    DesiredValue = 1
    Description  = 'Prevent information from being saved from web forms or the search bar.'
  }

  # https://mozilla.github.io/policy-templates/#disablefirefoxstudies
  @{
    PropertyName = 'DisableFirefoxStudies'
    DesiredValue = 1
    Description  = 'Disable evaluation features.'
  }

  # https://mozilla.github.io/policy-templates/#disablefirefoxaccounts
  # @{
  #   PropertyName = 'DisableFirefoxAccounts'
  #   DesiredValue = 1
  #   Description  = 'Disable Firefox Sync account integration.'
  # }

  # https://mozilla.github.io/policy-templates/#autofillcreditcardenabled
  @{
    PropertyName = 'AutofillCreditCardEnabled'
    DesiredValue = 0
    Description  = 'Do not offer to autofill credit card information.'
  }

)

$DisablePasswordManager = @(

  # https://mozilla.github.io/policy-templates/#passwordmanagerenabled
  @{
    PropertyName = 'PasswordManagerEnabled'
    DesiredValue = 0
    Description  = 'Mostly disable the Firefox password manager.'
  }

  # https://mozilla.github.io/policy-templates/#offertosaveloginsdefault
  @{
    PropertyName = 'OfferToSaveLoginsDefault'
    DesiredValue = 0
    Description  = 'Do not offer to save login information.'
  }

)

$HideNagsAndSplashScreens = @(

  # https://mozilla.github.io/policy-templates/#overridefirstrunpage
  @{
    PropertyName = 'OverrideFirstRunPage'
    DesiredValue = ''
    Description  = 'Do not show the first run page.'
  }

  # https://mozilla.github.io/policy-templates/#overridepostupdatepage
  @{
    PropertyName = 'OverridePostUpdatePage'
    DesiredValue = ''
    Description  = 'Do not show post-update pages.'
  }

  # https://mozilla.github.io/policy-templates/#nodefaultbookmarks
  @{
    PropertyName = 'NoDefaultBookmarks'
    DesiredValue = 1
    Description  = 'Do not create default bookmarks.'
  }

  # https://mozilla.github.io/policy-templates/#dontcheckdefaultbrowser
  @{
    PropertyName = 'DontCheckDefaultBrowser'
    DesiredValue = 1
    Description  = 'Do not check to see if Firefox is the default browser.'
  }

  # https://mozilla.github.io/policy-templates/#usermessaging
  @{
    PropertyName = 'UserMessaging\ExtensionRecommendations'
    DesiredValue = 0
    Description  = 'Do not recommend extensions to the user.'
  }
  @{
    PropertyName = 'UserMessaging\FeatureRecommendations'
    DesiredValue = 0
    Description  = 'Do not recommend browser features to the user.'
  }
  @{
    PropertyName = 'UserMessaging\UrlbarInterventions'
    DesiredValue = 0
    Description  = 'Do not offer Firefox-specific suggestions in the URL bar.'
  }
  @{
    PropertyName = 'UserMessaging\SkipOnboarding'
    DesiredValue = 0
    Description  = 'Do not show the onboarding experience.'
  }
  @{
    PropertyName = 'UserMessaging\MoreFromMozilla'
    DesiredValue = 0
    Description  = 'Do not suggest other Mozilla products.'
  }
  @{
    PropertyName = 'UserMessaging\FirefoxLabs'
    DesiredValue = 0
    Description  = 'Do not recommend experimental features.'
  }
  @{
    PropertyName = 'UserMessaging\Locked'
    DesiredValue = 0
    Description  = 'Do not lock these settings (allow the user to change them if they would like).'
  }

)

$DisableAds = @(
  
  # https://mozilla.github.io/policy-templates/#firefoxsuggest
  @{
    PropertyName = 'FirefoxSuggest\WebSuggestions'
    DesiredValue = 0
    Description  = 'Disable website suggestions.'
  }
  @{
    PropertyName = 'FirefoxSuggest\SponsoredSuggestions'
    DesiredValue = 0
    Description  = 'Disable sponsored website suggestions.'
  }
  @{
    PropertyName = 'FirefoxSuggest\ImproveSuggest'
    DesiredValue = 0
    Description  = 'Disable suggestion telemetry.'
  }
  @{
    PropertyName = 'FirefoxSuggest\Locked'
    DesiredValue = 0
    Description  = 'Do not lock these options; allow the user to reenable them.'
  }

  # https://mozilla.github.io/policy-templates/#firefoxhome
  @{
    PropertyName = 'FirefoxHome\SponsoredTopSites'
    DesiredValue = 0
    Description  = 'Do not show sponsored site recommendations on the homepage.'
  }
  @{
    PropertyName = 'FirefoxHome\Highlights'
    DesiredValue = 0
    Description  = 'Do not show browsing highlights on the homepage.'
  }
  @{
    PropertyName = 'FirefoxHome\Pocket'
    DesiredValue = 0
    Description  = 'Do not show Pocket on the homepage.'
  }
  @{
    PropertyName = 'FirefoxHome\SponsoredPocket'
    DesiredValue = 0
    Description  = 'Do not show sponsored Pocket posts on the homepage.'
  }
  @{
    PropertyName = 'FirefoxHome\Snippets'
    DesiredValue = 0
    Description  = 'No idea, but get it off my homepage.'
  }
  @{
    PropertyName = 'FirefoxHome\Locked'
    DesiredValue = 0
    Description  = 'Allow the user to change these options.'
  }

)

$SecurityPolicies = @(

  # https://mozilla.github.io/policy-templates/#httpsonlymode
  @{
    PropertyName = 'HttpsOnlyMode'
    DesiredValue = 'enabled'
    Description  = 'Enable HTTPS-Only mode.'
  }

  # https://mozilla.github.io/policy-templates/#disabletelemetry
  @{
    PropertyName = 'DisableTelemetry'
    DesiredValue = 1
    Description  = 'Disable Mozilla telemetry.'
  }

  # https://mozilla.github.io/policy-templates/#disabledefaultbrowseragent
  @{
    PropertyName = 'DisableDefaultBrowserAgent'
    DesiredValue = 1
    Description  = 'Disable Mozilla telemetry (scheduled task call-home).'
  }
  
  # https://mozilla.github.io/policy-templates/#installaddonspermission
  # @{
  #   PropertyName = 'InstallAddonsPermission\Default'
  #   DesiredValue = 0
  #   Description  = 'Block user installation of browser extensions.'
  # }

  # https://mozilla.github.io/policy-templates/#cookies
  @{
    PropertyName = 'Cookies\Behavior'
    DesiredValue = 'reject-foreign'
    Description  = 'Block third-party cookies.'
  }

  # https://mozilla.github.io/policy-templates/#enabletrackingprotection
  @{
    PropertyName = 'EnableTrackingProtection\Value'
    DesiredValue = 1
    Description  = 'Enable Tracking Protection.'
  }
  @{
    PropertyName = 'EnableTrackingProtection\Cryptomining'
    DesiredValue = 1
    Description  = 'Block cryptomining scripts on websites.'
  }
  @{
    PropertyName = 'EnableTrackingProtection\Fingerprinting'
    DesiredValue = 1
    Description  = 'Block fingerprinting scripts.'
  }
  @{
    PropertyName = 'EnableTrackingProtection\EmailTracking'
    DesiredValue = 1
    Description  = 'Block email tracking pixels and scripts.'
  }
  @{
    PropertyName = 'EnableTrackingProtection\Locked'
    DesiredValue = 1
    Description  = 'Do not allow the user to modify TrackingProtection settings.'
  }

  # https://mozilla.github.io/policy-templates/#dnsoverhttps
  @{
    PropertyName = 'DNSOverHTTPS\Enabled'
    DesiredValue = 1
    Description  = 'Enable DNS over HTTPS.'
  }
  @{
    PropertyName = 'DNSOverHTTPS\Fallback'
    DesiredValue = 1
    Description  = 'If DNS over HTTPS fails, fall back to the default DNS resolver.'
  }

  # https://mozilla.github.io/policy-templates/#disablesecuritybypass
  @{
    PropertyName = 'DisableSecurityBypass\InvalidCertificate'
    DesiredValue = 0
    Description  = 'Allow users to bypass invalid certificate warnings.'
  }
  @{
    PropertyName = 'DisableSecurityBypass\SafeBrowsing'
    DesiredValue = 1
    Description  = 'Do not allow users to bypass Safe Browsing warnings.'
  }

)

$FirefoxPolicies = $($TrustRootCerts; $EnableEntraSSO; $DisableMiscFeatures; $DisablePasswordManager; $HideNagsAndSplashScreens; $DisableAds; $SecurityPolicies)

foreach ($Policy in $FirefoxPolicies) {
  Set-Policy @Policy -PolicyPath $PoliciesPath
}

Write-Host 'Done.'
