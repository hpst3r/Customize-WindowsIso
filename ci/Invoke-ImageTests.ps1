#Requires -Version 5.1

<#
.SYNOPSIS
Install-tests the customized ISOs on the Proxmox test node, one at a time.

.DESCRIPTION
Builds the CI post-install media (New-CiMedia.ps1), then runs Test-IsoOnPve.ps1 for every
ISO in ImageDirectory (minus Exclude) - single-edition ISOs as they are, multi-edition ones
once per edition matching MultiEditionTest. A test is skipped when the same ISO (by
SHA-256) already passed, unless -Force; failed ones are tried again every run.

Writes a run summary for Send-BuildNotification.ps1 (<LogDirectory>\last-run-ci.json and
ci-<timestamp>.json, stage "ci") and keeps the test history in <WorkDirectory>\tests.json.
Exit code 0 if every test passed (or was already passed), 1 otherwise.

.EXAMPLE
.\Invoke-ImageTests.ps1                     # what changed since the last passing test
.\Invoke-ImageTests.ps1 -Force              # everything
.\Invoke-ImageTests.ps1 -Name '*26H2*'      # just these ISOs
#>
param (
  [string] $ConfigFile,
  # wildcards on the ISO file name
  [string[]] $Name = @('*'),
  [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'ci-config.json' }
$Ci = Get-Content -Raw $ConfigFile | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Pve.ps1')
$Runner = Get-Content -Raw $Ci.RunnerConfigFile | ConvertFrom-Json
$LogDir = Get-CiValue $Runner 'LogDirectory' (Join-Path (Split-Path $PSScriptRoot) 'logs')
$HistoryPath = Join-Path $Ci.WorkDirectory 'tests.json'

$Started = Get-Date
$Stamp = $Started.ToString('yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Force -Path $LogDir, $Ci.WorkDirectory, $Ci.ResultsDirectory | Out-Null
$TranscriptPath = Join-Path $LogDir "ci-$Stamp.log"
Start-Transcript -Path $TranscriptPath | Out-Null

# one test run at a time: they share the VM ID and the node
$Mutex = New-Object System.Threading.Mutex($false, 'Global\Customize-WindowsIso-ImageTests')
$Items = [System.Collections.Generic.List[object]]::new()
$ExitCode = 1
$RunError = $null
$Acquired = $false

function Write-Summary {
  $Ended = Get-Date
  $Summary = [PSCustomObject]@{
    stage    = 'ci'
    version  = $(try { git -c safe.directory='*' -C $PSScriptRoot rev-parse --short HEAD 2>$null } catch { $null })
    computer = $env:COMPUTERNAME
    started  = $Started.ToString('o')
    ended    = $Ended.ToString('o')
    minutes  = [math]::Round(($Ended - $Started).TotalMinutes, 1)
    exitCode = $ExitCode
    error    = $RunError
    logFile  = $TranscriptPath
    node     = $Ci.Host
    items    = @($Items)
  }
  $Json = $Summary | ConvertTo-Json -Depth 6
  $Utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $LogDir "ci-$Stamp.json"), $Json, $Utf8)
  $Latest = Join-Path $LogDir 'last-run-ci.json'
  [System.IO.File]::WriteAllText("$Latest.tmp", $Json, $Utf8)
  Move-Item "$Latest.tmp" $Latest -Force
}

try {
  $Acquired = try { $Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $true }
  if (-not $Acquired) { throw 'another test run is already active.' }

  $History = @{}
  if (Test-Path $HistoryPath) {
    foreach ($Property in @((Get-Content -Raw $HistoryPath | ConvertFrom-Json).PSObject.Properties)) { $History[$Property.Name] = $Property.Value }
  }

  # what to test: every edition of interest of every published ISO
  $Tests = @(foreach ($Iso in @(Get-ChildItem -LiteralPath $Ci.ImageDirectory -Filter '*.iso' -File | Sort-Object Name)) {
      if ($Iso.Extension -ne '.iso') { continue }
      if (@($Ci.Exclude | Where-Object { $Iso.Name -like $_ }).Count) { continue }
      if (-not @($Name | Where-Object { $Iso.Name -like $_ }).Count) { continue }
      $Manifest = try { Get-Content -Raw "$($Iso.FullName).json" | ConvertFrom-Json } catch { $null }
      if (-not $Manifest) { Write-Warning "ci: $($Iso.Name) has no manifest; skipped."; continue }
      $Editions = @($Manifest.images | ForEach-Object Name)
      if ($Editions.Count -gt 1) { $Editions = @($Editions | Where-Object { $E = $_; @($Ci.MultiEditionTest | Where-Object { $E -like $_ }).Count }) }
      $Sidecar = "$($Iso.FullName).sha256.txt"
      $Sha = if (Test-Path $Sidecar) { (Get-Content -Raw $Sidecar).Trim().ToLowerInvariant() } else { "$($Iso.Length):$($Iso.LastWriteTimeUtc.Ticks)" }
      foreach ($Edition in $Editions) { [PSCustomObject]@{ Iso = $Iso; Edition = $Edition; Multi = $Manifest.images.Count -gt 1; Sha = $Sha; Key = "$($Iso.Name)|$Edition" } }
    })
  Write-Host "ci: $($Tests.Count) test(s): $(@($Tests | ForEach-Object { "$($_.Iso.Name) [$($_.Edition)]" }) -join '; ')"

  $CiMedia = $null
  foreach ($Test in $Tests) {
    $Label = "$($Test.Iso.Name) [$($Test.Edition)]"
    $Previous = $History[$Test.Key]
    if (-not $Force -and $Previous -and $Previous.sha256 -eq $Test.Sha -and $Previous.result -eq 'Pass') {
      Write-Host "ci: $Label already passed on $($Previous.finished); skipped."
      $Items.Add([PSCustomObject]@{ name = $Label; result = 'UpToDate'; status = "passed $($Previous.finished)"; minutes = 0; summary = $Previous.summary; directory = $Previous.directory })
      continue
    }
    # the CI media only when there is something to test
    if (-not $CiMedia) { $CiMedia = & (Join-Path $PSScriptRoot 'New-CiMedia.ps1') -ConfigFile $ConfigFile | Select-Object -Last 1 }

    Write-Host "ci: testing $Label."
    $Arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Test-IsoOnPve.ps1')`"",
      '-IsoPath', "`"$($Test.Iso.FullName)`"", '-CiMediaPath', "`"$CiMedia`"", '-ConfigFile', "`"$ConfigFile`"")
    if ($Test.Multi) { $Arguments += @('-Edition', "`"$($Test.Edition)`"") }
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    $Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    $Minutes = [math]::Round($Watch.Elapsed.TotalMinutes, 1)

    # the newest result.json for this ISO/edition is this test's
    $ResultFile = Get-ChildItem -LiteralPath $Ci.ResultsDirectory -Directory | Sort-Object LastWriteTime -Descending |
      ForEach-Object { Join-Path $_.FullName 'result.json' } | Where-Object { Test-Path $_ } |
      Where-Object { $R = Get-Content -Raw $_ | ConvertFrom-Json; $R.iso -eq $Test.Iso.Name -and $R.edition -eq $Test.Edition -and [datetime]$R.started -ge $Started } | Select-Object -First 1
    $Result = if ($ResultFile) { Get-Content -Raw $ResultFile | ConvertFrom-Json }
    $Passed = $Process.ExitCode -eq 0 -and $Result -and $Result.result -eq 'Pass'
    $Status = if ($Passed) { "passed: $($Result.summary)" } elseif ($Result) { "$($Result.error)$(if (@($Result.checks).Count) { " ($($Result.summary))" })" } else { "Test-IsoOnPve.ps1 exited with $($Process.ExitCode) and wrote no result" }
    $Items.Add([PSCustomObject]@{
        name      = $Label
        result    = $(if ($Passed) { 'Passed' } else { 'Failed' })
        status    = $Status
        minutes   = $Minutes
        summary   = $(if ($Result) { $Result.summary })
        failures  = @(if ($Result) { $Result.checks | Where-Object result -eq 'Fail' | ForEach-Object { "$($_.name): $($_.detail)" } })
        warnings  = @(if ($Result) {
            $Result.checks | Where-Object result -eq 'Warn' | ForEach-Object { "$($_.name): $($_.detail)" }
            # the first-logon scripts' own warnings, when the checks couldn't run
            if (-not @($Result.checks).Count) { Get-CiValue $Result 'notes' @() | ForEach-Object { "first logon: $_" } }
          })
        phases    = $(if ($Result) { $Result.phases })
        directory = $(if ($Result) { $Result.directory })
        vmKept    = $(if ($Result) { $Result.vmKept } else { $false })
      })
    $History[$Test.Key] = [PSCustomObject]@{
      sha256 = $Test.Sha; result = $(if ($Passed) { 'Pass' } else { 'Fail' }); finished = (Get-Date).ToString('yyyy-MM-dd HH:mm')
      summary = $(if ($Result) { $Result.summary }); directory = $(if ($Result) { $Result.directory })
    }
    [PSCustomObject] $History | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $HistoryPath
    Write-Host "ci: $Label $(if ($Passed) { 'PASSED' } else { 'FAILED' }) in $Minutes min: $Status"
  }

  $ExitCode = if (@($Items | Where-Object result -eq 'Failed').Count) { 1 } else { 0 }
}
catch {
  $RunError = "$_"
  Write-Host "ci: FAILED: $_"
}
finally {
  Write-Host 'ci: summary:'
  $Items | Select-Object name, result, minutes, status | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
  try { Write-Summary } catch { Write-Warning "ci: could not write the run summary: $_" }
  # the share's index page shows each image's last install test
  if ($Acquired -and (Get-CiValue $Runner 'BuildIndex' $true)) {
    try {
      & (Join-Path (Split-Path $PSScriptRoot) 'New-ImageIndex.ps1') -OutputDirectory $Runner.OutputDirectory -SourceDirectory $Runner.InputDirectory `
        -RunSummaryPath (Join-Path $LogDir 'last-run-runner.json') -InstallTestsPath $HistoryPath | Write-Host
    }
    catch { Write-Warning "ci: index page: $_" }
  }
  if ($Acquired) { try { $Mutex.ReleaseMutex() } catch { } }
  Stop-Transcript | Out-Null
}

exit $ExitCode
