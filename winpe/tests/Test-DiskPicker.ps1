<#
.SYNOPSIS
Runs winpe\diskpicker.cmd against recorded and synthetic diskpart output.

.DESCRIPTION
diskpicker.cmd runs in test mode (DP_TEST_DIR): it reads list.txt/detail-<n>.txt
instead of running diskpart, prints the partitioning script instead of running it,
and never starts Setup. Nothing on this machine is touched.

samples\ is real output from a Proxmox VM with two virtio-scsi disks. The other
scenarios are built in the same format (fixed columns, as diskpart prints them).

-TemplateDir: a folder with unattend-head.xml/unattend-tail.xml (e.g. copied out of a
built boot.wim) to check the real answer file; by default a minimal one is used.
#>
param (
  [string] $Script,
  [string] $TemplateDir,
  [string] $OutDir = (Join-Path $env:TEMP 'diskpicker-tests')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path $PSScriptRoot) 'diskpicker.cmd' }
$Samples = Join-Path $PSScriptRoot 'samples'
$Failures = [System.Collections.Generic.List[string]]::new()

$Header = "`r`nMicrosoft DiskPart version 10.0.26100.1150`r`n`r`nCopyright (C) Microsoft Corporation.`r`nOn computer: MINWINPC`r`n`r`n"

function New-ListDisk([object[]] $Disks) {
  $Lines = @('  Disk ###  Status         Size     Free     Dyn  Gpt', '  --------  -------------  -------  -------  ---  ---')
  foreach ($D in $Disks) {
    $Lines += '  Disk {0,-3}  {1,-13}  {2,7}  {3,7}  {4,3}  {5,3}' -f $D.N, $D.Status, $D.Size, '1024 KB', '', '*'
  }
  $Header + ($Lines -join "`r`n") + "`r`n`r`nLeaving DiskPart...`r`n"
}

# Volumes: @{ Ltr; Label; Fs; Type; Size }
function New-DetailDisk($D) {
  $Lines = @(
    "Disk $($D.N) is now the selected disk.", '', $D.Model,
    'Disk ID: {00000000-0000-0000-0000-000000000000}',
    "Type   : $($D.Type)", "Status : $($D.Status)", 'Path   : 0', 'Target : 0', 'LUN ID : 0',
    'Location Path : PCIROOT(0)#PCI(0100)', "Current Read-only State : $(if ($D.Contains('RO')) { $D.RO } else { 'No' })", 'Read-only  : No',
    'Boot Disk  : No', 'Pagefile Disk  : No', 'Hibernation File Disk  : No', 'Crashdump Disk  : No', 'Clustered Disk  : No', ''
  )
  $Volumes = @(if ($D.Contains('Volumes')) { $D.Volumes })
  if ($Volumes) {
    $Lines += '  Volume ###  Ltr  Label        Fs     Type        Size     Status     Info'
    $Lines += '  ----------  ---  -----------  -----  ----------  -------  ---------  --------'
    $i = 2
    foreach ($V in $Volumes) {
      $Lines += '  Volume {0,-3}   {1,1}   {2,-11}  {3,-5}  {4,-10}  {5,7}  {6,-9}  {7,-8}' -f $i, $V.Ltr, $V.Label, $V.Fs, $V.Type, $V.Size, 'Healthy', ''
      $i++
    }
  }
  else { $Lines += 'There are no volumes.' }
  $Lines += ''
  if ($Volumes) {
    $Lines += '  Partition ###  Type              Size     Offset'
    $Lines += '  -------------  ----------------  -------  -------'
    $i = 1
    foreach ($V in $Volumes) { $Lines += '  Partition {0,-3}  {1,-16}  {2,7}  {3,7}' -f $i, 'Primary', $V.Size, '1024 KB'; $i++ }
  }
  else { $Lines += 'There are no partitions on this disk to show.' }
  $Header + ($Lines -join "`r`n") + "`r`n`r`nLeaving DiskPart...`r`n"
}

function Invoke-Scenario {
  param ([string] $Name, [object[]] $Disks, [string] $SampleDir, [string[]] $Answers = @(), [string] $Media = '',
    [string] $Firmware = 'UEFI', [int] $MinGB = 50, [string[]] $Expect = @(), [string[]] $Reject = @(),
    $InstallDisk = $null, [int] $Partition = 3, [string] $AnswerOverride = '')

  $Dir = Join-Path $OutDir $Name
  if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
  New-Item -ItemType Directory -Force $Dir | Out-Null

  if ($SampleDir) { Copy-Item (Join-Path $SampleDir '*.txt') $Dir }
  else {
    [IO.File]::WriteAllText((Join-Path $Dir 'list.txt'), (New-ListDisk $Disks), [Text.Encoding]::ASCII)
    foreach ($D in $Disks) { [IO.File]::WriteAllText((Join-Path $Dir "detail-$($D.N).txt"), (New-DetailDisk $D), [Text.Encoding]::ASCII) }
  }
  if ($TemplateDir) { Copy-Item (Join-Path $TemplateDir 'unattend-*.xml') $Dir }
  else {
    [IO.File]::WriteAllText((Join-Path $Dir 'unattend-head.xml'), "<?xml version=`"1.0`" encoding=`"utf-8`"?>`r`n<unattend xmlns=`"urn:schemas-microsoft-com:unattend`"><ImageInstall><OSImage><InstallTo>")
    [IO.File]::WriteAllText((Join-Path $Dir 'unattend-tail.xml'), "</InstallTo></OSImage></ImageInstall></unattend>`r`n")
  }
  $AnswerFile = Join-Path $Dir 'answers.txt'
  [IO.File]::WriteAllText($AnswerFile, (@($Answers) + '' | ForEach-Object { "$_`r`n" }) -join '', [Text.Encoding]::ASCII)

  # set /p only reads answers line by line from a file, not from a pipe
  $env:DP_TEST_DIR = $Dir; $env:DP_TEST_MEDIA = $Media; $env:DP_TEST_FIRMWARE = $Firmware; $env:DP_MIN_GB = "$MinGB"
  $env:DP_TEST_ANSWER = $AnswerOverride
  try { $Output = @(cmd.exe /d /c "`"$Script`" < `"$AnswerFile`" 2>&1") -join "`n" }
  finally { Remove-Item Env:DP_TEST_DIR, Env:DP_TEST_MEDIA, Env:DP_TEST_FIRMWARE, Env:DP_MIN_GB, Env:DP_TEST_ANSWER -ErrorAction SilentlyContinue }
  Set-Content -Path (Join-Path $Dir 'output.txt') -Value $Output

  $Problems = @()
  foreach ($E in $Expect) { if (-not $Output.Contains($E)) { $Problems += "missing '$E'" } }
  foreach ($R in $Reject) { if ($Output.Contains($R)) { $Problems += "unexpected '$R'" } }
  if ($Output -match "not recognized|syntax of the command|was unexpected at this time|Missing operand|Invalid number") { $Problems += "cmd error: $($Matches[0])" }

  $Unattend = Join-Path $Dir 'work\unattend.xml'
  if ($null -ne $InstallDisk) {
    if (-not (Test-Path $Unattend)) { $Problems += 'no unattend.xml written' }
    else {
      [xml] $Xml = Get-Content -Raw $Unattend
      $Ns = New-Object System.Xml.XmlNamespaceManager $Xml.NameTable
      $Ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
      $To = @($Xml.SelectNodes('//u:OSImage/u:InstallTo', $Ns))
      if ($To.Count -ne 1) { $Problems += "expected one InstallTo, found $($To.Count)" }
      elseif ($To[0].DiskID -ne "$InstallDisk" -or $To[0].PartitionID -ne "$Partition") { $Problems += "InstallTo is disk $($To[0].DiskID) partition $($To[0].PartitionID), expected $InstallDisk/$Partition" }
      if (@($Xml.SelectNodes('//u:DiskConfiguration', $Ns)).Count) { $Problems += 'unattend.xml still has DiskConfiguration' }
    }
  }
  elseif (Test-Path $Unattend) { $Problems += 'unattend.xml written but no install expected' }

  if ($Problems) { $Failures.Add("$($Name): $($Problems -join '; ')"); Write-Host "FAIL $Name`: $($Problems -join '; ')" -ForegroundColor Red }
  else { Write-Host "ok   $Name" -ForegroundColor Green }
}

$NoVolumes = @()
$WindowsVolumes = @(@{ Ltr = ''; Label = ''; Fs = 'FAT32'; Type = 'Partition'; Size = '100 MB' }, @{ Ltr = 'C'; Label = 'Windows'; Fs = 'NTFS'; Type = 'Partition'; Size = '475 GB' })

# one virtio-scsi disk (Proxmox VM): no menu, straight to Setup
Invoke-Scenario 'vm-single-disk' -Disks @(@{ N = 0; Status = 'Online'; Size = '64 GB'; Model = 'QEMU QEMU HARDDISK SCSI Disk Device'; Type = 'SAS' }) `
  -Expect @('Installing Windows on disk 0', 'convert gpt', 'create partition efi size=260', 'would run: ') -Reject @('Choice:', 'convert mbr') -InstallDisk 0 -Partition 3

# the same booted in BIOS mode: MBR layout, Windows on partition 2
Invoke-Scenario 'vm-single-disk-bios' -Firmware BIOS -Disks @(@{ N = 0; Status = 'Online'; Size = '64 GB'; Model = 'QEMU QEMU HARDDISK SCSI Disk Device'; Type = 'SAS' }) `
  -Expect @('convert mbr', 'active') -Reject @('Choice:', 'convert gpt') -InstallDisk 0 -Partition 2

# recorded: two virtio-scsi disks with existing volumes -> menu, pick 1, confirm
Invoke-Scenario 'recorded-two-disks' -SampleDir $Samples -Answers @('1', 'YES') `
  -Expect @('Choice:', 'QEMU QEMU HARDDISK SCSI Disk Device', '64 GB', '256 GB', 'SAS', 'C:', 'Y:', 'Data', '4 partition(s)', '2 partition(s)', 'Installing Windows on disk 1', 'select disk 1') `
  -Reject @('select disk 0') -InstallDisk 1

# menu, pick a disk but don't confirm, then a bad answer, then give up: nothing installed
Invoke-Scenario 'two-disks-cancel' -SampleDir $Samples -Answers @('1', 'no', '7') -Expect @('Type YES', 'is not one of the choices', 'no more input') -Reject @('Installing Windows')

# booted from a USB stick (media on D:) with one NVMe disk: USB never offered, NVMe automatic
Invoke-Scenario 'usb-media-one-nvme' -Media ' D' -Disks @(
  @{ N = 0; Status = 'Online'; Size = '476 GB'; Model = 'Samsung SSD 980 PRO 500GB'; Type = 'NVMe'; Volumes = $WindowsVolumes },
  @{ N = 1; Status = 'Online'; Size = '29 GB'; Model = 'SanDisk Ultra USB Device'; Type = 'USB'; Volumes = @(@{ Ltr = 'D'; Label = 'CCCOMA_X64F'; Fs = 'NTFS'; Type = 'Removable'; Size = '29 GB' }) }
) -Expect @('Installing Windows on disk 0') -Reject @('Choice:', 'select disk 1') -InstallDisk 0

# install media on an internal SATA disk (by drive letter): excluded even though it is big
Invoke-Scenario 'media-on-internal-disk' -Media ' E' -Disks @(
  @{ N = 0; Status = 'Online'; Size = '931 GB'; Model = 'WDC WD10EZEX-08WN4A0'; Type = 'SATA'; Volumes = @(@{ Ltr = 'E'; Label = 'Installers'; Fs = 'NTFS'; Type = 'Partition'; Size = '931 GB' }) },
  @{ N = 1; Status = 'Online'; Size = '238 GB'; Model = 'INTEL SSDPEKKF256G8L'; Type = 'NVMe' }
) -Expect @('Installing Windows on disk 1') -Reject @('Choice:', 'select disk 0') -InstallDisk 1

# Ventoy on an internal disk (recognized by its partition labels, no letter needed)
Invoke-Scenario 'ventoy-internal' -Disks @(
  @{ N = 0; Status = 'Online'; Size = '931 GB'; Model = 'Samsung SSD 870 EVO 1TB'; Type = 'SATA'; Volumes = @(@{ Ltr = 'F'; Label = 'Ventoy'; Fs = 'exFAT'; Type = 'Partition'; Size = '931 GB' }, @{ Ltr = ''; Label = 'VTOYEFI'; Fs = 'FAT'; Type = 'Partition'; Size = '32 MB' }) },
  @{ N = 1; Status = 'Online'; Size = '238 GB'; Model = 'INTEL SSDPEKKF256G8L'; Type = 'NVMe' }
) -Expect @('Installing Windows on disk 1') -Reject @('Choice:') -InstallDisk 1

# no usable disk (only the USB stick): explain, then let Setup show its page
Invoke-Scenario 'no-disk' -Media ' D' -Disks @(
  @{ N = 0; Status = 'Online'; Size = '29 GB'; Model = 'SanDisk Ultra USB Device'; Type = 'USB'; Volumes = @(@{ Ltr = 'D'; Label = 'CCCOMA_X64F'; Fs = 'NTFS'; Type = 'Removable'; Size = '29 GB' }) }
) -Answers @('S') -Expect @('No disk was found', 'storage controller', 'Not available:', 'holds the install media', 'Choice:', 'would run: ') -Reject @('/unattend', 'Type a disk number')

# nothing at all (no driver for the controller): load a driver, rescan, give up
Invoke-Scenario 'no-disks-at-all' -Disks @() -Answers @('L', 'E:\vioscsi\w11\amd64\vioscsi.inf') `
  -Expect @('No disk was found', 'would run: drvload "E:\vioscsi\w11\amd64\vioscsi.inf"', 'no more input') -Reject @('Not available:')

# only a small internal disk: never automatic, but it can be picked
Invoke-Scenario 'small-disk-only' -Disks @(@{ N = 0; Status = 'Online'; Size = '32 GB'; Model = 'QEMU QEMU HARDDISK SCSI Disk Device'; Type = 'SAS' }) `
  -Answers @('0', 'yes') -Expect @('smaller than 50 GB', 'Choice:', 'Installing Windows on disk 0') -InstallDisk 0

# a small disk next to a big one doesn't stop the automatic install (Optane/eMMC + SSD)
Invoke-Scenario 'small-and-big' -Disks @(
  @{ N = 0; Status = 'Online'; Size = '13 GB'; Model = 'INTEL MEMPEK1J016GAL'; Type = 'NVMe' },
  @{ N = 1; Status = 'Online'; Size = '476 GB'; Model = 'Samsung SSD 980 PRO 500GB'; Type = 'NVMe'; Volumes = $WindowsVolumes }
) -Expect @('Installing Windows on disk 1') -Reject @('Choice:') -InstallDisk 1

# two-word status, an empty card reader, disk numbers >= 10, TB sizes
Invoke-Scenario 'big-and-odd' -Disks @(
  @{ N = 0; Status = 'No Media'; Size = '0 B'; Model = 'Generic- SD/MMC USB Device'; Type = 'SD' },
  @{ N = 10; Status = 'Online'; Size = '7452 GB'; Model = 'ST8000NM000A-2KE101'; Type = 'SATA' },
  @{ N = 11; Status = 'Offline'; Size = '14 TB'; Model = 'WDC WUH721414ALE6L4'; Type = 'SAS'; RO = 'Yes' }
) -Answers @('11', 'YES') -Expect @('7452 GB', '14 TB', 'no media', 'Offline', 'read-only', 'Installing Windows on disk 11', 'select disk 11') -InstallDisk 11

# an answer file on another drive (e.g. a stick, or the install tests' DVD): Setup runs with
# it, no menu, nothing partitioned by the picker
Invoke-Scenario 'answer-file-on-another-drive' -SampleDir $Samples -AnswerOverride 'E:\autounattend.xml' `
  -Expect @('Found an answer file on another drive: E:\autounattend.xml', '/unattend:E:\autounattend.xml') -Reject @('Choice:', 'Erasing and partitioning')

if ($Failures.Count) { Write-Host "$($Failures.Count) scenario(s) failed. Output is in $OutDir."; exit 1 }
Write-Host "All scenarios passed. Output is in $OutDir."
exit 0
