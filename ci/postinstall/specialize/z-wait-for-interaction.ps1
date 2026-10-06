# CI only: replaces the "Press Enter" pause in specialize. Records that specialize ran.
$CiDir = Join-Path $env:ProgramData 'Customize-WindowsIso\ci'
New-Item -ItemType Directory -Force -Path $CiDir | Out-Null
[PSCustomObject]@{ completed = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $CiDir 'specialize-complete.json')
