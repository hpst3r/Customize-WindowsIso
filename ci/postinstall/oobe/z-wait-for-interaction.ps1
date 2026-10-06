# CI only: replaces the "Press Enter" pause. Tells the test the first-logon scripts are done.
$CiDir = Join-Path $env:ProgramData 'Customize-WindowsIso\ci'

# for the report when the guest agent or the network never come up: this reaches the test
# through the serial copy of the transcript
Write-Host 'CI: devices with problems:'
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object Status -ne 'OK' |
  ForEach-Object { Write-Host "  $($_.Status) $($_.Class) $($_.FriendlyName) [$($_.InstanceId)] code $((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_ProblemCode -ErrorAction SilentlyContinue).Data)" }
Write-Host 'CI: network adapters:'
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.Name): $($_.InterfaceDescription), $($_.Status), driver $($_.DriverFileName) $($_.DriverVersion)" }
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.InterfaceAlias): $($_.IPAddress)/$($_.PrefixLength) ($($_.PrefixOrigin))" }
New-Item -ItemType Directory -Force -Path $CiDir | Out-Null
[PSCustomObject]@{ completed = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $CiDir 'oobe-complete.json')
# the test watches the serial copy of the transcript for this line
Write-Host 'CI: first-logon scripts complete.'
try { Stop-Transcript | Out-Null } catch { }
