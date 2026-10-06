# CI only (ci\postinstall overlays the repo's .postinstall on the test media).
# Records everything the first-logon scripts print, for the test report, and streams it to
# COM1, which the test VM writes to a file on the node: that gets the log out even when the
# guest agent or the network never come up.
$CiDir = Join-Path $env:ProgramData 'Customize-WindowsIso\ci'
New-Item -ItemType Directory -Force -Path $CiDir | Out-Null
Start-Transcript -Path (Join-Path $CiDir 'oobe-transcript.log') -Append | Out-Null
[PSCustomObject]@{ started = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $CiDir 'oobe-started.json')

$Streamer = @'
$Dir = Join-Path $env:ProgramData 'Customize-WindowsIso\ci'
$Log = Join-Path $Dir 'oobe-transcript.log'
$Done = Join-Path $Dir 'oobe-complete.json'
$Port = New-Object System.IO.Ports.SerialPort 'COM1', 115200
try { $Port.Open() } catch { exit }
$Position = 0
$Until = $null
while ($true) {
  if (Test-Path $Log) {
    $Stream = [IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite')
    try {
      if ($Stream.Length -gt $Position) {
        $Stream.Position = $Position
        $Bytes = New-Object byte[] ($Stream.Length - $Position)
        $Read = $Stream.Read($Bytes, 0, $Bytes.Length)
        $Port.Write($Bytes, 0, $Read)
        $Position += $Read
      }
    }
    finally { $Stream.Dispose() }
  }
  # a few more seconds after the end, for the transcript's last lines
  if (Test-Path $Done) { if (-not $Until) { $Until = (Get-Date).AddSeconds(10) } elseif ((Get-Date) -gt $Until) { break } }
  Start-Sleep -Seconds 2
}
$Port.Close()
'@
$Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Streamer))
Start-Process powershell.exe -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $Encoded -WindowStyle Hidden
