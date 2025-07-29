# Customize-WindowsIso

Set of scripts to take a Windows ISO and:

- Remove arbitrary AppX packages, Windows packages, and Windows features
- Customize the registry in the image to disable most telemetry and some unsavory features
- Populate a very basic autounattend.xml to allow the admin to run arbitrary PowerShell from their removable disks
- Create stub PowerShell scripts to run further customization after initial installation

Additionally, includes a runner to customize a directory of ISOs and a scriptlet to register a scheduled task to run said runner.

## Usage

Call the script, specifying a Windows Recovery Environment "Winre.wim" file, working directory, configuration file, and output file (ISO) path.

```PowerShell
.\Customize-Iso.ps1 `
  -IsoPath 'C:\ISOs\Windows\w10-22h2-25h2\Windows11Professional,version24H2.iso' `
  -WinREWimPath C:\ISOs\Windows\Winre.wim `
  -WorkingDir C:\CustomizeIso2 `
  -ConfigFile .\config.json `
  -OutPath C:\CustomizeIso\Autologon-script
```

## Registering the script as a scheduled task

You will likely want to customize the `runner.ps1` script for your environment.

TODO:
