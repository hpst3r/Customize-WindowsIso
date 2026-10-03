#Requires -Version 5.1

<#
.SYNOPSIS
Writes index.html and index.json describing the customized ISOs in a directory.

.DESCRIPTION
Built from the manifests Customize-Iso.ps1 writes beside each ISO: editions and
versions, build date, size, SHA-256, removed packages, drivers, warnings, the
kept previous ISO (<name>.previous.iso), and postinstall.iso. With
-SourceDirectory it adds the source build from Get-WindowsIso's <name>.iso.json,
and with -RunSummaryPath (last-run-runner.json) each image's status in the last run.

The page is self-contained (no external resources) and works on a phone. Both
files are written beside the target and then swapped in, so a client never
reads half a file. runner.ps1 calls this at the end of every run.

Exit code is 0 on success and 1 on failure.

.EXAMPLE
.\New-ImageIndex.ps1 -OutputDirectory Y:\Images\Customized -SourceDirectory Y:\Images\Standard
#>
param (
  [Parameter(Mandatory = $true)]
  [string] $OutputDirectory,
  # Get-WindowsIso's output, for the source build of each image
  [string] $SourceDirectory,
  # runner.ps1's last-run-runner.json, for each image's status in the last run
  [string] $RunSummaryPath,
  [string] $Title = 'Windows images'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue($Object, [string] $Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}

function Read-JsonFile([string] $Path) {
  if (-not $Path -or -not (Test-Path $Path)) { return $null }
  try { Get-Content -Raw $Path | ConvertFrom-Json } catch { Write-Warning "New-ImageIndex: could not read $($Path): $_"; $null }
}

function Read-Checksum([string] $IsoPath, $Manifest) {
  if (Test-Path "$IsoPath.sha256.txt") { return (Get-Content -Raw "$IsoPath.sha256.txt").Trim() }
  Get-ConfigValue $Manifest 'checksum'
}

# Everything known about one published ISO
function Get-IsoEntry([System.IO.FileInfo] $File) {
  $Manifest = Read-JsonFile "$($File.FullName).json"
  [PSCustomObject]@{
    file          = $File.Name
    size          = $File.Length
    modified      = $File.LastWriteTime.ToString('o')
    sha256        = Read-Checksum $File.FullName $Manifest
    hasManifest   = [bool]$Manifest
    built         = Get-ConfigValue $Manifest 'built'
    scriptVersion = Get-ConfigValue $Manifest 'version'
    format        = Get-ConfigValue $Manifest 'format'
    images        = @(Get-ConfigValue $Manifest 'images' @() | ForEach-Object {
        [PSCustomObject]@{ index = Get-ConfigValue $_ 'Index'; name = Get-ConfigValue $_ 'Name'; version = Get-ConfigValue $_ 'Version' }
      })
    removed       = @(Get-ConfigValue $Manifest 'removed' @())
    virtio        = Get-ConfigValue $Manifest 'virtio'
    drivers       = @(Get-ConfigValue $Manifest 'drivers' @())
    warnings      = @(Get-ConfigValue $Manifest 'warnings' @())
    minutes       = Get-ConfigValue $Manifest 'elapsed'
  }
}

#region html

function ConvertTo-Html([string] $Text) { [System.Net.WebUtility]::HtmlEncode($Text) }

function Format-Size([double] $Bytes) {
  if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) }
}

function Format-Date($Value) {
  if (-not $Value) { return '' }
  try { ([datetime]::Parse($Value)).ToString('yyyy-MM-dd HH:mm') } catch { "$Value" }
}

function Get-Badge([string] $Result) {
  $Class = switch ($Result) { 'Built' { 'ok' } 'UpToDate' { 'ok' } 'Stale' { 'warn' } '' { '' } default { 'bad' } }
  $Label = switch ($Result) { 'UpToDate' { 'up to date' } 'Built' { 'rebuilt' } default { $Result.ToLowerInvariant() } }
  if ($Result) { "<span class=`"badge $Class`">$(ConvertTo-Html $Label)</span>" }
}

# <details> with a list, or a plain line when the list is empty
function New-ListBlock([string] $Label, [object[]] $Items, [string] $Class = '') {
  if (-not $Items) { return "<p class=`"line`">$(ConvertTo-Html $Label): none</p>" }
  $Li = ($Items | ForEach-Object { "<li>$(ConvertTo-Html "$_")</li>" }) -join ''
  "<details class=`"$Class`"><summary>$(ConvertTo-Html $Label): $($Items.Count)</summary><ul>$Li</ul></details>"
}

function New-ShaLine([string] $Sha) {
  if ($Sha) { '<p class="line">SHA-256 <code>' + (ConvertTo-Html $Sha) + '</code></p>' }
}

function New-ImageCard($Entry) {
  $Name = ConvertTo-Html $Entry.file
  $Href = if ($null -ne $Entry.size) { "<a href=`"$([Uri]::EscapeDataString($Entry.file))`">$Name</a>" } else { $Name }
  $Status = Get-ConfigValue $Entry.lastRun 'result' ''
  $Parts = @(
    (Get-ConfigValue $Entry.source 'name'),
    $(if (Get-ConfigValue $Entry.source 'build') { "build $($Entry.source.build)" }),
    $(if ($null -ne $Entry.size) { Format-Size $Entry.size }),
    $(if ($Entry.built) { "built $(Format-Date $Entry.built)" })
  ) | Where-Object { $_ }

  $Html = [System.Collections.Generic.List[string]]::new()
  $Html.Add("<section class=`"card`"><h2>$Href $(Get-Badge $Status)</h2>")
  if ($Parts) { $Html.Add("<p class=`"meta`">$(ConvertTo-Html ($Parts -join ' | '))</p>") }
  if ($Status -and $Status -notin 'Built', 'UpToDate') { $Html.Add("<p class=`"note $(if ($Status -eq 'Stale') { 'warn' } else { 'bad' })`">$(ConvertTo-Html $Entry.lastRun.status)</p>") }

  if ($null -eq $Entry.size) { $Html.Add('<p class="line">Not built yet.</p></section>'); return $Html -join "`n" }
  if (-not $Entry.hasManifest) { $Html.Add('<p class="note warn">No manifest: not built by Customize-Iso, or its last publish was interrupted.</p>') }

  if ($Entry.images) {
    $Rows = ($Entry.images | ForEach-Object { "<tr><td>$($_.index)</td><td>$(ConvertTo-Html $_.name)</td><td>$(ConvertTo-Html $_.version)</td></tr>" }) -join ''
    $Html.Add("<table><thead><tr><th>#</th><th>Edition</th><th>Version</th></tr></thead><tbody>$Rows</tbody></table>")
  }
  if ($Entry.sha256) { $Html.Add((New-ShaLine $Entry.sha256)) }
  $Facts = @(
    $(if ($Entry.format) { "format $($Entry.format)" }),
    $(if ($Entry.virtio) { "drivers from $($Entry.virtio)" }),
    $(if ($Entry.scriptVersion) { "Customize-Iso $($Entry.scriptVersion)" }),
    $(if ($Entry.minutes) { "$($Entry.minutes) min to build" })
  ) | Where-Object { $_ }
  if ($Facts) { $Html.Add("<p class=`"line dim`">$(ConvertTo-Html ($Facts -join ' | '))</p>") }
  $Html.Add((New-ListBlock 'Removed packages' $Entry.removed))
  $Html.Add((New-ListBlock 'Drivers added' $Entry.drivers))
  $Html.Add((New-ListBlock 'Warnings' $Entry.warnings $(if ($Entry.warnings) { 'warn' } else { '' })))

  if ($Entry.previous) {
    $P = $Entry.previous
    $Versions = @($P.images | ForEach-Object { $_.version } | Where-Object { $_ } | Sort-Object -Unique) -join ', '
    $Html.Add("<details><summary>Previous: built $(ConvertTo-Html (Format-Date $P.built))$(if ($Versions) { ", $(ConvertTo-Html $Versions)" })</summary>" +
      "<p class=`"line`"><a href=`"$([Uri]::EscapeDataString($P.file))`">$(ConvertTo-Html $P.file)</a> | $(Format-Size $P.size)</p>" +
      (New-ShaLine $P.sha256) + '</details>')
  }
  $Html.Add('</section>')
  $Html -join "`n"
}

function New-IndexHtml($Index) {
  $Run = $Index.lastRun
  $RunLine = if ($Run) {
    $Problems = @($Index.images | Where-Object { (Get-ConfigValue $_.lastRun 'result') -notin $null, 'Built', 'UpToDate' })
    $Text = "Last run $(Format-Date $Run.started) to $(Format-Date $Run.ended): " + $(if ($Run.exitCode -eq 0) { 'OK' } else { "exit code $($Run.exitCode)" })
    if ($Problems) { $Text += " ($($Problems.Count) image(s) need attention)" }
    "<p class=`"meta $(if ($Run.exitCode -eq 0) { '' } else { 'bad' })`">$(ConvertTo-Html $Text)</p>"
  }
  $Cards = @($Index.images | ForEach-Object { New-ImageCard $_ }) -join "`n"
  $Post = if ($Index.postinstall) {
    $P = $Index.postinstall
    "<section class=`"card`"><h2><a href=`"postinstall.iso`">postinstall.iso</a></h2>" +
    "<p class=`"meta`">$(ConvertTo-Html (@((Format-Size $P.size), "built $(Format-Date $P.built)", "$($P.files.Count) files", $(if ($P.virtio) { "guest tools from $($P.virtio)" })) -ne $null -join ' | '))</p>" +
    "<p class=`"line dim`">Attach as a second CD-ROM to VMs installed from these ISOs; Setup's post-install scripts run from it.</p>" +
    (New-ShaLine $P.sha256) +
    (New-ListBlock 'Files' $P.files) + '</section>'
  }

  @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(ConvertTo-Html $Index.title)</title>
<style>
:root { --bg: #f6f7f9; --card: #fff; --text: #1d2125; --dim: #5f6b76; --line: #dde1e6; --ok: #1a7f37; --warn: #9a6700; --bad: #cf222e; --code: #eef1f4; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #111418; --card: #1a1f25; --text: #e6e9ec; --dim: #98a2ad; --line: #2c333b; --ok: #3fb950; --warn: #d29922; --bad: #f85149; --code: #232a31; }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--text); font: 15px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 960px; margin: 0 auto; }
h1 { font-size: 1.4em; margin: 0 0 4px; }
h2 { font-size: 1.05em; margin: 0 0 6px; overflow-wrap: anywhere; }
a { color: inherit; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; margin: 12px 0; }
.meta { color: var(--dim); margin: 0 0 8px; }
.line { margin: 6px 0; }
.dim { color: var(--dim); }
.note { margin: 6px 0; font-weight: 600; }
.ok { color: var(--ok); } .warn { color: var(--warn); } .bad { color: var(--bad); }
.badge { display: inline-block; font-size: 0.75em; font-weight: 600; padding: 1px 8px; border-radius: 10px; border: 1px solid currentColor; vertical-align: middle; }
code { background: var(--code); padding: 1px 4px; border-radius: 4px; font-size: 0.85em; word-break: break-all; }
table { border-collapse: collapse; width: 100%; margin: 6px 0; }
th, td { text-align: left; padding: 4px 6px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--dim); font-weight: 600; font-size: 0.9em; }
td:first-child, th:first-child { width: 2em; }
details { margin: 6px 0; }
summary { cursor: pointer; }
ul { margin: 4px 0; padding-left: 20px; overflow-wrap: anywhere; }
footer { color: var(--dim); font-size: 0.85em; margin-top: 16px; }
</style>
</head>
<body>
<main>
<h1>$(ConvertTo-Html $Index.title)</h1>
<p class="meta">$(ConvertTo-Html "$($Index.images.Count) image(s), generated $(Format-Date $Index.generated)")</p>
$RunLine
$Cards
$Post
<footer>Generated by New-ImageIndex.ps1 from the manifests beside each ISO. Machine-readable: <a href="index.json">index.json</a>.</footer>
</main>
</body>
</html>
"@
}

#endregion

# write beside the target, then swap it in
function Write-Atomic([string] $Path, [string] $Text) {
  $Temporary = "$Path.tmp"
  [System.IO.File]::WriteAllText($Temporary, $Text, (New-Object System.Text.UTF8Encoding($false)))
  # [NullString]: PowerShell would pass $null as "" (no backup file wanted)
  if (Test-Path $Path) { [System.IO.File]::Replace($Temporary, $Path, [NullString]::Value) } else { Move-Item $Temporary $Path }
}

$ExitCode = 1
try {
  if (-not (Test-Path $OutputDirectory -PathType Container)) { throw "New-ImageIndex: $OutputDirectory does not exist." }
  $Summary = Read-JsonFile $RunSummaryPath
  $RunItems = @(Get-ConfigValue $Summary 'items' @())

  $Files = @(Get-ChildItem -Path $OutputDirectory -Filter '*.iso' -File |
      Where-Object { $_.Extension -eq '.iso' -and $_.Name -notlike '*.previous.iso' -and $_.Name -ne 'postinstall.iso' } | Sort-Object Name)

  $Images = [System.Collections.Generic.List[object]]::new()
  foreach ($File in $Files) {
    $Entry = Get-IsoEntry $File
    $PreviousFile = Join-Path $OutputDirectory "$($File.BaseName).previous.iso"
    $Previous = if (Test-Path $PreviousFile) { Get-IsoEntry (Get-Item $PreviousFile) }
    $Entry | Add-Member -NotePropertyName previous -NotePropertyValue $(if ($Previous) {
        [PSCustomObject]@{ file = $Previous.file; size = $Previous.size; built = $Previous.built; sha256 = $Previous.sha256; images = $Previous.images }
      })
    $Images.Add($Entry)
  }
  # images the last run reported on that have no ISO yet (e.g. a first build that failed)
  foreach ($Item in $RunItems) {
    if ($Item.name -like '*.iso' -and $Item.name -ne 'postinstall.iso' -and -not ($Images | Where-Object file -eq $Item.name)) {
      $Images.Add([PSCustomObject]@{ file = $Item.name; size = $null; hasManifest = $false; built = $null; images = @(); previous = $null })
    }
  }
  foreach ($Entry in $Images) {
    $Source = if ($SourceDirectory) { Read-JsonFile (Join-Path $SourceDirectory "$($Entry.file).json") }
    $Entry | Add-Member -NotePropertyName source -NotePropertyValue $(if ($Source) {
        [PSCustomObject]@{ name = Get-ConfigValue $Source 'name'; title = Get-ConfigValue $Source 'title'; build = Get-ConfigValue $Source 'build' }
      })
    $Item = $RunItems | Where-Object name -eq $Entry.file | Select-Object -First 1
    $Entry | Add-Member -NotePropertyName lastRun -NotePropertyValue $(if ($Item) {
        [PSCustomObject]@{ result = Get-ConfigValue $Item 'result'; status = Get-ConfigValue $Item 'status' }
      })
  }
  $Images = @($Images | Sort-Object file)

  $PostinstallPath = Join-Path $OutputDirectory 'postinstall.iso'
  $Postinstall = if (Test-Path $PostinstallPath) {
    $Manifest = Read-JsonFile "$PostinstallPath.json"
    [PSCustomObject]@{
      file   = 'postinstall.iso'
      size   = (Get-Item $PostinstallPath).Length
      built  = Get-ConfigValue $Manifest 'built'
      # small enough to hash every time; it has no .sha256.txt
      sha256 = (Get-FileHash -Algorithm SHA256 $PostinstallPath).Hash.ToLowerInvariant()
      virtio = Get-ConfigValue $Manifest 'virtio'
      files  = @(Get-ConfigValue $Manifest 'files' @())
    }
  }

  $Index = [PSCustomObject]@{
    title       = $Title
    generated   = (Get-Date).ToString('o')
    lastRun     = if ($Summary) { [PSCustomObject]@{ started = $Summary.started; ended = $Summary.ended; exitCode = $Summary.exitCode } } else { $null }
    images      = $Images
    postinstall = $Postinstall
  }

  Write-Atomic (Join-Path $OutputDirectory 'index.json') ($Index | ConvertTo-Json -Depth 6)
  Write-Atomic (Join-Path $OutputDirectory 'index.html') (New-IndexHtml $Index)
  Write-Host "New-ImageIndex: wrote index.html and index.json ($($Images.Count) image(s)) in $OutputDirectory."
  $ExitCode = 0
}
catch {
  Write-Host "New-ImageIndex: FAILED: $_"
}

exit $ExitCode
