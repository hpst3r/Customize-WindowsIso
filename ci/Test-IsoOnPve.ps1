#Requires -Version 5.1

<#
.SYNOPSIS
Installs one customized ISO (one edition) in a throwaway Proxmox VM and checks the result.

.DESCRIPTION
1. Uploads the ISO and the CI post-install media to the node's ISO storage (skipped when
   the copy there already has the same SHA-256).
2. Creates a VM like the hardware the images are made for: q35, OVMF with Secure Boot keys,
   TPM 2.0, virtio-scsi disk, virtio-net. The ISO's own autounattend.xml drives Setup; for
   multi-edition media (which ask for the edition) a copy of it with /IMAGE/INDEX set is
   attached as a small DVD in the first IDE slot, which Setup reads before the ISO's.
3. Waits for Setup, specialize and the first-logon scripts (the CI media replaces the
   "Press Enter" pauses with completion markers), taking console screenshots as it goes.
4. Runs ci\Test-InstalledWindows.ps1 in the guest against what the ISO's manifest and
   profile say, collects the first-logon transcript, and writes the results.
5. Destroys the VM (kept, stopped, on failure with KeepFailedVm).

Results go to <ResultsDirectory>\<iso>-<edition>-<timestamp>\: result.json, checks,
screenshots, transcript. Exit code 0 = passed, 1 = failed.
#>
param (
  [Parameter(Mandatory)] [string] $IsoPath,
  # the edition to install (image name from the manifest); required for multi-edition ISOs
  [string] $Edition,
  # the CI post-install ISO (New-CiMedia in Invoke-ImageTests.ps1)
  [Parameter(Mandatory)] [string] $CiMediaPath,
  # default: ci-config.json next to this script
  [string] $ConfigFile,
  # config.json used to build the ISO (for the profile's expectations)
  [string] $CustomizeConfigFile,
  [string] $ResultsDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ($PSScriptRoot is empty in an advanced script's parameter defaults)
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'ci-config.json' }
$Ci = Get-Content -Raw $ConfigFile | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Pve.ps1')
function Get-ConfigValue($Object, [string] $Name, $Default = $null) { Get-CiValue $Object $Name $Default }
. (Join-Path (Split-Path $PSScriptRoot) 'Profiles.ps1')
if (-not $CustomizeConfigFile) { $CustomizeConfigFile = Join-Path (Split-Path $PSScriptRoot) 'config.json' }
if (-not $ResultsDirectory) { $ResultsDirectory = $Ci.ResultsDirectory }

$VmId = [int] $Ci.VmId
$Iso = Get-Item -LiteralPath $IsoPath
$Manifest = Get-Content -Raw "$($Iso.FullName).json" | ConvertFrom-Json
$Images = @($Manifest.images)
$Image = if ($Edition) { $Images | Where-Object Name -eq $Edition | Select-Object -First 1 } elseif ($Images.Count -eq 1) { $Images[0] }
if (-not $Image) { throw "$($Iso.Name): $(if ($Edition) { "no edition '$Edition'" } else { "$($Images.Count) editions; pass -Edition" }) (editions: $(($Images | ForEach-Object Name) -join ', '))" }
$Scope = "[$($Image.Index)] $($Image.Name)"

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Short = ($Iso.BaseName -replace '[^\w.-]', '') + $(if ($Images.Count -gt 1) { '-' + ($Image.Name -replace '^Windows Server \d+ ', '' -replace '[^\w]', '') })
$OutDir = Join-Path $ResultsDirectory "$Short-$Stamp"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir 'test.log') | Out-Null

$Started = Get-Date
$Result = [ordered]@{
  iso = $Iso.Name; sha256 = $null; edition = $Image.Name; index = $Image.Index; version = $Image.Version
  started = $Started.ToString('o'); finished = $null; result = 'Fail'; error = $null
  phases = [ordered]@{}; summary = $null; checks = @(); facts = $null; notes = @(); vmKept = $false; directory = $OutDir
}
$Phase = 'prepare'
$AnswerIso = $null
$SerialLog = $null

function Write-Step([string] $Text) { Write-Host "$(Get-Date -Format 'HH:mm:ss') $($Short): $Text" }
# a console screenshot; tracks when the screen last showed something new (identical frames
# give identical PNGs, and a spinner only cycles through a few frames)
$script:SeenFrames = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ScreenChanged = Get-Date
function Save-Shot([string] $Label) {
  $Path = Join-Path $OutDir ("{0:000}m-{1}.png" -f [int]((Get-Date) - $Started).TotalMinutes, $Label)
  if (-not (Save-VmScreenshot $VmId $Path)) { return }
  if ($script:SeenFrames.Add((Get-FileHash -Algorithm SHA256 $Path).Hash)) { $script:ScreenChanged = Get-Date }
  # a frame seen before needs no second picture
  else { Remove-Item -LiteralPath $Path -Force }
}

# the ISO on the node under a stable name, re-uploaded only when its SHA-256 changed
function Publish-Iso([string] $LocalPath, [string] $RemoteName, [string] $Sha256) {
  $Remote = "$($Ci.IsoDirectory)/$RemoteName"
  $Have = (Invoke-Pve "cat $Remote.sha256 2>/dev/null; true").Trim()
  if ($Have -eq $Sha256) { Write-Step "$RemoteName is already on the node."; return }
  Write-Step "uploading $RemoteName ($([math]::Round((Get-Item -LiteralPath $LocalPath).Length / 1GB, 2)) GB)..."
  $Watch = [System.Diagnostics.Stopwatch]::StartNew()
  Invoke-Pve "rm -f $Remote $Remote.sha256 $Remote.partial" | Out-Null
  Copy-ToPve $LocalPath "$Remote.partial"
  $Uploaded = ((Invoke-Pve "sha256sum $Remote.partial" -TimeoutSeconds 900) -split '\s+')[0]
  if ($Uploaded -ne $Sha256) { throw "upload of $RemoteName is corrupt (sha256 $Uploaded, expected $Sha256)" }
  Invoke-Pve "mv $Remote.partial $Remote && echo $Sha256 > $Remote.sha256" | Out-Null
  Write-Step "uploaded $RemoteName in $([math]::Round($Watch.Elapsed.TotalMinutes, 1)) min."
}

try {
  #region expectations: the manifest and the profile the image was built with
  $Profiles = Initialize-InstallProfiles (Get-Content -Raw $CustomizeConfigFile | ConvertFrom-Json)
  $ProfileName = Get-CiValue (Get-CiValue $Manifest 'profiles') $Scope
  $ImageProfile = if ($ProfileName) { $Profiles.Profiles[$ProfileName] }
  if (-not $ImageProfile) { Write-Warning "no profile recorded for $Scope (manifest from before profiles?); profile checks are skipped." }
  $Registry = @(if ($ImageProfile) { $ImageProfile.Registry | Where-Object { Get-CiValue $_ 'Enabled' $true } })
  $OfficeWanted = [bool] @($Registry | Where-Object Name -eq 'OfficeOnFirstLogon').Count
  $CiMediaManifest = Get-Content -Raw "$CiMediaPath.json" | ConvertFrom-Json
  $OfficeOnMedia = Get-CiValue $CiMediaManifest 'office'
  [xml] $OfficeXml = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot) '.postinstall\office\configuration.xml')
  $Channel = "$($OfficeXml.Configuration.Add.Channel)"
  $ChannelIds = @{ Current = '492350f6-3a01-4f97-b9c0-c7c6ddf67d60'; MonthlyEnterprise = '55336b82-a18d-4dd6-b5f6-9e5095c314a6'; SemiAnnual = '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114'
    CurrentPreview = '64256afe-f5d9-4f86-8936-8840a6a4f5be'; SemiAnnualPreview = 'b8f9b850-328d-4355-9145-c59439a0c4cf'; BetaChannel = '5440fd1f-7ecb-4221-8110-145efaa6372f' }
  $WinGet = @(Get-CiValue (Get-CiValue $Manifest 'winget') 'images' @()) | Where-Object { $_.image -eq $Scope -and $_.status -in 'updated', 'current' } | Select-Object -First 1
  $Defender = @(Get-CiValue (Get-CiValue $Manifest 'defender') 'images' @()) | Where-Object { $_.image -eq $Scope -and $_.status -in 'updated', 'current' } | Select-Object -First 1
  # (not -like: "[1]" in a wildcard is a character class)
  $Drivers = @(Get-CiValue $Manifest 'drivers' @() | Where-Object { "$_".StartsWith("$($Scope): ") } | ForEach-Object { (($_ -split ': ', 2)[1] -split ' ')[-1] -replace '\\.*$', '' } | Sort-Object -Unique)
  $InstallType = if ($Image.Name -notlike 'Windows Server*') { 'Client' } elseif ($Image.Name -like '*(Desktop Experience)') { 'Server' } else { 'Server Core' }

  $Expected = [ordered]@{
    iso          = $Iso.Name
    edition      = $Image.Name
    version      = $Image.Version
    profile      = $ProfileName
    adminUser    = Get-CiValue $Ci 'AdminUser' 'admin'
    appx         = @(if ($ImageProfile) { $ImageProfile.Packages.AppXPackagesToRemove })
    capabilities = @(if ($ImageProfile) { $ImageProfile.Packages.WindowsCapabilitiesToRemove })
    registry     = $Registry
    drivers      = $Drivers
    winget       = $(if ($WinGet) { $WinGet.after })
    defender     = $(if ($Defender) { $Defender.after })
    software     = @(Get-CiValue (Get-CiValue $Ci 'ExpectSoftware') $InstallType @())
    office       = $(if ($OfficeWanted -and $OfficeOnMedia) { [ordered]@{ version = $OfficeOnMedia; product = "$($OfficeXml.Configuration.Add.Product.ID)"; channel = $Channel; channelId = $ChannelIds[$Channel] } })
  }
  $Expected | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $OutDir 'expected.json')
  #endregion

  #region media on the node
  $Phase = 'upload'
  $Sidecar = "$($Iso.FullName).sha256.txt"
  $Result.sha256 = if (Test-Path $Sidecar) { (Get-Content -Raw $Sidecar).Trim().ToLowerInvariant() } else { (Get-FileHash -Algorithm SHA256 $Iso.FullName).Hash.ToLowerInvariant() }
  $RemoteIso = 'ci-' + ($Iso.BaseName -replace '[^\w.-]', '') + '.iso'
  # room for this one: drop other test ISOs (not the CI media)
  Invoke-Pve "find $($Ci.IsoDirectory) -maxdepth 1 -name 'ci-*.iso*' ! -name '$RemoteIso*' ! -name 'ci-postinstall.iso*' -delete" | Out-Null
  Publish-Iso $Iso.FullName $RemoteIso $Result.sha256
  $CiMediaSha = Get-CiValue $CiMediaManifest 'sha256'
  if (-not $CiMediaSha) { $CiMediaSha = (Get-FileHash -Algorithm SHA256 $CiMediaPath).Hash.ToLowerInvariant() }
  Publish-Iso $CiMediaPath 'ci-postinstall.iso' $CiMediaSha

  # multi-edition media: the ISO's answer file plus the edition, on a small DVD in front of it.
  # Setup reads the first autounattend.xml in drive-letter order, and the first IDE slot gets
  # the first letter. (Not a USB stick: with a USB disk attached, OVMF reads the DVD so slowly
  # that Setup takes forever to boot.)
  $AnswerIso = $null
  if ($Images.Count -gt 1) {
    $Disk = Mount-DiskImage -ImagePath $Iso.FullName -StorageType ISO -Access ReadOnly -PassThru
    try {
      $Letter = $null
      for ($i = 0; $i -lt 30 -and -not $Letter; $i++) { $Letter = ($Disk | Get-Volume -ErrorAction SilentlyContinue).DriveLetter; if (-not $Letter) { Start-Sleep 1 } }
      [xml] $Answer = Get-Content -Raw "$($Letter):\autounattend.xml"
    }
    finally { Dismount-DiskImage -ImagePath $Iso.FullName | Out-Null }
    $Ns = New-Object System.Xml.XmlNamespaceManager $Answer.NameTable
    $Ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $Wcm = 'http://schemas.microsoft.com/WMIConfig/2002/State'
    $OsImage = $Answer.SelectSingleNode("//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']/u:ImageInstall/u:OSImage", $Ns)
    if (-not $OsImage) { throw "the ISO's autounattend.xml has no ImageInstall/OSImage to add the edition to" }
    foreach ($Old in @($OsImage.SelectNodes('u:InstallFrom', $Ns))) { $OsImage.RemoveChild($Old) | Out-Null }
    $U = 'urn:schemas-microsoft-com:unattend'
    $InstallFrom = $Answer.CreateElement('InstallFrom', $U)
    $MetaData = $Answer.CreateElement('MetaData', $U)
    $Action = $Answer.CreateAttribute('wcm', 'action', $Wcm); $Action.Value = 'add'; $MetaData.Attributes.Append($Action) | Out-Null
    $Key = $Answer.CreateElement('Key', $U); $Key.InnerText = '/IMAGE/INDEX'; $MetaData.AppendChild($Key) | Out-Null
    $Value = $Answer.CreateElement('Value', $U); $Value.InnerText = "$($Image.Index)"; $MetaData.AppendChild($Value) | Out-Null
    $InstallFrom.AppendChild($MetaData) | Out-Null
    $OsImage.PrependChild($InstallFrom) | Out-Null
    $Writer = New-Object System.IO.StringWriter
    $Answer.Save($Writer)
    $Answer.Save((Join-Path $OutDir 'autounattend-ci.xml'))

    $AnswerIso = "ci-answer-$VmId.iso"
    $Folder = "$($Ci.WorkDirectoryOnNode)/answer-$VmId"
    # -J: Joliet, for the long lowercase name
    Invoke-Pve ("set -e; rm -rf $Folder; mkdir -p $Folder; $StripBom > $Folder/autounattend.xml; " +
      "genisoimage -quiet -J -l -V CIANSWER -o $($Ci.IsoDirectory)/$AnswerIso $Folder; rm -rf $Folder") -InputText $Writer.ToString() | Out-Null
    Write-Step "answer file for edition $($Image.Index) ($($Image.Name)) on $AnswerIso."
  }
  #endregion

  #region VM
  $Phase = 'create'
  Remove-Vm $VmId
  $Create = @(
    "qm create $VmId --name ci-$VmId",
    '--machine q35 --bios ovmf --ostype win11 --cpu host --sockets 1',
    "--cores $($Ci.Cores) --memory $($Ci.MemoryMB) --balloon 0",
    "--efidisk0 $($Ci.DiskStorage):1,efitype=4m,pre-enrolled-keys=1 --tpmstate0 $($Ci.DiskStorage):1,version=v2.0",
    "--scsihw virtio-scsi-single --scsi0 $($Ci.DiskStorage):$($Ci.DiskGB),iothread=1,discard=on,ssd=1",
    "--net0 virtio,bridge=$($Ci.Bridge)",
    "--ide2 $($Ci.IsoStorage):iso/$RemoteIso,media=cdrom --ide1 $($Ci.IsoStorage):iso/ci-postinstall.iso,media=cdrom",
    "--boot 'order=scsi0;ide2' --agent enabled=1 --vga std --tags ci --description 'Customize-WindowsIso install test: $($Iso.Name) $($Image.Name)'"
  ) -join ' '
  if ($AnswerIso) { $Create += " --ide0 $($Ci.IsoStorage):iso/$AnswerIso,media=cdrom" }
  # COM1 into a file on the node: the CI media streams the first-logon transcript to it
  $SerialLog = "$($Ci.WorkDirectoryOnNode)/serial-$VmId.log"
  Invoke-Pve "mkdir -p $($Ci.WorkDirectoryOnNode); rm -f $SerialLog" | Out-Null
  $Create += " --args '-serial file:$SerialLog'"
  Invoke-Pve $Create -TimeoutSeconds 300 | Out-Null
  Invoke-Pve "qm start $VmId" -TimeoutSeconds 120 | Out-Null
  $Booted = Get-Date
  $script:ScreenChanged = $Booted
  Write-Step "VM $VmId started: $($Image.Name) from $RemoteIso."
  #endregion

  #region wait: Setup (until the guest agent answers, which the first-logon scripts install), then the first-logon scripts
  $Phase = 'setup'
  $Deadline = $Booted.AddMinutes($Ci.SetupTimeoutMinutes)
  $NextShot = Get-Date
  $NextSerial = Get-Date
  $ScriptsDone = $null
  while (-not (Test-GuestAgent $VmId)) {
    if ((Get-VmStatus $VmId) -ne 'running') { throw "the VM stopped during Setup" }
    # the first-logon scripts may finish without ever installing the agent
    if ((Get-Date) -ge $NextSerial) {
      $NextSerial = (Get-Date).AddMinutes(1)
      if (-not $ScriptsDone -and (Invoke-Pve "grep -a -c 'CI: first-logon scripts complete' $SerialLog; true").Trim() -ne '0') { $ScriptsDone = Get-Date }
      if ($ScriptsDone -and ((Get-Date) - $ScriptsDone).TotalMinutes -ge 3) {
        Save-Shot 'no-agent'
        throw 'the first-logon scripts finished but the guest agent never answered: the VirtIO guest tools did not install (see serial-oobe-transcript.log)'
      }
    }
    if ((Get-Date) -gt $Deadline) { Save-Shot 'setup-timeout'; throw "the guest agent didn't answer within $($Ci.SetupTimeoutMinutes) minutes (Setup stuck, or the guest tools didn't install)" }
    if ((Get-Date) -ge $NextShot) { Save-Shot 'setup'; $NextShot = (Get-Date).AddMinutes($Ci.ScreenshotMinutes) }
    # Setup keeps showing new things (progress, phases); a screen with nothing new is stuck
    $Still = ((Get-Date) - $script:ScreenChanged).TotalMinutes
    if ($Still -ge (Get-CiValue $Ci 'StallMinutes' 20)) {
      Save-Shot 'stalled'
      throw "Setup has shown nothing new for $([int]$Still) minutes: stuck at a prompt, an error or a boot hang (see the last screenshot)"
    }
    Start-Sleep -Seconds 20
  }
  $Result.phases.setupMinutes = [math]::Round(((Get-Date) - $Booted).TotalMinutes, 1)
  Write-Step "guest agent up after $($Result.phases.setupMinutes) min."

  $Phase = 'first logon'
  $Marker = 'C:\ProgramData\Customize-WindowsIso\ci\oobe-complete.json'
  $AgentUp = Get-Date
  $Deadline = $AgentUp.AddMinutes($Ci.PostinstallTimeoutMinutes)
  while (-not (Read-GuestFile $VmId $Marker)) {
    if ((Get-VmStatus $VmId) -ne 'running') { throw "the VM stopped during the first-logon scripts" }
    if ((Get-Date) -gt $Deadline) { Save-Shot 'firstlogon-timeout'; throw "the first-logon scripts didn't finish within $($Ci.PostinstallTimeoutMinutes) minutes" }
    if ((Get-Date) -ge $NextShot) { Save-Shot 'firstlogon'; $NextShot = (Get-Date).AddMinutes($Ci.ScreenshotMinutes) }
    Start-Sleep -Seconds 20
  }
  $Result.phases.firstLogonMinutes = [math]::Round(((Get-Date) - $AgentUp).TotalMinutes, 1)
  Write-Step "first-logon scripts done after another $($Result.phases.firstLogonMinutes) min."
  Save-Shot 'done'
  #endregion

  #region checks
  $Phase = 'checks'
  $Checked = Invoke-GuestChecks $VmId $Expected (Join-Path $OutDir 'checks-raw.txt')
  $Result.checks = @($Checked.checks)
  $Result.facts = $Checked.facts
  $Failed = @($Result.checks | Where-Object result -eq 'Fail')
  $Result.result = if ($Failed) { 'Fail' } else { 'Pass' }
  if ($Failed) { $Result.error = "$($Failed.Count) check(s) failed: $(($Failed | ForEach-Object name) -join ', ')" }
  #endregion
}
catch {
  $Result.error = "$Phase`: $_"
  Write-Warning "$($Short): FAILED in $Phase`: $_"
  if (Get-VmStatus $VmId) { Save-Shot 'failure' }
}
finally {
  # whatever the outcome: the first-logon transcript (from COM1, so also without the agent)
  # and, on failure, Setup's logs
  if ($SerialLog) {
    $SerialCopy = Join-Path $OutDir 'serial-oobe-transcript.log'
    try {
      Copy-FromPve $SerialLog $SerialCopy
      # the scripts' warnings, for the report (the checks see them too, but not when the agent never came up)
      $Result.notes = @(Get-Content $SerialCopy -Encoding UTF8 | ForEach-Object { $_ -replace '[\x00\r]', '' } | Where-Object { $_ -match '^WARNING: ' } | Select-Object -Unique -First 10)
    }
    catch { Write-Warning "no serial log: $_" }
  }
  if ((Get-VmStatus $VmId) -eq 'running' -and (Test-GuestAgent $VmId)) {
    $Files = @('C:\ProgramData\Customize-WindowsIso\ci\oobe-transcript.log')
    if ($Result.result -ne 'Pass') { $Files += 'C:\Windows\Panther\setupact.log', 'C:\Windows\Panther\UnattendGC\setupact.log' }
    foreach ($File in $Files) {
      $Content = Read-GuestFile $VmId $File
      if ($Content) { Set-Content -Encoding utf8 (Join-Path $OutDir ((Split-Path -Leaf (Split-Path $File)) + '-' + (Split-Path -Leaf $File))) $Content }
    }
  }
  $Counts = @{}; foreach ($R in 'Pass', 'Fail', 'Warn', 'Info') { $Counts[$R] = @($Result.checks | Where-Object result -eq $R).Count }
  $Result.summary = "$($Counts.Pass) pass, $($Counts.Fail) fail, $($Counts.Warn) warn"
  $Result.finished = (Get-Date).ToString('o')
  $Result.phases.totalMinutes = [math]::Round(((Get-Date) - $Started).TotalMinutes, 1)

  if ($Result.result -eq 'Pass' -or -not (Get-CiValue $Ci 'KeepFailedVm' $true)) { try { Remove-Vm $VmId } catch { Write-Warning "removing VM $VmId`: $_" } }
  elseif (Get-VmStatus $VmId) {
    Invoke-Pve "qm stop $VmId --timeout 60" -AllowFailure | Out-Null
    $Result.vmKept = $true
    Write-Step "kept VM $VmId (stopped) for troubleshooting; the next test replaces it."
  }
  if ($AnswerIso -and -not $Result.vmKept) { Invoke-Pve "rm -f $($Ci.IsoDirectory)/$AnswerIso" -AllowFailure | Out-Null }
  if ($SerialLog -and -not $Result.vmKept) { Invoke-Pve "rm -f $SerialLog" -AllowFailure | Out-Null }

  [PSCustomObject] $Result | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $OutDir 'result.json')
  Write-Step "$($Result.result): $($Result.summary)$(if ($Result.error) { " - $($Result.error)" }) ($($Result.phases.totalMinutes) min)."
  foreach ($Check in $Result.checks) { if ($Check.result -in 'Fail', 'Warn') { Write-Host "  [$($Check.result.ToUpper())] $($Check.name): $($Check.detail)" } }
  Stop-Transcript | Out-Null
}

exit $(if ($Result.result -eq 'Pass') { 0 } else { 1 })
