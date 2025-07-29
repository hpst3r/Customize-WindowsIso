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

# Recommended: HKLM:\SOFTWARE\Policies\Microsoft\Edge\Recommended
# Enforced: HKLM:\SOFTWARE\Policies\Microsoft\Edge
[string]$EdgeEnforcedPolicies = (Assert-KeyExists -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge')
[string]$EdgeRecommendedPolicies = (Assert-KeyExists -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\Recommended')

$EdgePolicies = @(

  # HideFirstRunExperience
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/hidefirstrunexperience
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'HideFirstRunExperience'
    DesiredValue = 1
    Description  = 'Disable the splash screens and preference menu at Edge startup'
  },

  # BackgroundModeEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/backgroundmodeenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'BackgroundModeEnabled'
    DesiredValue = 0
    Description  = 'Do not keep Edge running in the background when all windows are closed'
  },

  # NewTabPageHideDefaultTopSites
  # blocks the sponsored links in the quick links section of the new tab page
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/newtabpagehidedefaulttopsites
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'NewTabPageHideDefaultTopSites'
    DesiredValue = 1
    Description  = 'Disable the "Promoted Links" section on the new tab page'
  },

  # NewTabPageContentEnabled
  # blocks the MSN content on the new tab page
  # if this is enforced, weather will be blocked, too (this is the only way to block weather)
  # 'recommending' this does not work unless you are signed in with an Azure AD account
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/newtabpagecontentenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'NewTabPageContentEnabled'
    DesiredValue = 0
    Description  = 'Disable the "Web content" section (MSN) on the new tab page'
  },

  # NewTabPageBingChatEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/newtabpagebingchatenabled
  @{
    PolicyPath   = $EdgeRecommendedPolicies
    PropertyName = 'NewTabPageBingChatEnabled'
    DesiredValue = 0
    Description  = 'Remove Bing Chat entrypoints from the New Tab page'
  },

  # HubsSidebarEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/hubssidebarenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'HubsSidebarEnabled'
    DesiredValue = 0
    Description  = 'Disable all the Copilot icons and links in the browser'
  },

  # DefaultBrowserSettingEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/defaultbrowsersettingenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'DefaultBrowserSettingEnabled'
    DesiredValue = 0
    Description  = 'Disable the "Make Edge your default browser" prompt'
  },

  # DefaultNotificationsSetting
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/defaultnotificationsetting
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'DefaultNotificationsSetting'
    DesiredValue = 2
    Description  = 'Disable all notifications from Edge'
  },

  # TyposquattingCheckerEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/typosquattingcheckerenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'TyposquattingCheckerEnabled'
    DesiredValue = 1
    Description  = 'Enable the "Typosquatting Checker" feature'
  },

  # NewTabPageQuickLinksEnabled
  # blocks ALL of the "quick links" on the new tab page, including the sponsored links
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/newtabpagequicklinksenabled
  # @{
  #     PolicyPath = $EdgeEnforcedPolicies
  #     PropertyName = 'NewTabPageQuickLinksEnabled'
  #     DesiredValue = 0
  #     Description = 'Disable the "Quick Links" section on the New Tab page'
  # },

  # ScarewareBlockerProtectionEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/scarewareblockerprotectionenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'ScarewareBlockerProtectionEnabled'
    DesiredValue = 1
    Description  = 'Enable the "Scareware Blocker" feature'
  },

  # ShowDownloadsInsecureWarningsEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/showdownloadsinsecurewarningsenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'ShowDownloadsInsecureWarningsEnabled'
    DesiredValue = 1
    Description  = 'Enable the "Insecure downloads" warning'
  },

  # PaymentMethodQueryEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/paymentmethodqueryenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'PaymentMethodQueryEnabled'
    DesiredValue = 0
    Description  = 'Block sites from querying available payment methods'
  },

  # ShowMicrosoftRewards
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/showmicrosoftrewards
  # @{
  #     PolicyPath = $EdgeEnforcedPolicies
  #     PropertyName = 'ShowMicrosoftRewards'
  #     DesiredValue = 0
  #     Description = 'Disable the Microsoft Rewards program'
  # },

  # ShowRecommendationsEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/showrecommendationsenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'ShowRecommendationsEnabled'
    DesiredValue = 0
    Description  = 'Disable Edge feature recommendation popups'
  },

  # TrackingPrevention
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/trackingprevention
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'TrackingPrevention'
    DesiredValue = 2
    Description  = 'Enable "Balanced" tracking prevention'
  },

  # NewTabPageCompanyLogoEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/newtabpagecompanylogoenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'NewTabPageCompanyLogoEnabled'
    DesiredValue = 0
    Description  = 'Disable company logo on the new tab page'
  },

  # NewTabPageSearchBox
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/newtabpagesearchbox
  # this does not work with Bing
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'NewTabPageSearchBox'
    DesiredValue = 'bing'
    Description  = 'Configure the search box on the new tab page ("bing" always uses Bing, "redirect" is janky)'
  }

  # AddressBarTrendingSuggestEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/addressbartrendingsuggestenabled
  # This does not affect the New Tab page search box
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'AddressBarTrendingSuggestEnabled'
    DesiredValue = 0
    Description  = 'Disable "Trending" suggestions in the address bar'
  },

  # DefaultSearchProviderEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/defaultsearchproviderenabled
  # @{
  #     PolicyPath = $EdgeRecommendedPolicies
  #     PropertyName = 'DefaultSearchProviderEnabled'
  #     DesiredValue = 1
  #     Description = 'Enable management of the default Edge search provider'
  # },

  # DefaultSearchProviderSearchURL
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/defaultsearchprovidersearchurl
  # @{
  #     PolicyPath = $EdgeRecommendedPolicies
  #     PropertyName = 'DefaultSearchProviderSearchURL'
  #     DesiredValue = 'https://www.google.com/search?q={searchTerms}'
  #     Description = 'Set default search provider to Google'
  # },

  # EdgeShoppingAssistantEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/edgeshoppingassistantenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'EdgeShoppingAssistantEnabled'
    DesiredValue = 0
    Description  = 'Disable the "Shopping" feature in Edge'
  },

  # EdgeWalletCheckoutEnabled
  # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/edgewalletcheckoutenabled
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'EdgeWalletCheckoutEnabled'
    DesiredValue = 0
    Description  = 'Disable the "Wallet" feature in Edge'
  },
  @{
    PolicyPath   = $EdgeEnforcedPolicies
    PropertyName = 'PasswordManagerEnabled'
    DesiredValue = 0
    Description  = 'Disable the Edge password manager'
  }
)

<#
# ManagedFavorites
# https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/managedfavorites
Set-Policy `
  -PolicyPath $EdgeEnforcedPolicies `
  -PropertyName 'ManagedFavorites' `
  -DesiredValue '[
    {
      "toplevel_name": "Custom Bookmark Example"
    },
    {
      "name": "SharePoint Hub",
      "url": "https://sharepoint.com"
    },
    {
      "name": "Bing",
      "url": "https://www.bing.com"
    },
    {
      "name": "Matrix",
      "url": "www.matrix.org"
    }
    ]' `
  -Description 'Add custom bookmarks to the favorites bar'
  
# HomepageLocation
# https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/homelocation
Set-Policy `
  -PolicyPath $EdgeEnforcedPolicies `
  -PropertyName 'HomepageLocation' `
  -DesiredValue 'https://mycompany.sharepoint.com' `
  -Description 'Set the homepage to SharePoint Online'

# NewTabPageLocation
# https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/newtabpagelocation
Set-Policy `
  -PolicyPath $EdgeEnforcedPolicies `
  -PropertyName 'NewTabPageLocation' `
  -DesiredValue 'https://mycompany.sharepoint.com' `
  -Description 'Set the new tab page to SharePoint Online'
#>

foreach ($Policy in $EdgePolicies) {
  Set-Policy @Policy
}
