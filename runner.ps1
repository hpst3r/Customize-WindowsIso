$ConfigFile = (Join-Path (Split-Path $PSCommandPath) runner-config.json)
$BuildScript = (Join-Path (Split-Path $PSCommandPath) Customize-Iso.ps1)
$Config = (Get-Content $ConfigFile | ConvertFrom-Json)

Remove-Item $Config.WorkingDirectory -Force -Recurse
New-Item $Config.WorkingDirectory -Force -ItemType Directory

if (-not (Test-Path $Config.OutputDirectory)) {
  New-Item $Config.OutputDirectory -Force -ItemType Directory
}

$Processes = foreach ($IsoFile in ($Config.InputDirectory | Get-ChildItem -Filter "*.iso")) {

  $WorkingDirectory = (Join-Path $Config.WorkingDirectory $IsoFile.Name)

  Write-Host "stub: Starting script $($BuildScript) for ISO with working directory $($WorkingDirectory)."

  $Arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $BuildScript,
    "-IsoPath", "`"$($IsoFile.FullName)`"",
    "-WorkingDir", "`"$($WorkingDirectory)`"",
    "-WinREWimPath", "`"$($Config.RecoveryWimPath)`"",
    "-OutPath", "`"$(Join-Path $Config.OutputDirectory $($IsoFile.Name))`"",
    "-ConfigFile", "`"$(Join-Path (Split-Path $PSCommandPath) config.json)`"",
    "-Autounattend", "`"$(Join-Path (Split-Path $PSCommandPath) autounattend.xml)`"",
    "-Verbose"
  )

  Start-Process `
    -FilePath 'powershell.exe' `
    -ArgumentList $Arguments `
    -PassThru `
  
}

Write-Host 'stub: Processes launched. Waiting for completion.'

foreach ($Process in $Processes) {

  $Process.WaitForExit()

}

Write-Host 'stub: Build processes finished.'

Write-Host 'stub: Beginning cleanup.'

# Write-Host "stub: Moving products to $($Config.OutputDirectory)."

# Get-ChildItem $Config.WorkingDirectory -Recurse -File |
#   Where-Object Name -match "(sha256|.iso$)" |
#   Move-Item -Destination $Config.OutputDirectory -Force

Write-Host "stub: Removing working directory $($Config.WorkingDirectory)."

Remove-Item $Config.WorkingDirectory -Force -Recurse

Write-Host 'stub: Done!'
