# Waits for the Microsoft 365 Apps install that 06-start-office-install.ps1 started in the
# background, so the post-install media isn't removed while Office is still reading from it.

$Install = Get-Variable -Name OfficeInstall -Scope Global -ValueOnly -ErrorAction SilentlyContinue
if (-not $Install) { return }

Write-Host "Waiting for Microsoft 365 Apps to finish installing (from $($Install.From))..."
while (-not $Install.Process.WaitForExit(30000)) {
  Write-Host "  still installing ($([int]((Get-Date) - $Install.Started).TotalMinutes) min)..."
}
$Minutes = [math]::Round(((Get-Date) - $Install.Started).TotalMinutes, 1)

$Version = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -Name VersionToReport -ErrorAction SilentlyContinue).VersionToReport
if ($Install.Process.ExitCode -eq 0 -and $Version) {
  Write-Host "Microsoft 365 Apps $Version installed in $Minutes minutes."
}
else {
  Write-Warning "Microsoft 365 Apps install failed (setup.exe exit code $($Install.Process.ExitCode), after $Minutes minutes). Logs: $($Install.LogDir)"
}
Remove-Variable -Name OfficeInstall -Scope Global -ErrorAction SilentlyContinue
