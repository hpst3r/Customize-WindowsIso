# Search for a .postinstall directory at the root of all filesystem drives
$PostinstallDirectoryRoot = Get-PSDrive -PSProvider FileSystem |
Where-Object { Test-Path "$($_.Root).postinstall\oobe" } |
Select-Object -ExpandProperty Root -First 1

if ($PostinstallDirectoryRoot) {

  $PostinstallDirectory = "$PostinstallDirectoryRoot.postinstall\oobe"

  Write-Host "Found .postinstall directory: '$($PostinstallDirectory)'" -ForegroundColor Green

  # collect all .ps1 scripts in the .postinstall directory, sorted by name (so ordering them e.g. 01-setup.ps1, 02-configure.ps1, etc works)
  $Scripts = (Get-ChildItem -Path $PostinstallDirectory -Filter *.ps1 -File | Sort-Object Name)

  foreach ($Script in $Scripts) {
    Write-Host "Executing script: '$($Script.FullName)'" -ForegroundColor Green
    try {
      # Execute the script
      & $Script.FullName
      Write-Host "Successfully executed: '$($Script.FullName)'" -ForegroundColor Green
    } catch {
      Write-Host "Error executing script: '$($Script.FullName)'. Error: $_" -ForegroundColor Red
    }
  }

}
else {
  Write-Host "No .postinstall\oobe directory found on any filesystem drive." -ForegroundColor Yellow
}
