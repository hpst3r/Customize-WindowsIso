# CI only (ci\postinstall overlays the repo's .postinstall on the test media).
# Records everything the first-logon scripts print, for the test report.
$CiDir = Join-Path $env:ProgramData 'Customize-WindowsIso\ci'
New-Item -ItemType Directory -Force -Path $CiDir | Out-Null
Start-Transcript -Path (Join-Path $CiDir 'oobe-transcript.log') -Append | Out-Null
[PSCustomObject]@{ started = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $CiDir 'oobe-started.json')
