# CI only: replaces the "Press Enter" pause. Tells the test the first-logon scripts are done.
$CiDir = Join-Path $env:ProgramData 'Customize-WindowsIso\ci'
New-Item -ItemType Directory -Force -Path $CiDir | Out-Null
[PSCustomObject]@{ completed = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $CiDir 'oobe-complete.json')
try { Stop-Transcript | Out-Null } catch { }
