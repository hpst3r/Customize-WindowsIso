#Requires -Version 5.1

<#
.SYNOPSIS
Sends one notification summarizing the weekly build: Get-WindowsIso's stub.ps1
and runner.ps1, from their run summaries.

.DESCRIPTION
Runs as the last action of the weekly task (see register-task.ps1). Channels are
configured in notify.json next to this script (copy notify.example.json); each
is optional and has Send = "Always" or "OnlyOnFailure". OnlyOnFailure sends when
the outcome is anything but OK, i.e. also when images need action (stale).

  ntfy:  POSTs to <Server> (default https://ntfy.sh) for <Topic>, with an access
         token if one is stored (Set-NotificationSecret.ps1 -Name NtfyToken).
  Email: through an authenticated SMTP relay (Microsoft 365, SES, ...) with
         STARTTLS. The password is stored with Set-NotificationSecret.ps1
         -Name SmtpPassword, encrypted with DPAPI (LocalMachine scope) in
         notify.secrets.json, so the SYSTEM task can read it but a copy of the
         file is useless on another machine.

A summary that is missing, or older than MaxSummaryAgeHours, is reported as a
failure: that stage didn't finish (or didn't run).

Exit code is 0 if notifications were sent, nothing needed sending, or nothing is
configured; 1 if every channel that tried to send failed, or notify.json is invalid.

.EXAMPLE
.\Send-BuildNotification.ps1 -StubSummaryPath Y:\src\Get-WindowsIso\logs\last-run-stub.json

.EXAMPLE
# send a test message on every enabled channel, ignoring OnlyOnFailure
.\Send-BuildNotification.ps1 -Test
#>
param (
  # default: notify.json next to this script
  [string] $ConfigFile,
  # default: StubSummaryPath in notify.json; without either, the stub is left out
  [string] $StubSummaryPath,
  # default: RunnerSummaryPath in notify.json, else last-run-runner.json in runner-config.json's LogDirectory
  [string] $RunnerSummaryPath,
  # default: runner-config.json next to this script
  [string] $RunnerConfigFile,
  # send on every enabled channel regardless of Send, with "[test]" in the title
  [switch] $Test,
  # print the message instead of sending it
  [switch] $DryRun
)

# $PSScriptRoot is empty in parameter defaults in Windows PowerShell
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'notify.json' }
if (-not $RunnerConfigFile) { $RunnerConfigFile = Join-Path $PSScriptRoot 'runner-config.json' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-ConfigValue($Object, [string] $Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}

# notify.json -> notify.secrets.json
function Get-SecretsPath([string] $Path) {
  Join-Path (Split-Path $Path) ([System.IO.Path]::GetFileNameWithoutExtension($Path) + '.secrets.json')
}

# Decrypt a secret stored by Set-NotificationSecret.ps1, or $null if there is none
function Get-Secret([string] $Name) {
  $Path = Get-SecretsPath $ConfigFile
  if (-not (Test-Path $Path)) { return $null }
  $Blob = Get-ConfigValue (Get-Content -Raw $Path | ConvertFrom-Json) $Name
  if (-not $Blob) { return $null }
  Add-Type -AssemblyName System.Security
  try {
    $Bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Blob), $null, 'LocalMachine')
  }
  catch {
    # don't echo the blob; the usual cause is a file copied from another machine
    throw "could not decrypt $Name from $Path (stored on another machine?). Store it again with Set-NotificationSecret.ps1."
  }
  [System.Text.Encoding]::UTF8.GetString($Bytes)
}

#region summaries

# A stage's summary, or a stand-in describing why it is missing
function Read-Summary([string] $Stage, [string] $Path, [double] $MaxAgeHours) {
  $Problem = $null
  $Summary = $null
  if (-not (Test-Path $Path)) { $Problem = "no run summary at $Path" }
  else {
    try {
      $Summary = Get-Content -Raw $Path | ConvertFrom-Json
      $Ended = [datetime]::Parse($Summary.ended)
      [datetime]::Parse($Summary.started) | Out-Null
      if (((Get-Date) - $Ended).TotalHours -gt $MaxAgeHours) {
        $Problem = "last run summary is from $($Ended.ToString('yyyy-MM-dd HH:mm')) - this run didn't finish or didn't run"
      }
    }
    catch { $Summary = $null; $Problem = "unreadable run summary $($Path): $_" }
  }
  [PSCustomObject]@{ Stage = $Stage; Path = $Path; Summary = $Summary; Problem = $Problem }
}

function Get-Items($Stage) {
  if ($Stage.Problem -or -not $Stage.Summary) { return @() }
  @(Get-ConfigValue $Stage.Summary 'items' @())
}

function Format-Span($Summary) {
  $Start = [datetime]::Parse($Summary.started)
  $End = [datetime]::Parse($Summary.ended)
  "$($Start.ToString('ddd HH:mm'))-$($End.ToString('HH:mm')), $([math]::Round(($End - $Start).TotalMinutes)) min"
}

# Overall outcome, title, priority, and plain-text body
function New-Report($Stages, [bool] $Detailed) {
  $Stub = @($Stages | Where-Object Stage -eq 'stub')
  $Runner = @($Stages | Where-Object Stage -eq 'runner')

  $AllItems = @($Stages | ForEach-Object { Get-Items $_ })
  $Failed = @($AllItems | Where-Object { $_.result -in 'Failed', 'Locked' })
  $Stale = @($AllItems | Where-Object { $_.result -eq 'Stale' })
  # a stage that died (error), didn't report, or exited non-zero without saying why
  $StageProblems = @($Stages | Where-Object {
      $_.Problem -or (Get-ConfigValue $_.Summary 'error') -or
      ((Get-ConfigValue $_.Summary 'exitCode' 0) -ne 0 -and -not @(Get-Items $_ | Where-Object { $_.result -in 'Failed', 'Locked', 'Stale' }).Count)
    })
  $Rebuilt = @($Runner | ForEach-Object { Get-Items $_ } | Where-Object { $_.result -eq 'Built' -and $_.name -like '*.iso' -and $_.name -notlike 'postinstall*.iso' })
  $NewBuilds = @($Stub | ForEach-Object { Get-Items $_ } | Where-Object result -eq 'Published')

  $Outcome = if ($Failed.Count -or $StageProblems.Count) { 'FAILED' } elseif ($Stale.Count) { 'ACTION NEEDED' } else { 'OK' }

  $Counts = @()
  if ($Failed.Count -or $StageProblems.Count) { $Counts += "$($Failed.Count + $StageProblems.Count) failed" }
  if ($Stale.Count) { $Counts += "$($Stale.Count) stale" }
  if ($Rebuilt.Count) { $Counts += "$($Rebuilt.Count) rebuilt" }
  if (-not $Counts) { $Counts += 'no changes' }
  $Title = "Windows images: $Outcome ($($Counts -join ', '))"

  $Lines = [System.Collections.Generic.List[string]]::new()
  foreach ($Stage in $Stages) {
    $Name = if ($Stage.Stage -eq 'stub') { 'Get-WindowsIso' } else { 'Customize-WindowsIso' }
    if ($Stage.Problem) {
      $Lines.Add("$($Name): FAILED - $($Stage.Problem)")
      $Lines.Add('')
      continue
    }
    $S = $Stage.Summary
    $Items = @(Get-Items $Stage)
    $Labels = [ordered]@{ Failed = 'failed'; Locked = 'locked'; Stale = 'stale'; Published = 'new'; Built = 'rebuilt'; UpToDate = 'up to date' }
    $StageCounts = @(foreach ($Result in $Labels.Keys) {
        $Count = @($Items | Where-Object result -eq $Result).Count
        if ($Count) { "$Count $($Labels[$Result])" }
      })
    if (-not $StageCounts) { $StageCounts = @('nothing to do') }
    $Exit = if ($S.exitCode -ne 0) { ", exit $($S.exitCode)" } else { '' }
    $Lines.Add("$($Name) ($(Format-Span $S)$Exit): $($StageCounts -join ', ')")
    if (Get-ConfigValue $S 'error') { $Lines.Add("  ERROR: $($S.error)") }

    foreach ($Item in $Items) {
      if ($Item.result -eq 'UpToDate' -and -not $Detailed) { continue }
      $Line = switch ($Item.result) {
        'Published' {
          $From = if (Get-ConfigValue $Item 'previousBuild') { "$($Item.previousBuild) -> " } else { '' }
          "  NEW    $($Item.name): $From$($Item.build) ($($Item.minutes) min)"
        }
        'Built' {
          $Versions = @(Get-ConfigValue $Item 'imageVersions' @()) -join ', '
          $Detail = @(if ($Versions) { $Versions }; "$($Item.minutes) min"; "$($Item.warnings) warning(s)") -join ', '
          "  BUILT  $($Item.name): $Detail"
        }
        'UpToDate' {
          $Build = @(Get-ConfigValue $Item 'build'; @(Get-ConfigValue $Item 'imageVersions' @()) -join ', ') | Where-Object { $_ } | Select-Object -First 1
          "  OK     $($Item.name)$(if ($Build) { ": $Build" })"
        }
        'Stale' { "  STALE  $($Item.name): $($Item.status -replace '^Stale:\s*', '')" }
        default { "  FAILED $($Item.name): $($Item.status)$(if ($Item.minutes) { " after $($Item.minutes) min" })" }
      }
      $Lines.Add($Line)
      if ($Detailed -and $Item.result -eq 'Built') {
        foreach ($Warning in @(Get-ConfigValue $Item 'warningMessages' @())) { $Lines.Add("           warning: $Warning") }
      }
    }
    $Lines.Add('')
  }

  $WarningCount = 0
  foreach ($Item in $Rebuilt) { $WarningCount += [int](Get-ConfigValue $Item 'warnings' 0) }
  if ($NewBuilds.Count) { $Lines.Add("New Windows builds: $(@($NewBuilds | ForEach-Object { "$($_.name) $($_.build)" }) -join '; ')") }
  $Lines.Add("Warnings in rebuilt images: $([int]$WarningCount)")
  foreach ($Stage in $Stages) {
    if ($Stage.Summary) { $Lines.Add("Log ($($Stage.Stage)): $($Stage.Summary.logFile)") }
  }

  $Priority, $Tags = switch ($Outcome) {
    'FAILED' { 4, @('x') }
    'ACTION NEEDED' { 4, @('warning') }
    default { if ($Rebuilt.Count -or $NewBuilds.Count) { 3, @('white_check_mark') } else { 2, @('white_check_mark') } }
  }

  [PSCustomObject]@{ Outcome = $Outcome; Title = $Title; Body = ($Lines -join "`n").TrimEnd(); Priority = $Priority; Tags = $Tags }
}

#endregion

#region channels

function Send-Ntfy($Channel, $Report, [string] $Link) {
  $Server = "$(Get-ConfigValue $Channel 'Server' 'https://ntfy.sh')".TrimEnd('/')
  $Topic = Get-ConfigValue $Channel 'Topic'
  if (-not $Topic) { throw 'Ntfy.Topic is not set.' }

  # JSON publishing keeps UTF-8 titles intact (headers would need RFC 2047)
  $Message = [ordered]@{ topic = $Topic; title = $Report.Title; message = $Report.Body; priority = $Report.Priority; tags = @($Report.Tags) }
  if ($Link) { $Message.click = $Link }
  $Headers = @{}
  $Token = Get-Secret 'NtfyToken'
  if ($Token) { $Headers.Authorization = "Bearer $Token" }

  $Body = [System.Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Depth 3))
  Invoke-RestMethod -Method Post -Uri $Server -Headers $Headers -Body $Body -ContentType 'application/json; charset=utf-8' -TimeoutSec 60 | Out-Null
  "ntfy: sent to $Server/$Topic$(if ($Token) { ' (with token)' })."
}

function Send-Email($Channel, $Report) {
  $SmtpServer = Get-ConfigValue $Channel 'SmtpServer'
  $Security = "$(Get-ConfigValue $Channel 'Security' 'StartTls')"
  $From = Get-ConfigValue $Channel 'From'
  $To = @(Get-ConfigValue $Channel 'To' @() | Where-Object { $_ })
  $Username = Get-ConfigValue $Channel 'Username'
  if (-not $SmtpServer -or -not $From -or -not $To) { throw 'Email needs SmtpServer, From and To.' }
  # System.Net.Mail only does STARTTLS ("explicit" TLS, usually port 587), not TLS-on-connect (465)
  if ($Security -notin 'StartTls', 'None') { throw "Email.Security must be StartTls or None, not '$Security' (TLS on connect / port 465 isn't supported by System.Net.Mail; use port 587 with StartTls)." }
  $Port = [int](Get-ConfigValue $Channel 'Port' $(if ($Security -eq 'StartTls') { 587 } else { 25 }))

  $Client = New-Object System.Net.Mail.SmtpClient($SmtpServer, $Port)
  $Message = New-Object System.Net.Mail.MailMessage
  try {
    $Client.EnableSsl = $Security -eq 'StartTls'
    $Client.Timeout = 60000
    if ($Username) {
      $Password = Get-Secret 'SmtpPassword'
      if ($null -eq $Password) { throw "Email.Username is set but no SmtpPassword is stored. Run Set-NotificationSecret.ps1 -Name SmtpPassword." }
      if ($Security -eq 'None') { Write-Warning 'email: Security is None - the password is sent unencrypted.' }
      $Client.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
    }
    $Message.From = $From
    foreach ($Address in $To) { $Message.To.Add($Address) }
    $Message.Subject = $Report.Title
    $Message.SubjectEncoding = [System.Text.Encoding]::UTF8
    $Message.Body = $Report.Body
    $Message.BodyEncoding = [System.Text.Encoding]::UTF8
    $Client.Send($Message)
  }
  finally {
    $Message.Dispose()
    $Client.Dispose()
  }
  "email: sent to $($To -join ', ') via $($SmtpServer):$Port ($Security)."
}

#endregion

$ExitCode = 1
$RunnerConfig = if (Test-Path $RunnerConfigFile) { Get-Content -Raw $RunnerConfigFile | ConvertFrom-Json } else { $null }
$LogDir = Get-ConfigValue $RunnerConfig 'LogDirectory' (Join-Path $PSScriptRoot 'logs')
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir "notify-$(Get-Date -Format yyyyMMdd-HHmmss).log") | Out-Null

try {
  if (-not (Test-Path $ConfigFile)) {
    Write-Host "notify: $ConfigFile not found; no notifications configured (copy notify.example.json to set them up)."
    $ExitCode = 0
  }
  else {
    $Config = Get-Content -Raw $ConfigFile | ConvertFrom-Json
    # TLS 1.2 isn't on by default for .NET Framework 4.x clients
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (-not $StubSummaryPath) { $StubSummaryPath = Get-ConfigValue $Config 'StubSummaryPath' '' }
    if (-not $RunnerSummaryPath) { $RunnerSummaryPath = Get-ConfigValue $Config 'RunnerSummaryPath' (Join-Path $LogDir 'last-run-runner.json') }
    $MaxAge = [double](Get-ConfigValue $Config 'MaxSummaryAgeHours' 24)

    $Stages = @(
      if ($StubSummaryPath) { Read-Summary 'stub' $StubSummaryPath $MaxAge }
      Read-Summary 'runner' $RunnerSummaryPath $MaxAge
    )

    $Channels = @(
      foreach ($Name in 'Ntfy', 'Email') {
        $Channel = Get-ConfigValue $Config $Name
        if ($Channel -and (Get-ConfigValue $Channel 'Enabled' $true)) {
          $Send = "$(Get-ConfigValue $Channel 'Send' 'Always')"
          if ($Send -notin 'Always', 'OnlyOnFailure') { throw "$Name.Send must be Always or OnlyOnFailure, not '$Send'." }
          [PSCustomObject]@{ Name = $Name; Config = $Channel; Send = $Send }
        }
      })

    $Report = New-Report $Stages $false
    $Detailed = New-Report $Stages $true
    if ($Test) { $Report.Title = "[test] $($Report.Title)"; $Detailed.Title = $Report.Title }
    Write-Host "notify: $($Report.Title)"
    Write-Host $Report.Body

    if (-not $Channels) { Write-Host 'notify: no channels enabled in notify.json.' }
    $Attempted = 0
    $Sent = 0
    foreach ($Channel in $Channels) {
      if ($Channel.Send -eq 'OnlyOnFailure' -and $Report.Outcome -eq 'OK' -and -not $Test) {
        Write-Host "notify: $($Channel.Name) only sends on failure; outcome is OK."
        continue
      }
      if ($DryRun) { Write-Host "notify: (dry run) would send via $($Channel.Name)."; continue }
      $Attempted++
      try {
        $Result = switch ($Channel.Name) {
          'Ntfy' { Send-Ntfy $Channel.Config $Report (Get-ConfigValue $Config 'Link') }
          # email has room for every item and the warning messages
          'Email' { Send-Email $Channel.Config $Detailed }
        }
        Write-Host "notify: $Result"
        $Sent++
      }
      catch { Write-Warning "notify: $($Channel.Name) failed: $($_.Exception.Message)" }
    }
    $ExitCode = if ($Attempted -and -not $Sent) { 1 } else { 0 }
  }
}
catch {
  Write-Host "notify: FAILED: $_"
}
finally {
  Stop-Transcript | Out-Null
}

exit $ExitCode
