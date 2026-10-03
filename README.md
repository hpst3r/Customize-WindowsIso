# Customize-WindowsIso

Set of scripts to take a Windows ISO and:

- Remove a short list of consumer AppX packages and deprecated capabilities from **every** edition in `install.wim`
- Apply offline registry settings (sponsored content, Start/Search suggestions, Widgets, mouse acceleration) from `config.json`
- Bypass the Windows 11 TPM / Secure Boot / RAM checks in `boot.wim` (`LabConfig`)
- Add a very basic `autounattend.xml` that lets the admin run arbitrary PowerShell from removable disks
- Add stub PowerShell scripts that run further customization after installation (`.postinstall\specialize`, `.postinstall\oobe`)

It is designed to run weekly after [Get-WindowsIso](https://github.com/hpst3r/Get-WindowsIso), which builds fully-updated ISOs from uupdump.

## Requirements

- Windows PowerShell 5.1, elevated
- Windows ADK **Deployment Tools** (for `oscdimg.exe`):

  ```PowerShell
  adksetup.exe /quiet /norestart /ceip off /features OptionId.DeploymentTools
  ```

- Free space on the working drive of roughly 3x the ISO size + 20 GB

## Usage

```PowerShell
.\Customize-Iso.ps1 `
  -IsoPath 'Y:\Images\Standard\WindowsServer2025.iso' `
  -WorkingDir 'Y:\IsoBuild\Customize\WindowsServer2025' `
  -OutPath 'Y:\Images\Customized\WindowsServer2025.iso'
```

Optional parameters: `-ConfigFile`, `-Autounattend`, `-LogDir`, and `-WinREWimPath`.
`-WinREWimPath` is only used for images that have no WinRE of their own. Get-WindowsIso
builds keep a WinRE that matches the build, so it is normally not needed.

Outputs, written only after the ISO has been built and verified:

- `<name>.iso`
- `<name>.iso.sha256.txt`
- `<name>.iso.json`: images, removed packages, warnings, build time, and the fingerprint used by the runner

If an image has several editions (e.g. the four Windows Server editions), the
`/IMAGE/INDEX` selection is removed from the unattend so Setup asks which edition to
install. With a single edition, Setup installs it without asking.

> **Warning:** the unattend wipes disk 0 without prompting, and the ISO boots
> without "press any key" on UEFI (`iso.NoPrompt`). Don't leave it attached to a machine you care about.

## Configuration (`config.json`)

- `install.Packages.AppXPackagesToRemove`: provisioned AppX package names (wildcards allowed)
- `install.Packages.WindowsCapabilitiesToRemove`: capability names (wildcards allowed)
- `install.Packages.WindowsPackagesToRemove`: CBS package names (wildcards allowed)
- `install.Registry`: groups of registry values, each with `Enabled`. `Hive` is one of:
  - `SOFTWARE`: HKLM\SOFTWARE
  - `SYSTEM`: HKLM\SYSTEM
  - `DEFAULTUSER`: the default user profile (`C:\Users\Default\NTUSER.DAT`), copied to every new user
- `install.Format`: `wim` (default) or `esd`. With `esd`, the serviced image is exported to
  `sources\install.esd` with LZMS (`recovery`) compression instead of `install.wim`. It is much
  smaller (and fits FAT32 USB media more easily) but takes much longer to build. Setup uses
  `install.esd` automatically. The ESD can't be mounted for servicing; export it to a WIM first.
- `install.ExportWim`: with `wim`, re-export `install.wim` after servicing to drop orphaned data (smaller ISO)
- `boot.LabConfig`: Windows 11 Setup hardware-check bypasses to enable
- `iso.NoPrompt`: use `efisys_noprompt.bin` so UEFI boot doesn't wait for a key press

## Post-install scripts

The stubs look for `.postinstall\specialize` and `.postinstall\oobe` at the root of any
drive (e.g. a USB stick) and run the `.ps1` scripts in them, sorted by name.

The `specialize` stub runs as SYSTEM with no console, so it only runs the top-level scripts.

The `oobe` stub runs at first logon. Subfolders of `.postinstall\oobe` are clients (and may
have subfolders of their own, e.g. sites). The stub shows them as a tree, and picking a folder
runs the scripts in every folder on the way down to it:

```text
.postinstall\oobe\
  01-common.ps1          always runs
  ClientA\
    01-join-domain.ps1   runs for ClientA and anything under it
    Site1\
      01-printers.ps1    runs for ClientA\Site1 only
  ClientB\
```

Keys: arrows to move and expand/collapse, a letter to jump, Enter to select (it lists the
scripts and asks again before running), Esc to run nothing. With no subfolders, the
top-level scripts run without a menu, as before.

## Post-install scripts for VMs (`postinstall.iso`)

For virtual machines, `New-PostinstallIso.ps1` packs the repo's `.postinstall` folder into a small,
non-bootable `postinstall.iso` to attach as a second CD-ROM. The runner builds it into the
output directory each run (`BuildPostinstallIso` in `runner-config.json`), and only rebuilds it when
the scripts change. It has to be attached as a disk: specialize runs as SYSTEM before
networking, so a network share won't work. Only attach one drive with a `.postinstall` folder,
since the first one found wins.

> The scripts may contain credentials in plain text (e.g. `10-create-user.ps1`), so anyone
> who can read `postinstall.iso` can read them.

## VirtIO drivers (QEMU/KVM, Proxmox)

To install onto **virtio-scsi** (or virtio-blk) disks, Setup and the installed OS both need
the storage driver, so it has to be in the images, not only on a second disk. With a
virtio-win ISO configured, every customized ISO gets:

- the drivers in `VirtIO.Drivers` (default `vioscsi`, `viostor`, `NetKVM`) added to the Setup
  image in `boot.wim`, so Setup sees the disk, and to every image in `install.wim`, so the
  installed OS boots from it and has networking for the OOBE scripts
- the matching OS folder from the virtio-win ISO: `w11` (client), `2k22`, `2k25` (server)

`postinstall.iso` also gets `virtio\virtio-win-guest-tools.exe` and its SHA-256, and
`.postinstall\oobe\05-install-virtio-guest-tools.ps1` installs it silently (balloon, serial,
QEMU guest agent, SPICE agent, the remaining drivers) when the machine has VirtIO devices.
On anything else it does nothing.

The installers in upstream (Fedora) virtio-win builds are unsigned; only the drivers are
(WHQL), and Windows checks those at install time. So the installer is accepted when building
`postinstall.iso` if it is validly signed or unsigned (a broken signature is rejected), and the
OOBE script only runs it if it is validly signed or matches the SHA-256 recorded at build time.

The virtio-win ISO isn't downloaded automatically. The fedorapeople.org directory listings are
behind a browser challenge, though direct file links work, e.g.
`curl -LO https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso`.
Put the ISO at `VirtIO.IsoPath` in `runner-config.json`
(default `Y:\IsoBuild\Cache\virtio-win.iso`); replacing it with a newer one rebuilds every ISO
on the next run. If the path is set but the file is missing, the run fails rather than building
images without the drivers. Clear `VirtIO.IsoPath` to turn this off.

The drivers are not added to WinRE inside the images, so the recovery environment won't see a
virtio-scsi disk.

## Weekly runs

`runner.ps1` customizes every ISO in `InputDirectory` (see `runner-config.json`) one at a
time. It skips an ISO when the output already exists and was built from the same input
with the same config, unattend, stubs, and script. Pass `-Force` to rebuild everything.
Exit code is non-zero if any ISO failed, so Task Scheduler's *Last Run Result* shows it.

`register-task.ps1` registers one weekly task, running as SYSTEM, that runs Get-WindowsIso's
`stub.ps1`, then `runner.ps1`, then `Send-BuildNotification.ps1` (see Notifications):

```PowerShell
.\register-task.ps1 -GetWindowsIsoPath Y:\src\Get-WindowsIso
```

Logs are in `LogDirectory` (default `Y:\IsoBuild\Logs`). Each ISO has its own
`Customize-<name>-<timestamp>.log`, and DISM's log is in the working directory.
A failed build leaves its working directory in place for troubleshooting.
The next run cleans it up, including any stale mounts.

Each run also writes a machine-readable summary to `LogDirectory\last-run-runner.json` (and a
`runner-<timestamp>.json` copy beside the transcript): start/end time, exit code, log file, and
per ISO the status, `result` (`Built`, `UpToDate`, `Failed`, `Locked`, `Stale`), minutes,
warnings, and the source build, image versions and editions from the manifests.
Get-WindowsIso's `stub.ps1` writes the same kind of file to its `logs\last-run-stub.json`.

## Notifications

The task's last action, `Send-BuildNotification.ps1`, reads both run summaries and sends one
message, e.g. *Windows images: OK (2 rebuilt)*, *Windows images: FAILED (1 failed)* or
*Windows images: ACTION NEEDED (3 stale)*, listing what was rebuilt, new Windows builds,
failures, durations and warning counts. A summary that is missing or older than
`MaxSummaryAgeHours` (default 24) counts as a failure, since that stage didn't finish.

Setup (on the build machine, elevated):

1. Copy `notify.example.json` to `notify.json` (it's gitignored) and edit it. Each channel is
   optional (`Enabled`) and has `Send`: `Always` or `OnlyOnFailure` (anything but OK, so it
   includes *ACTION NEEDED*).
   - `Ntfy`: `Server` (default `https://ntfy.sh`) and `Topic`. On the public server anyone who
     knows the topic can read it, so use a long random name. The message has priority 4 on
     failure, 3 when something was rebuilt, and 2 when nothing changed.
   - `Email`: an authenticated SMTP relay (Microsoft 365 `smtp.office365.com`, Amazon SES,
     etc.): `SmtpServer`, `Port` (587), `Security` (`StartTls`, or `None` for a trusted
     relay without TLS), `From`, `To` (list), `Username`. `System.Net.Mail` can't do TLS on
     connect (port 465), so use 587 with STARTTLS. Microsoft 365 needs SMTP AUTH enabled
     for the sending mailbox.
   - `Link`: optional URL opened when the ntfy notification is tapped (e.g. the index page).
2. Store secrets with `Set-NotificationSecret.ps1`; it prompts for the value and never prints it:

   ```PowerShell
   .\Set-NotificationSecret.ps1 -Name SmtpPassword
   .\Set-NotificationSecret.ps1 -Name NtfyToken      # only for a protected ntfy topic
   ```

   They are encrypted with DPAPI in *LocalMachine* scope into `notify.secrets.json`
   (gitignored, readable only by SYSTEM and Administrators): the SYSTEM task can decrypt
   them, but a copy of the file is useless on another machine. Re-run it to change a secret,
   or pass `-Remove`.
3. Test: `.\Send-BuildNotification.ps1 -Test` sends on every enabled channel (ignoring
   `OnlyOnFailure`); `-DryRun` only prints the message. Run `register-task.ps1` again to add
   the notification action to an existing task (`-NoNotification` leaves it out).

A channel that fails is logged as a warning (`notify-<timestamp>.log` in `LogDirectory`); the
step exits non-zero only if every channel that tried to send failed.
