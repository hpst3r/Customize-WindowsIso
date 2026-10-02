# Runs post-install scripts from a .postinstall\oobe directory at the root of any filesystem drive.
#
# Each subfolder is a client (and may have its own subfolders, e.g. sites). The stub shows them
# as a tree, and picking a folder runs the scripts in every folder on the way down to it:
#
#   .postinstall\oobe\        01-common.ps1, ...   always run
#     ClientA\                01-join-domain.ps1   run for ClientA and anything under it
#       Site1\                01-printers.ps1      run for ClientA\Site1 only
#     ClientB\
#
# Scripts in a folder run sorted by name (01-setup.ps1, 02-configure.ps1, ...). With no
# subfolders, or no console to show the menu on, only the top-level scripts run.

# Search for a .postinstall directory at the root of all filesystem drives
$PostinstallDirectoryRoot = Get-PSDrive -PSProvider FileSystem |
Where-Object { Test-Path "$($_.Root).postinstall\oobe" } |
Select-Object -ExpandProperty Root -First 1

# build the folder tree; folders with no scripts anywhere below them are left out
function Get-FolderNode([System.IO.DirectoryInfo] $Folder, $Parent) {
  $Node = [PSCustomObject]@{
    Name     = $Folder.Name
    Path     = $Folder.FullName
    Parent   = $Parent
    Depth    = if ($Parent) { $Parent.Depth + 1 } else { 0 }
    Expanded = -not $Parent
    Children = New-Object System.Collections.Generic.List[object]
    # -Filter *.ps1 also matches *.ps1xml, so check the extension too
    Scripts  = @(Get-ChildItem -LiteralPath $Folder.FullName -Filter *.ps1 -File | Where-Object Extension -eq '.ps1' | Sort-Object Name)
  }
  foreach ($Child in Get-ChildItem -LiteralPath $Folder.FullName -Directory | Sort-Object Name) {
    $ChildNode = Get-FolderNode $Child $Node
    if ($ChildNode) { $Node.Children.Add($ChildNode) }
  }
  if (-not $Parent -or $Node.Scripts.Count -or $Node.Children.Count) { $Node }
}

function Get-VisibleNodes($Node) {
  $Node
  if ($Node.Expanded) { foreach ($Child in $Node.Children) { Get-VisibleNodes $Child } }
}

# the folders whose scripts run when $Node is picked, top-level first
function Get-NodeChain($Node) {
  $Chain = @()
  while ($Node) { $Chain = @($Node) + $Chain; $Node = $Node.Parent }
  $Chain
}

function Show-Tree($Visible, [int] $Index) {
  Clear-Host
  Write-Host 'Pick the client to set up this machine for.' -ForegroundColor Cyan
  Write-Host 'Up/Down: move   Right/Left: expand/collapse   letter: jump   Enter: select   Esc: run nothing' -ForegroundColor DarkGray
  Write-Host ''

  # scroll so the highlighted line stays on screen
  $Height = [Math]::Max(5, $Host.UI.RawUI.WindowSize.Height - 5)
  $Top = [Math]::Max(0, $Index - $Height + 1)
  for ($i = $Top; $i -lt [Math]::Min($Visible.Count, $Top + $Height); $i++) {
    $Node = $Visible[$i]
    $Marker = if (-not $Node.Children.Count -or $Node.Depth -eq 0) { ' ' } elseif ($Node.Expanded) { '-' } else { '+' }
    $Label = if ($Node.Depth -eq 0) { '(common scripts only)' } else { $Node.Name }
    $Line = '{0}{1} {2}  [{3}]' -f ('    ' * $Node.Depth), $Marker, $Label, $Node.Scripts.Count
    if ($i -eq $Index) { Write-Host "> $Line" -ForegroundColor Black -BackgroundColor Gray }
    else { Write-Host "  $Line" }
  }
}

function Confirm-Selection($Node) {
  Clear-Host
  $Chain = @(Get-NodeChain $Node)
  Write-Host "Scripts that will run for '$(($Chain | Select-Object -Skip 1 | ForEach-Object Name) -join '\')', in order:" -ForegroundColor Cyan
  $Scripts = @($Chain | ForEach-Object { $_.Scripts })
  foreach ($Script in $Scripts) { Write-Host "  $($Script.FullName.Substring($Chain[0].Path.Length + 1))" }
  if (-not $Scripts.Count) { Write-Host '  (none)' }
  Write-Host ''
  Write-Host 'Enter: run   any other key: go back' -ForegroundColor DarkGray
  [Console]::ReadKey($true).Key -eq 'Enter'
}

# returns the picked folder's node, or $null if the admin chose to run nothing
function Select-Folder($Root) {
  $Index = 0
  while ($true) {
    $Visible = @(Get-VisibleNodes $Root)
    $Index = [Math]::Min($Index, $Visible.Count - 1)
    Show-Tree $Visible $Index
    $Node = $Visible[$Index]
    $Key = [Console]::ReadKey($true)

    switch ($Key.Key) {
      'UpArrow' { if ($Index -gt 0) { $Index-- } }
      'DownArrow' { if ($Index -lt $Visible.Count - 1) { $Index++ } }
      'Home' { $Index = 0 }
      'End' { $Index = $Visible.Count - 1 }
      'RightArrow' {
        if ($Node.Children.Count) { if ($Node.Expanded) { $Index++ } else { $Node.Expanded = $true } }
      }
      'LeftArrow' {
        if ($Node.Expanded -and $Node.Depth -gt 0) { $Node.Expanded = $false }
        elseif ($Node.Parent) { $Index = [Array]::IndexOf($Visible, $Node.Parent) }
      }
      'Enter' { if (Confirm-Selection $Node) { return $Node } }
      'Escape' { return $null }
      default {
        # jump to the next visible folder starting with the typed letter
        if ([char]::IsLetterOrDigit($Key.KeyChar)) {
          for ($Step = 1; $Step -le $Visible.Count; $Step++) {
            $Next = ($Index + $Step) % $Visible.Count
            if ($Visible[$Next].Depth -gt 0 -and $Visible[$Next].Name -like "$($Key.KeyChar)*") { $Index = $Next; break }
          }
        }
      }
    }
  }
}

if ($PostinstallDirectoryRoot) {

  $PostinstallDirectory = "$PostinstallDirectoryRoot.postinstall\oobe"

  Write-Host "Found .postinstall directory: '$($PostinstallDirectory)'" -ForegroundColor Green

  $Root = Get-FolderNode (Get-Item -LiteralPath $PostinstallDirectory) $null
  $Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
  $Selected = if ($Root.Children.Count -and $Interactive) { Select-Folder $Root } else { $Root }

  if ($null -eq $Selected) {
    Write-Host 'No client selected; not running any post-install scripts.' -ForegroundColor Yellow
  }

  foreach ($Script in @(Get-NodeChain $Selected | ForEach-Object { $_.Scripts })) {
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
