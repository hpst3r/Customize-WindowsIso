# Troubleshooting

## During an install

| Symptom | Likely cause | What to do |
|---|---|---|
| Setup's disk list is empty ("We couldn't find any drives") | no driver for the storage controller (Intel RST/VMD, RAID, virtio on an old ISO) | Switch the controller to AHCI in the firmware, or add the driver to a [driver set](configuration.md#driver-sets). With the disk picker: `L` loads a driver from a stick. On a VM, check the ISO is a current one (the index page lists its drivers). |
| Setup asks for the language, edition or licence | it didn't use the ISO's `autounattend.xml`: another answer file on a drive that comes first (e.g. a stick made with Rufus's customization options), or a damaged file | Remove other drives/answer files; check `autounattend.xml` at the ISO root. Multi-edition (Server) media *do* ask for the edition. |
| The machine reinstalls after Setup's reboot | the ISO boots without "press any key", and the firmware boots it again | Remove the stick/DVD after Setup, or put the disk first in the boot order. |
| First logon stops at *Press Ctrl+Alt+Del* / the sign-in screen | no autologon: `specialize\10-create-user.ps1` didn't run (no `.postinstall\specialize` on any drive) or the account wasn't created (password doesn't meet the policy: Server requires complexity) | Fix the password; check the post-install drive was attached during Setup. |
| No console window / nothing runs at first logon | no `.postinstall\oobe` on any drive at first logon (stick removed, the VM's second DVD missing) | Re-run by hand: `powershell -ExecutionPolicy Bypass -File C:\postinstall-oobe-stub.ps1`. |
| No client menu | `.postinstall\oobe` has no subfolders with scripts, or the stub has no console | Check the folders on the drive the stub found (it prints `Found .postinstall directory: ...`). |
| `Error executing script: ...` | that script threw | Read the message in the console; the other scripts still ran. |
| No network at first logon on a VM | the VirtIO network driver is missing or was removed | Current ISOs have it in the image. The post-install script installs drivers and guest agent separately so an agent failure can't remove it. |
| Office isn't installed | not a client image, no `\office` on the drive and no internet, or the install failed | `%ProgramData%\Customize-WindowsIso\office\logs`; the console says which source it used. |
| `winget` fails with "Failed when opening source(s)" | an old App Installer | Current ISOs provision the current one; on an old install: `Repair-WinGetPackageManager -AllUsers -Latest`, `winget source reset --force`. |
| QEMU guest agent missing on a VM | its install failed (it does on Insider 29xxx) | `%TEMP%\qemu-ga-x86_64.log`; the console shows the failing step. |

Logs on the installed machine:

| Where | What |
|---|---|
| `C:\Windows\Panther\setupact.log`, `setuperr.log` | Setup |
| `C:\Windows\Panther\UnattendGC\setupact.log` | the specialize pass (and its `RunSynchronous` commands) |
| `X:\Windows\Panther\setupact.log` | Setup in WinPE (Shift+F10 during Setup opens a command prompt) |
| `X:\DiskPicker\work\diskpicker.log` | the disk picker (`C` in its menu opens a prompt) |
| `%TEMP%\virtio-win-gt-x64.log`, `qemu-ga-x86_64.log` | the guest tools MSIs |
| `%ProgramData%\Customize-WindowsIso\office\logs` | Office |

## During a build

| Symptom | Where to look |
|---|---|
| An ISO shows *Failed* in the notification or the index page | `Y:\IsoBuild\Logs\Customize-<iso>-<time>.log` (the reason is near the end, `Customize-Iso: FAILED: ...`), and DISM's log in `Y:\IsoBuild\Customize\<iso>\`. The previous ISO is still on the share. |
| *Stale* | `DeleteSourceAfterBuild` deleted the source and the output needs a rebuild: re-download it with Get-WindowsIso (the message has the command). |
| *Locked* | the source ISO was still being written; the next run picks it up. |
| A stage "didn't finish or didn't run" | the task was stopped (time limit, reboot) or a step crashed: Task Scheduler's history and the stage's log. |
| "another runner is already active" | a run is still going (or was killed seconds ago). |

DISM, image mounts and hive loads need SYSTEM (or an elevated session with backup/restore
privileges). To run something by hand as SYSTEM, use a temporary scheduled task (see the README's
`Test-CustomizedIso.ps1` section). If a build was killed, the next run cleans up its mounts; never
run `dism /Cleanup-Mountpoints` while a build is active: it acts on every mount on the machine.

## Install tests

See [install tests](install-tests.md#reading-the-results): `result.json` says what failed,
`serial-oobe-transcript.log` has everything the first logon printed, and the screenshots show where
Setup stopped. A failed test's VM (9100) is kept, stopped, on the node until the next test.
