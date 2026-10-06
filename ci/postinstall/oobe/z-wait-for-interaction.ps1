# CI only: replaces the "Press Enter" pause. Runs the install checks and tells the test the
# first-logon scripts are done. Everything here reaches the test through the serial copy of
# the transcript (see 00-ci-begin.ps1), so it works without the guest agent or the network.
$CiDir = Join-Path $env:ProgramData 'Customize-WindowsIso\ci'
New-Item -ItemType Directory -Force -Path $CiDir | Out-Null
[PSCustomObject]@{ completed = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $CiDir 'oobe-complete.json')

# for the report when something is missing
Write-Host 'CI: devices with problems:'
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object Status -ne 'OK' |
  ForEach-Object { Write-Host "  $($_.Status) $($_.Class) $($_.FriendlyName) [$($_.InstanceId)] code $((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_ProblemCode -ErrorAction SilentlyContinue).Data)" }
Write-Host 'CI: network adapters:'
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.Name): $($_.InterfaceDescription), $($_.Status), driver $($_.DriverFileName) $($_.DriverVersion)" }
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.InterfaceAlias): $($_.IPAddress)/$($_.PrefixLength) ($($_.PrefixOrigin))" }

# the checks, from the test's own DVD (ci\Test-InstalledWindows.ps1 and ci\expected.json);
# the results go out base64-encoded in short lines between markers
$TestDrive = Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path "$($_.Root)ci\expected.json" } | Select-Object -First 1
if ($TestDrive) {
  Copy-Item "$($TestDrive.Root)ci\Test-InstalledWindows.ps1", "$($TestDrive.Root)ci\expected.json" $CiDir -Force
  try {
    $Json = & (Join-Path $CiDir 'Test-InstalledWindows.ps1') -ExpectedFile (Join-Path $CiDir 'expected.json') | Out-String
  }
  catch { $Json = [PSCustomObject]@{ checks = @([PSCustomObject]@{ name = 'checks'; result = 'Fail'; detail = "the checks threw: $_" }) } | ConvertTo-Json -Depth 4 }
  $Encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json))
  Write-Host 'CI-RESULTS-BEGIN'
  for ($i = 0; $i -lt $Encoded.Length; $i += 100) { Write-Host "CI-RESULTS:$($Encoded.Substring($i, [Math]::Min(100, $Encoded.Length - $i)))" }
  Write-Host 'CI-RESULTS-END'
}
else { Write-Host 'CI: no ci\expected.json on any drive; the test runs the checks through the guest agent.' }

# the test watches for this line
Write-Host 'CI: first-logon scripts complete.'
try { Stop-Transcript | Out-Null } catch { }
