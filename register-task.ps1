#Requires -Version 5.1 -RunAsAdministrator

<#
.SYNOPSIS
Registers the weekly image build: Get-WindowsIso (download + update), then
Customize-WindowsIso (customize), then a notification, as one scheduled task
running as SYSTEM.

.DESCRIPTION
Task Scheduler runs a task's actions in order, each waiting for the previous
one, so customization always sees the finished output of the download step.
The customize step runs even if some downloads failed - it rebuilds whatever
changed and skips the rest. With -InstallTests, ci\Invoke-ImageTests.ps1 then
installs every new image in a VM on the Proxmox test node. The notification step
(Send-BuildNotification.ps1) always runs last and reports on all of them; it does
nothing until notify.json exists.

Running as SYSTEM avoids a dedicated local account with a stored password.

.EXAMPLE
.\register-task.ps1 -GetWindowsIsoPath Y:\src\Get-WindowsIso -InstallTests
#>
param (
  # path to a clone of https://github.com/hpst3r/Get-WindowsIso; omit to only run customization
  [string] $GetWindowsIsoPath,
  [string] $TaskName = 'Weekly Windows Image Build',
  [System.DayOfWeek] $DayOfWeek = 'Wednesday',
  [string] $At = '01:00',
  [int] $TimeLimitHours = 30,
  # leave out the Send-BuildNotification.ps1 action
  [switch] $NoNotification,
  # install-test the new images on the Proxmox test node (ci\Invoke-ImageTests.ps1, ci\ci-config.json)
  # after customizing and before the notification
  [switch] $InstallTests
)

$ErrorActionPreference = 'Stop'

$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Actions = @()

if ($GetWindowsIsoPath) {
  $Stub = Join-Path (Resolve-Path $GetWindowsIsoPath) 'stub.ps1'
  if (-not (Test-Path $Stub)) { throw "stub.ps1 not found in $GetWindowsIsoPath" }
  $Actions += New-ScheduledTaskAction -Execute $PowerShell `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Stub`"" `
    -WorkingDirectory (Split-Path $Stub)
}

$Runner = Join-Path $PSScriptRoot 'runner.ps1'
$Actions += New-ScheduledTaskAction -Execute $PowerShell `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Runner`"" `
  -WorkingDirectory $PSScriptRoot

if ($InstallTests) {
  $Tests = Join-Path $PSScriptRoot 'ci\Invoke-ImageTests.ps1'
  $Actions += New-ScheduledTaskAction -Execute $PowerShell `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Tests`"" `
    -WorkingDirectory (Split-Path $Tests)
}

if (-not $NoNotification) {
  $Notify = Join-Path $PSScriptRoot 'Send-BuildNotification.ps1'
  $NotifyArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Notify`""
  # the stub writes its summary to logs\ next to itself
  if ($GetWindowsIsoPath) { $NotifyArguments += " -StubSummaryPath `"$(Join-Path (Split-Path $Stub) 'logs\last-run-stub.json')`"" }
  if ($InstallTests) { $NotifyArguments += ' -IncludeInstallTests' }
  $Actions += New-ScheduledTaskAction -Execute $PowerShell -Argument $NotifyArguments -WorkingDirectory $PSScriptRoot
}

$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $At

$Settings = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit (New-TimeSpan -Hours $TimeLimitHours) `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -DontStopOnIdleEnd

$Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Actions -Trigger $Trigger -Settings $Settings -Principal $Principal `
  -Description "Downloads fully-updated Windows client/server ISOs (Get-WindowsIso), customizes them (Customize-WindowsIso), $(if ($InstallTests) { 'install-tests them on the Proxmox test node, ' })and sends a notification." `
  -Force
