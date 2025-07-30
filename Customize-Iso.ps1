param (
  [Parameter(Mandatory = $true)]
  [string] $IsoPath,
  [Parameter(Mandatory = $true)] 
  [string] $WorkingDir,
  [string] $ConfigFile = (Join-Path (Split-Path $PSCommandPath) config.json),
  [string] $Autounattend = (Join-Path (Split-Path $PSCommandPath) autounattend.xml),
  [string] $WinREWimPath = 'D:\Winre.wim',
  [string] $OutPath = (Join-Path $WorkingDir 'Customized.iso')
)

Start-Transcript -Path "Get-Iso-$($Version)-$(Get-Date -UFormat %s).log"

Write-Host "Customize-Iso: Beginning execution: version $(git rev-parse --short HEAD) at $(Get-Date -UFormat %s)."

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "Output: $OutPath"

$Config = (Get-Content $ConfigFile | ConvertFrom-Json)

# working directories
$ScratchPath = (Join-Path $WorkingDir 'Scratch')
$MountDir = (Join-Path $WorkingDir 'Mount')

# Mount an ISO, copy its contents to a scratch directory, and remove read-only attributes.
function Get-IsoImage {
  param (
    [string] $Path,
    [string] $Destination
  )

  # mount the ISO
  $Mount = Mount-DiskImage -ImagePath $IsoPath

  # get the drive letter of the mounted ISO
  $Drive = ($Mount | Get-Volume).DriveLetter

  # copy the contents of the ISO to the scratch directory
  New-Item -Path $ScratchPath -ItemType Directory -Force | Out-Null
  
  Start-Process `
    -File robocopy.exe `
    -ArgumentList @(
      "$($Drive):\",
      $ScratchPath,
      '/E',
      '/COPYALL',
      '/R:0',
      '/W:0'
    ) `
    -Wait `
    -NoNewWindow |
    Out-Null

  # unmount the ISO
  Dismount-DiskImage -ImagePath $IsoPath

  # remove the read-only attribute from all files in the scratch directory
  Get-ChildItem $ScratchPath -Recurse | ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) }

}

# Mount and modify the image
function Set-Image {
  param (
    [string] $ImagePath,
    [string] $MountPath,
    [string] $WinREWimPath,
    [pscustomobject] $Config
  )

  function Set-ImageRegistry {
    param (
      [string] $ImagePath,
      [pscustomobject] $Config
    )

    # it's possible to do this with PowerShell, but it's easier
    # to use reg.exe so you don't have to hunt down handles

    # load HKLM and default hives from the offline image
    reg load HKLM\OfflineDefault "$($ImagePath)\Windows\System32\Config\DEFAULT"
    reg load HKLM\OfflineSoftware "$($ImagePath)\Windows\System32\Config\SOFTWARE"
    reg load HKLM\OfflineSystem "$($ImagePath)\Windows\System32\Config\SYSTEM"

    # disable consumer features
    reg add 'HKLM\OfflineSoftware\Policies\Microsoft\Windows\CloudContent' /v 'DisableWindowsConsumerFeatures' /t REG_DWORD /d 1 /f

    # disable cloud content
    reg add 'HKLM\OfflineSoftware\Policies\Microsoft\Windows\CloudContent' /v 'DisableCloudOptimizedContent' /t REG_DWORD /d 1 /f

    # DisableConsumerAccountStateContent
    reg add 'HKLM\OfflineSoftware\Policies\Microsoft\Windows\CloudContent' /v 'DisableConsumerAccountStateContent' /t REG_DWORD /d 1 /f

    # disable Content Delivery Manager
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'ContentDeliveryAllowed' /t REG_DWORD /d 0 /f

    # disable all preinstalled apps and features
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'OemPreInstalledAppsEnabled' /t REG_DWORD /d 0 /f

    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'PreInstalledAppsEnabled' /t REG_DWORD /d 0 /f

    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'PreInstalledAppsEverEnabled' /t REG_DWORD /d 0 /f

    # disable 'silentinstalledapps' like Candy Crush
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SilentInstalledAppsEnabled' /t REG_DWORD /d 0 /f

    # Another one that may or may not kill Candy Crush
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-314559Enabled' /t REG_DWORD /d 0 /f

    # disable 'softlanding' like the Start menu suggestions
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SoftLandingEnabled' /t REG_DWORD /d 0 /f

    # disable 'subscribedcontent' like the Start menu ads
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContentEnabled' /t REG_DWORD /d 0 /f

    # 'feature management' - dynamically inserted tiles and ads
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'FeatureManagementEnabled' /t REG_DWORD /d 0 /f

    # 'windows welcome experience' - may not affect W11
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-310093Enabled' /t REG_DWORD /d 0 /f

    # 'timeline suggestions'
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-353698Enabled' /t REG_DWORD /d 0 /f
    
    # 'app suggestions'
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-338388Enabled' /t REG_DWORD /d 0 /f

    # 'tips and tricks'
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-338389Enabled' /t REG_DWORD /d 0 /f

    # 'suggested content in Settings'
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-338393Enabled' /t REG_DWORD /d 0 /f
    
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-353694Enabled' /t REG_DWORD /d 0 /f
    
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-353696Enabled' /t REG_DWORD /d 0 /f

    # disable 'SystemPaneSuggestionsEnabled'
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SystemPaneSuggestionsEnabled' /t REG_DWORD /d 0 /f

    # RotatingLockScreenOverlayEnabled
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'RotatingLockScreenOverlayEnabled' /t REG_DWORD /d 0 /f

    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'RotatingLockScreenEnabled' /t REG_DWORD /d 0 /f

    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v 'Start_IrisRecommendations' /t REG_DWORD /d 0 /f

    # disable 'PushToInstall' - this is the 'Get more apps' button in the Start menu
    reg add 'HKLM\OfflineDefault\Software\Policies\Microsoft\PushToInstall' /v 'DisablePushToInstall' /t REG_DWORD /d 1 /f

    # hide the ad section in Start
    reg add 'HKLM\OfflineSoftware\Policies\Microsoft\Windows\Explorer' /v 'HideRecommendedSection' /t REG_DWORD /d 1 /f

    # hide the Bing junk in Windows Search
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\Search' /v BingSearchEnabled /t REG_DWORD /d 0 /f

    # disable search highlights feature (the above also does this, but for good measure)
    reg add 'HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\SearchSettings' /v 'IsDynamicSearchBoxEnabled' /t REG_DWORD /d 0 /f

    # WSB, also for good measure
    reg add 'HKLM\OfflineSoftware\Policies\Microsoft\Windows\Windows Search' /v 'EnableDynamicContentInWSB' /t REG_DWORD /d 0 /f

    # disable mouse acceleration
    reg add 'HKLM\OfflineDefault\Control Panel\Mouse' /v 'MouseSpeed' /t REG_SZ /d 0 /f
    reg add 'HKLM\OfflineDefault\Control Panel\Mouse' /v 'MouseThreshold1' /t REG_SZ /d 0 /f
    reg add 'HKLM\OfflineDefault\Control Panel\Mouse' /v 'MouseThreshold2' /t REG_SZ /d 0 /f
    
    # remove CDM subscriptions and suggested apps
    reg delete "HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions" /f
    reg delete "HKLM\OfflineDefault\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps" /f
    
    reg unload HKLM\OfflineDefault
    reg unload HKLM\OfflineSoftware
    reg unload HKLM\OfflineSystem

  }

  function Remove-ImagePackages {
    param (
      [string] $ImagePath,
      [pscustomobject] $Config
    )

    Write-Host "Removing AppX packages from $ImagePath."

    Write-Host "AppX packages to remove: $($Config.AppXPackagesToRemove -join ", ")."

    foreach ($Package in $Config.AppXPackagesToRemove) {

      Get-AppXProvisionedPackage -Path $ImagePath |
      Where-Object PackageName -like $Package |
      ForEach-Object {
        Write-Host "Removing AppX package $($_.PackageName)"
        Remove-AppxProvisionedPackage -Path $ImagePath -PackageName $_.PackageName
      }

    }

    Write-Host "Removing Windows packages from $ImagePath."

    foreach ($Package in $Config.WindowsPackagesToRemove) {

      Get-WindowsPackage -Path $ImagePath |
      Where-Object PackageName -like $Package |
      ForEach-Object {
        Write-Host "Removing Windows package $($_.PackageName)"
        Remove-WindowsPackage -Path $ImagePath -PackageName $_.PackageName
      }

    }

    Write-Host "Removing Windows capabilities from $ImagePath."

    foreach ($Capability in $Config.WindowsFeaturesToRemove) {

      Get-WindowsCapability -Path $ImagePath |
      Where-Object Name -like $Capability |
      ForEach-Object {
        Write-Host "Removing Windows capability $($_.Name)"
        Remove-WindowsCapability -Path $ImagePath -Name $_.Name
      }

    }

  }

  $Config | ConvertTo-Json -Depth 10 | Write-Host
  $Config.install | ConvertTo-Json -Depth 10 | Write-Host

  Write-Host "Set-Image: Searching for WIM files in $ImagePath."

  # find all WIM files in the ISO
  $Wims = Get-ChildItem $ImagePath -Recurse | Where-Object Name -like *.wim*

  Write-Host "Set-Image: Found $($Wims.Count) WIM files ($($Wims.Name -join ", "))."

  # find boot and install WIMages
  $BootWim = $Wims | Where-Object Name -eq 'boot.wim'
  $InstallWim = $Wims | Where-Object Name -eq 'install.wim'

  Write-Host "Set-Image: Mounting $($InstallWim.Name) to $MountPath with DISM."

  # mount the image
  Mount-WindowsImage -ImagePath $InstallWim.FullName -Path $MountPath -Optimize

  Write-Host "Set-Image: Mounted $($InstallWim.Name) to $MountPath."
  Write-Host "Set-Image: Copying Windows Recovery Environment WIM to image at $MountPath."

  # copy the WinRE.wim to the image
  Copy-Item $WinREWimPath "$($MountPath)\Windows\System32\Recovery\Winre.wim"

  Write-Host "Set-Image: Removing unwanted packages and features from $($InstallWim.Name)."

  # remove unwanted packages and features
  Remove-ImagePackages -ImagePath $MountPath -Config $Config.install.Packages

  Write-Host "Set-Image: Modifying the offline registry in $($InstallWim.Name)."

  # edit the registry to set desired policy
  Set-ImageRegistry -ImagePath $MountPath -Config $Config.install.Registry

  Write-Host "Set-Image: Saving changes to $($InstallWim.Name)."

  # save changes to the image
  Dismount-WindowsImage -Path $MountPath -Save

  Write-Host "Set-Image: Done with $($InstallWim.Name)."
  Write-Host "Set-Image: Mounting $($BootWim.Name) to $MountPath with DISM."

  # mount the boot.wim
  $SetupIndex = (Get-WindowsImage -ImagePath $BootWim.FullName | Where-Object ImageName -eq 'Microsoft Windows Setup (x64)').ImageIndex

  Mount-WindowsImage -ImagePath $BootWim.FullName -Path $MountPath -Optimize -Index $SetupIndex

  Write-Host "Set-Image: Modifying the offline registry in $($BootWim.Name) to bypass hardware restrictions."

  reg load HKLM\OfflineSystem "$($MountPath)\Windows\System32\Config\SYSTEM"

  reg add 'HKLM\OfflineSystem\Setup\LabConfig' /v 'BypassTPMCheck' /t REG_DWORD /d 1 /f
  reg add 'HKLM\OfflineSystem\Setup\LabConfig' /v 'BypassSecureBootCheck' /t REG_DWORD /d 1 /f
  reg add 'HKLM\OfflineSystem\Setup\LabConfig' /v 'BypassRAMCheck' /t REG_DWORD /d 1 /f

  reg unload HKLM\OfflineSystem
  
  Write-Host "Set-Image: Saving changes to $($BootWim.Name)."

  Dismount-WindowsImage -Path $MountPath -Save

  Write-Host "Set-Image: Done with $($BootWim.Name)."
  Write-Host "Set-Image: Done."

}

# create an ISO from the modified image (as files on disk)
function New-IsoImage {
  param (
    [Parameter(Mandatory=$true)]
    [string] $Source,
    [Parameter(Mandatory=$true)]
    [string] $Outputfile,
    [string] $EFIFile,
    [string] $BIOSFile
  )

  function Get-ShortPath {
    param ([string]$Path)
    $fso = New-Object -ComObject Scripting.FileSystemObject

    $FileCreated = $false
    if (-not (Test-Path $Path)) {
      New-Item $Path 1>$null
      $FileCreated = $true
    }

    if (Test-Path $Path -PathType Container) {
        return $fso.GetFolder($Path).ShortPath
    } else {
        return $fso.GetFile($Path).ShortPath
    }

    if ($FileCreated) {
      Remove-Item $Path 1>$null
    }

  }

  if (-not [bool]$EFIFile) { $EFIFile = Get-ShortPath (Join-Path $Source "efi\microsoft\boot\efisys_noprompt.bin") }

  if (-not [bool]$BIOSFile) { $BIOSFile = Get-ShortPath (Join-Path $Source "boot\etfsboot.com") }

  $Source = Get-ShortPath $Source
  $Outputfile = Get-ShortPath $Outputfile

  $BootData = "-bootdata:2#p0,e,b`"${BIOSFile}`"#pEF,e,b`"${EFIFile}`""

  Write-Host "New-IsoImage: oscdimg.exe BootData: $($BootData -join " ")"

  $Arguments = @(
    "-m",
    "-o",
    "-h",
    "-u2",
    "-udfver102",
    $BootData,
    $Source,
    $Outputfile
  )

  Write-Host "New-IsoImage: oscdimg.exe arguments: $($Arguments -join " ")"

  Start-Process `
    -FilePath 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe' `
    -ArgumentList $Arguments `
    -Wait `
    -NoNewWindow

}

Write-Host "Config: $($Config | ConvertTo-Json -Depth 99)"

Write-Host "Creating working directories"

New-Item $MountDir -ItemType Directory -Force | Out-Null
New-Item $ScratchPath -ItemType Directory -Force | Out-Null

Write-Host "Copying image from ISO to scratch directory"

Get-IsoImage -Path $IsoPath -Destination $ScratchPath

Write-Host "Copying unattend to scratch directory"

# prep the image by adding an autounattend.xml
Copy-Item $Autounattend $ScratchPath\autounattend.xml

Write-Host "Copying stub scripts to scratch directory"

New-Item (Join-Path $ScratchPath 'sources\$OEM$\$1') -ItemType Directory -Force

Copy-Item (Join-Path (Split-Path $PSCommandPath) \stub-scripts\*) (Join-Path $ScratchPath 'sources\$OEM$\$1\') -Recurse -Force

Write-Host "Customizing install.wim"

$Config

$Config.install

$Config.install | ConvertTo-Json -Depth 10 | Write-Host

Set-Image -ImagePath $ScratchPath -MountPath $MountDir -WinREWimPath $WinREWimPath -Config $Config

Write-Host "Done"

Write-Host "Creating output file"

# create the new ISO
New-IsoImage -Source $ScratchPath -Outputfile $OutPath

Write-Host "Done"

$Stopwatch.Stop()

Write-Host "Customize-Iso: Execution completed at: $(Get-Date -UFormat %s), elapsed: $($Stopwatch.Elapsed.TotalSeconds) seconds."

Stop-Transcript
