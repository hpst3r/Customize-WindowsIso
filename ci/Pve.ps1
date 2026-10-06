# Proxmox VE over SSH, for the install tests. Dot-sourced by Test-IsoOnPve.ps1 and
# Invoke-ImageTests.ps1, after $Ci (ci-config.json) is loaded.
#
# Everything goes through ssh.exe/scp.exe with a dedicated key and a pinned host key
# (StrictHostKeyChecking=yes against ci-config's KnownHostsFile): qm/pvesh on the node
# can do all of it, including console screenshots, which the API can't.

# run an executable, capturing stdout and stderr separately (PowerShell 5.1's 2>&1 turns
# native stderr into error records); optional text on stdin
function Invoke-Exe([string] $FilePath, [string[]] $Arguments, [string] $InputText, [int] $TimeoutSeconds = 3600) {
  $Info = New-Object System.Diagnostics.ProcessStartInfo
  $Info.FileName = $FilePath
  $Info.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' '
  $Info.UseShellExecute = $false
  $Info.RedirectStandardOutput = $true
  $Info.RedirectStandardError = $true
  $Info.RedirectStandardInput = $true
  $Info.CreateNoWindow = $true
  $Process = [System.Diagnostics.Process]::Start($Info)
  $Stdout = $Process.StandardOutput.ReadToEndAsync()
  $Stderr = $Process.StandardError.ReadToEndAsync()
  if ($InputText) {
    # LF only: the other end is Linux
    $Bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($InputText -replace "`r`n", "`n"))
    $Process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
  }
  $Process.StandardInput.Close()
  if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
    try { $Process.Kill() } catch { }
    throw "$(Split-Path -Leaf $FilePath) timed out after $TimeoutSeconds s: $($Info.Arguments)"
  }
  $Process.WaitForExit()
  [PSCustomObject]@{ ExitCode = $Process.ExitCode; Output = $Stdout.Result; Error = $Stderr.Result }
}

function Get-SshOptions {
  @('-i', $Ci.SshKey, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$($Ci.KnownHostsFile)",
    '-o', 'ConnectTimeout=20', '-o', 'ServerAliveInterval=30', '-o', 'LogLevel=ERROR')
}

# .NET Framework writes a UTF-8 BOM ahead of whatever goes to a child's stdin; remote
# commands that read stdin pipe it through this first
$StripBom = "sed '1s/^\xef\xbb\xbf//'"

# single-quote a string for the remote (bash) shell
function ConvertTo-ShellQuoted([string] $Text) { "'" + $Text.Replace("'", "'\''") + "'" }

# run a shell command on the node; returns stdout. Throws on a non-zero exit unless -AllowFailure.
function Invoke-Pve([string] $Command, [string] $InputText, [int] $TimeoutSeconds = 600, [switch] $AllowFailure, [switch] $Raw) {
  $Result = Invoke-Exe 'ssh.exe' (@(Get-SshOptions) + @("$($Ci.SshUser)@$($Ci.Host)", $Command)) -InputText $InputText -TimeoutSeconds $TimeoutSeconds
  if ($Result.ExitCode -ne 0 -and -not $AllowFailure) {
    $Shown = if ($Command.Length -gt 120) { $Command.Substring(0, 117) + '...' } else { $Command }
    throw "on $($Ci.Host): '$Shown' exited with $($Result.ExitCode): $(($Result.Error.Trim() -split "`n" | Select-Object -Last 3) -join ' | ')"
  }
  if ($Raw) { $Result } else { $Result.Output }
}

function Copy-ToPve([string] $Path, [string] $Destination, [int] $TimeoutSeconds = 3600) {
  $Result = Invoke-Exe 'scp.exe' (@(Get-SshOptions) + @('-q', $Path, "$($Ci.SshUser)@$($Ci.Host):$Destination")) -TimeoutSeconds $TimeoutSeconds
  if ($Result.ExitCode -ne 0) { throw "scp $Path -> $Destination failed ($($Result.ExitCode)): $($Result.Error.Trim())" }
}

function Copy-FromPve([string] $Path, [string] $Destination) {
  $Result = Invoke-Exe 'scp.exe' (@(Get-SshOptions) + @('-q', "$($Ci.SshUser)@$($Ci.Host):$Path", $Destination)) -TimeoutSeconds 600
  if ($Result.ExitCode -ne 0) { throw "scp $Path <- node failed ($($Result.ExitCode)): $($Result.Error.Trim())" }
}

# qm status: running, stopped, or $null when there's no such VM
function Get-VmStatus([int] $VmId) {
  $Result = Invoke-Pve "qm status $VmId" -AllowFailure -Raw
  if ($Result.ExitCode -ne 0) { return $null }
  if ($Result.Output -match 'status:\s*(\S+)') { $Matches[1] }
}

function Remove-Vm([int] $VmId) {
  if (-not (Get-VmStatus $VmId)) { return }
  Invoke-Pve "qm stop $VmId --skiplock 1 --timeout 60 >/dev/null 2>&1; qm destroy $VmId --purge 1 --destroy-unreferenced-disks 1 --skiplock 1" -TimeoutSeconds 300 | Out-Null
}

# a PNG of the VM's console, or $null if the VM isn't running or the dump failed
function Save-VmScreenshot([int] $VmId, [string] $Path) {
  $Remote = "/tmp/ci-$VmId-screen.png"
  # HMP: screendump filename [-f format]
  $Result = Invoke-Pve "rm -f $Remote; echo 'screendump $Remote -f png' | qm monitor $VmId >/dev/null 2>&1; test -s $Remote" -AllowFailure -Raw -TimeoutSeconds 60
  if ($Result.ExitCode -ne 0) { return $null }
  try { Copy-FromPve $Remote $Path; $Path } catch { $null }
  finally { Invoke-Pve "rm -f $Remote" -AllowFailure | Out-Null }
}

# true once the QEMU guest agent answers
function Test-GuestAgent([int] $VmId) {
  (Invoke-Pve "qm agent $VmId ping" -AllowFailure -Raw -TimeoutSeconds 60).ExitCode -eq 0
}

# run a PowerShell script in the guest as SYSTEM through the agent; $Script is passed as
# -EncodedCommand, so keep it small and put data in files with Write-GuestFile.
# (qm guest exec --pass-stdin times out against the Windows agent.)
function Invoke-GuestPowerShell([int] $VmId, [string] $Script, [int] $TimeoutSeconds = 600) {
  $Encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
  $Command = "qm guest exec $VmId --timeout $TimeoutSeconds -- powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $Encoded"
  $Output = Invoke-Pve $Command -TimeoutSeconds ($TimeoutSeconds + 60)
  $Result = $Output | ConvertFrom-Json
  [PSCustomObject]@{
    Exited   = [bool] (Get-CiValue $Result 'exited' $false)
    ExitCode = Get-CiValue $Result 'exitcode'
    Output   = "$(Get-CiValue $Result 'out-data' '')"
    Error    = "$(Get-CiValue $Result 'err-data' '')"
  }
}

# put text in a file in the guest, base64-encoded (decode it there); up to ~45 KB of text.
# The content goes over SSH stdin: Windows command lines stop at 32K characters.
function Write-GuestFile([int] $VmId, [string] $Path, [string] $Text) {
  $Base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
  if ($Base64.Length -gt 60000) { throw "Write-GuestFile: $Path is too big for the agent ($($Base64.Length) base64 characters, limit 60 KiB)." }
  $Command = "f=`$(mktemp); $StripBom > `$f; pvesh create /nodes/$($Ci.Node)/qemu/$VmId/agent/file-write --file $(ConvertTo-ShellQuoted $Path) --content `"`$(cat `$f)`" >/dev/null; rc=`$?; rm -f `$f; exit `$rc"
  Invoke-Pve $Command -InputText $Base64 -TimeoutSeconds 120 | Out-Null
}

# a text file from the guest (up to 16 MiB), or $null
function Read-GuestFile([int] $VmId, [string] $Path) {
  $Result = Invoke-Pve "pvesh get /nodes/$($Ci.Node)/qemu/$VmId/agent/file-read --file $(ConvertTo-ShellQuoted $Path) --output-format json" -AllowFailure -Raw -TimeoutSeconds 120
  if ($Result.ExitCode -ne 0) { return $null }
  ($Result.Output | ConvertFrom-Json).content
}

# run ci\Test-InstalledWindows.ps1 in the guest against $Expected; returns the parsed
# { checks, facts } and keeps the raw output in $RawPath
function Invoke-GuestChecks([int] $VmId, $Expected, [string] $RawPath) {
  $Dir = 'C:\ProgramData\Customize-WindowsIso\ci'
  Invoke-GuestPowerShell $VmId "New-Item -ItemType Directory -Force -Path '$Dir' | Out-Null" -TimeoutSeconds 60 | Out-Null
  Write-GuestFile $VmId "$Dir\Test-InstalledWindows.ps1.b64" (Get-Content -Raw (Join-Path $PSScriptRoot 'Test-InstalledWindows.ps1'))
  Write-GuestFile $VmId "$Dir\expected.json.b64" ($Expected | ConvertTo-Json -Depth 10)
  $Bootstrap = @"
`$Dir = '$Dir'
foreach (`$Name in 'Test-InstalledWindows.ps1', 'expected.json') {
  [IO.File]::WriteAllBytes("`$Dir\`$Name", [Convert]::FromBase64String([IO.File]::ReadAllText("`$Dir\`$Name.b64").Trim()))
}
& "`$Dir\Test-InstalledWindows.ps1" -ExpectedFile "`$Dir\expected.json"
"@
  $Exec = Invoke-GuestPowerShell $VmId $Bootstrap -TimeoutSeconds 900
  if ($RawPath) { Set-Content -Encoding utf8 $RawPath "exit: $($Exec.ExitCode)`nstdout:`n$($Exec.Output)`nstderr:`n$($Exec.Error)" }
  if (-not $Exec.Exited) { throw 'the checks did not finish in 15 minutes' }
  $Start = $Exec.Output.IndexOf('{')
  if ($Start -lt 0) { throw "the checks printed no results (exit $($Exec.ExitCode)): $(($Exec.Error -split "`n" | Select-Object -First 5) -join ' | ')" }
  $Exec.Output.Substring($Start) | ConvertFrom-Json
}

function Get-CiValue($Object, [string] $Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}
