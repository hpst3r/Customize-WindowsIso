# Customize-WindowsIso

Set of scripts to take a Windows ISO and:

- Customize **every** edition in `install.wim` according to a profile chosen per edition (see
  [Profiles](#profiles)): e.g. remove consumer AppX packages and deprecated capabilities and apply
  offline registry settings (sponsored content, Start/Search suggestions, Widgets) on clients, and
  leave Windows Server untouched apart from the stub, drivers and Defender update
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

Optional parameters: `-ConfigFile`, `-Autounattend`, `-LogDir`, `-WinREWimPath`,
`-DefenderPackage` (see [Microsoft Defender update](#microsoft-defender-update)), and
`-ProfileName` (use one profile for every edition instead of `install.ProfileRules`).
`-WinREWimPath` is only used for images that have no WinRE of their own. Get-WindowsIso
builds keep a WinRE that matches the build, so it is normally not needed.

Outputs, written only after the ISO has been built and verified:

- `<name>.iso`
- `<name>.iso.sha256.txt`
- `<name>.iso.json`: images, the profile each image got, removed packages, Defender versions, warnings, build time, and the fingerprint used by the runner

With `-KeepPrevious` (the runner passes it unless `KeepPrevious` is `false` in
`runner-config.json`), the ISO being replaced and its sidecars are kept as
`<name>.previous.iso` (`.previous.iso.json`, `.previous.iso.sha256.txt`), replacing any older
previous copy, so last week's image is still there if this week's turns out bad. This roughly
doubles the space the output directory needs. If a client on the share has the old previous
copy open it can't be replaced: the build still succeeds, with a warning, without keeping the
ISO it replaced. If a client has the current ISO open it can't be replaced at all: the build
fails and leaves the current ISO and its sidecars as they were.

If an image has several editions (e.g. the four Windows Server editions), the
`/IMAGE/INDEX` selection is removed from the unattend so Setup asks which edition to
install. With a single edition, Setup installs it without asking.

> **Warning:** the unattend wipes disk 0 without prompting (unless `iso.DiskPicker` is on; see
> below), and the ISO boots without "press any key" on UEFI (`iso.NoPrompt`). Don't leave it
> attached to a machine you care about.

## Configuration (`config.json`)

- `install.Profiles` / `install.ProfileRules`: what is removed and which registry settings are
  applied, per edition (see [Profiles](#profiles))
- `install.Format`: `wim` or `esd` (this config uses `esd`). With `esd`, the serviced image is exported to
  `sources\install.esd` with LZMS (`recovery`) compression instead of `install.wim`: about 20%
  smaller, but customizing takes roughly 2.5x as long. Setup uses `install.esd` automatically.
  The ESD can't be mounted for servicing; export it to a WIM first.
- `install.ExportWim`: with `wim`, re-export `install.wim` after servicing to drop orphaned data (smaller ISO)
- `install.DefenderUpdate`: apply Microsoft's Defender update to every image (default `true`; see below)
- `boot.LabConfig`: Windows 11 Setup hardware-check bypasses to enable
- `iso.NoPrompt`: use `efisys_noprompt.bin` so UEFI boot doesn't wait for a key press
- `iso.DiskPicker` (default `false`, `true` in this config): choose the install disk in WinPE instead of wiping disk 0 (below)
- `iso.DiskPickerMinSizeGB` (default `50`): smallest disk the picker installs to without asking

## Profiles

A profile says what is done to an edition's image:

- `Packages.AppXPackagesToRemove`: provisioned AppX package names (wildcards allowed)
- `Packages.WindowsCapabilitiesToRemove`: capability names (wildcards allowed)
- `Packages.WindowsPackagesToRemove`: CBS package names (wildcards allowed)
- `Registry`: groups of registry values, each with a `Name` and `Enabled`. `Hive` is one of:
  - `SOFTWARE`: HKLM\SOFTWARE
  - `SYSTEM`: HKLM\SYSTEM
  - `DEFAULTUSER`: the default user profile (`C:\Users\Default\NTUSER.DAT`), copied to every new user
- `Extends`: another profile to start from. Its package patterns are added to; its registry
  groups are replaced by same-named groups here (e.g. one with `"Enabled": false`) or added to.

Driver sets, the Defender update, the autounattend stub and `boot.LabConfig` apply to every
image whatever its profile.

This config has three:

| Profile | What it does | Used for |
|---|---|---|
| `plain` | Nothing removed, no registry changes | Windows Server (`Server`, `Server Core`) |
| `client-default` | Ads, consumer and retired apps removed; sponsored content, Start/Search suggestions and Widgets off; mouse acceleration off | Windows 11 |
| `client-minimal` | `client-default` plus most inbox apps (Camera, Clock, Sticky Notes, Sound Recorder, Media Player, Feedback Hub, Get Help, Quick Assist, Phone Link, Teams, new Outlook, To Do, Power Automate, Xbox components), legacy Media Player and PowerShell ISE; Game DVR off; telemetry at Required | not used by default |

Removing the Xbox identity components in `client-minimal` breaks Xbox/Game Pass sign-in in games.

`install.ProfileRules` picks the profile for each edition: the first rule whose conditions all
match wins. Conditions are wildcards (case-insensitive) on:

- `IsoName`: the source ISO's file name, e.g. `Windows11Professional,version26H2.iso`
- `ImageName`: the edition, e.g. `Windows 11 Pro`, `Windows Server 2025 Datacenter`
- `InstallationType`: `Client`, `Server` (Desktop Experience) or `Server Core`

A rule without conditions matches everything. An edition that no rule matches fails the build
rather than getting a profile nobody chose. For example, to strip one image harder:

```json
"ProfileRules": [
  { "InstallationType": "Server*", "Profile": "plain" },
  { "IsoName": "*Insider*", "Profile": "client-minimal" },
  { "InstallationType": "Client", "Profile": "client-default" }
]
```

The manifest records the profile each image got. Configs from before profiles (with
`install.Packages` and `install.Registry`) still work as a single profile for every image.

## Choosing the install disk (`iso.DiskPicker`)

> On in this config, and tested on Proxmox VMs (one disk, two disks) and with recorded diskpart output; not yet on physical machines. Off by default in the code; with it off, the ISO is built exactly as before.

With `iso.DiskPicker` on, the ISO no longer wipes disk 0 blindly. A script in the Setup image of
`boot.wim` (`winpe\diskpicker.cmd`, started by `winpeshl.ini` instead of Setup) looks at the disks first:

- **One internal disk of `DiskPickerMinSizeGB` or more:** it is wiped and Windows is installed on it
  with no questions, as before (single-disk VMs stay unattended).
- **Several:** a numbered menu shows each disk's number, size, bus type, model, partition count and
  volumes. Type a disk number, then `YES`, to wipe it and install. Smaller internal disks are listed
  too but never chosen automatically (e.g. a 16 GB Optane module next to an SSD is ignored).
- **None:** it says so (usually a missing storage driver: Intel RST/VMD, RAID, virtio) and offers to
  load a driver (`drvload`) and rescan.

USB and SD disks, the disk holding the install media (a volume with `\sources\boot.wim`) and Ventoy
disks are never offered. The menu also has `S` (run Setup and choose/partition the disk on its own
page), `C` (command prompt), `R` (rescan), `B`/`P` (reboot/power off).

The chosen disk gets the same layout the answer file used for disk 0 (UEFI: EFI 260 MB, MSR 16 MB,
Windows), or MBR with a 100 MB active system partition when booted in BIOS mode. The script then
starts Setup with `/unattend:` pointing at a copy of the media's answer file with `InstallTo` set to
that disk. The media's own `autounattend.xml` has no disk settings, so if Setup ever starts without
the picker (`S`, or a future boot.wim that ignores `winpeshl.ini`), Setup asks for the disk rather
than wiping one.

An `autounattend.xml` at the root of another drive overrides the picker: it runs Setup with that file
instead (as Setup itself would have, since other drives come first in its search order).

The picker uses only cmd and diskpart: the Setup image has no `findstr`, `choice` or `wmic`, and
Server 2022's has no PowerShell, so it's a typed menu rather than an arrow-key one.
Its log is `X:\DiskPicker\work\diskpicker.log` (Shift+F10 in Setup, or `C` in the menu).
`winpe\tests\Test-DiskPicker.ps1` runs it against recorded and made-up diskpart output in a
test mode that never partitions anything or starts Setup.

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
top-level scripts run without a menu, as before. Scripts named `z-*` (in any of the folders)
run after all the others, so the common `z-1-wait-for-office.ps1` and
`z-9-wait-for-interaction.ps1` come after the client's scripts. Windows 11 opens the Start menu
over the console at the first sign-in; while the menu waits for a key it takes the keyboard
focus back.

The full guide, with screenshots of an install, is in [docs/](docs/README.md).

## Post-install scripts for VMs (`postinstall-client.iso`, `postinstall-server.iso`)

For virtual machines, `New-PostinstallIso.ps1` packs the repo's `.postinstall` folder (or
`PostinstallSource` from `runner-config.json`: a private copy for client scripts with credentials,
since this repository is public) into a non-bootable ISO to attach as a second CD-ROM. The runner
builds two into the output directory each run (`BuildPostinstallIso` in `runner-config.json`), each
only rebuilt when its contents change:

| ISO | Contents | Attach to |
|---|---|---|
| `postinstall-client.iso` | `.postinstall`, VirtIO guest tools, Microsoft 365 Apps (`office\`, ~4 GB) | client VMs |
| `postinstall-server.iso` | `.postinstall`, VirtIO guest tools (a few MB) | server VMs |

The scripts are the same on both; servers never install Office (see below), so they don't need
to carry it. An ISO has to be attached as a disk: specialize runs as SYSTEM before networking,
so a network share won't work. Only attach one drive with a `.postinstall` folder, since the
first one found wins. (`postinstall.iso`, from before the split, is no longer updated; delete it
once no VM refers to it.)

> The scripts may contain credentials in plain text (e.g. `10-create-user.ps1`), so anyone
> who can read the ISOs can read them.

The runner also keeps the client ISO's contents as a folder (`PostinstallFolder`, default
`<OutputDirectory>\postinstall`): `.postinstall`, `office` and `virtio`, ready for the root of a
USB stick or Ventoy drive. `Copy-PostinstallMedia.ps1` copies them there, mirroring just those
three folders (only changed files are copied; nothing else on the drive is touched):

```powershell
.\Copy-PostinstallMedia.ps1 -Source \\server\Customized\postinstall -Destination E:\
# server-only drive: -SkipOffice leaves the 4 GB office\ folder off (or use postinstall-server.iso as the source)
.\Copy-PostinstallMedia.ps1 -Source \\server\Customized\postinstall -Destination E:\ -SkipOffice
```

## Microsoft 365 Apps at first logon

Client images install Microsoft 365 Apps (Office) at first logon, from the post-install media:

- **Weekly**, the runner (`OfficeKit.ps1`) checks Microsoft's release feed for the newest build
  on the channel in `.postinstall\office\configuration.xml` (Current), and only when it has
  changed downloads it (about 4 GB, a few minutes) with the Office Deployment Tool into
  `Office.CacheDirectory`. The build and the ODT's `setup.exe` must be signed by Microsoft. It
  goes into `postinstall-client.iso` and the post-install folder as `office\`. A failed download keeps
  the cached build. Office doesn't affect the images, so a new build doesn't rebuild them.
- **At first logon**, `.postinstall\oobe\06-start-office-install.ps1` starts the install from
  `office\` on the post-install drive in the background, so it overlaps the other scripts
  (WinGet, software), and `z-1-wait-for-office.ps1` waits for it before the final prompt, so the
  drive isn't pulled while Office still reads from it. From a local SSD this is the fastest way
  to install it. Anything missing from `office\` comes from Microsoft's CDN (`AllowCdnFallback`),
  and without `office\` on any drive, the script downloads the ODT and installs from the CDN.
  Logs: `%ProgramData%\Customize-WindowsIso\office\logs`.
- **Which machines**: only images whose profile has the `OfficeOnFirstLogon` registry group
  (`client-default`, and `client-minimal` through it), which sets
  `HKLM\SOFTWARE\Customize-WindowsIso\Postinstall` `InstallOffice` = 1. Server images (`plain`)
  don't have it. To leave Office off a profile, add the group to it with `"Enabled": false`.
  Machines that already have Office are skipped.

What gets installed is `.postinstall\office\configuration.xml`: 64-bit, Current Channel,
en-us, Microsoft 365 Apps for enterprise (`O365ProPlusRetail`) without Skype for Business,
OneDrive (Windows has its own) or the legacy OneDrive for Business sync app, and with updates
from the CDN. Changing the product ID needs no new download; changing the channel, edition or
languages makes the next run download again. Turn the download off with `Office.Enabled =
false` in `runner-config.json`.

## Driver sets (boot-critical storage and network drivers)

To install onto a disk Windows has no inbox driver for (virtio-scsi, many RAID/NVMe
controllers), Setup, the installed OS and the recovery environment all need the storage driver,
so it has to be in the images, not only on a second disk. `DriverSets` in `runner-config.json`
lists the driver sets to add:

```json
"DriverSets": [
  { "Name": "VirtIO", "Type": "virtio-iso", "Path": "Y:\\IsoBuild\\Cache\\virtio-win.iso",
    "Drivers": ["vioscsi", "viostor", "NetKVM"], "Targets": ["boot", "install", "winre"] },
  { "Name": "Storage", "Type": "folder", "Path": "Y:\\IsoBuild\\Drivers\\Storage",
    "Targets": ["boot", "install", "winre"], "Enabled": false }
]
```

- `Type`:
  - `virtio-iso`: a virtio-win ISO. `Drivers` are its driver folders (default `vioscsi`,
    `viostor`, `NetKVM`); the OS folder is picked per image: `w11` (client), `2k22`, `2k25` (server).
  - `folder`: a folder of drivers, e.g. a per-model pack exported with `pnputil /export-driver * <dir>`,
    added with `dism /Add-Driver /Recurse`. If it has OS subfolders (`w10`, `w11`, `2k19`, `2k22`,
    `2k25`), only the one matching each image is used (an image with no matching subfolder gets a
    warning); otherwise the whole folder is added to every image. Keep it to boot-critical
    storage and network drivers for the right architecture: everything in it goes into each target.
- `Targets` (default all three):
  - `boot`: the Setup image in `boot.wim`, so Setup sees the disk (and the network)
  - `install`: every image in `install.wim`, so the installed OS boots from the disk and has
    networking for the OOBE scripts
  - `winre`: `Windows\System32\Recovery\Winre.wim` inside each install image, so the recovery
    environment sees the disk. It is mounted inside the mounted install image, then re-exported to
    drop orphaned data. An image without a Winre.wim gets a warning.
- `Enabled: false` turns a set off; so does an empty `Path`. If an enabled set's `Path` doesn't
  exist, the run fails rather than building images without the drivers.

DISM refuses unsigned drivers, which fails the build. The drivers added to each image are listed
in the `drivers` field of the output `.json` (e.g. `[1] Windows 11 Pro WinRE: VirtIO vioscsi\w11`).
Replacing the virtio-win ISO, changing a driver folder or editing a set rebuilds every ISO on the
next run. The older `"VirtIO": { "IsoPath", "Drivers" }` block still works when there is no
`DriverSets`: it is one `virtio-iso` set targeting all three.

`Customize-Iso.ps1` takes the sets with `-DriverSetsFile <json>` (a file with `DriverSets`, such as
`runner-config.json`; the runner passes a copy in the working directory), or a single virtio-win
ISO with `-VirtIOIsoPath`/`-VirtIODrivers`.

### VirtIO (QEMU/KVM, Proxmox)

Besides the drivers in the images, both post-install ISOs get the guest tools from the (first)
`virtio-iso` set, each with its SHA-256: `virtio\virtio-win-gt-x64.msi` (the remaining drivers
and services: balloon, serial, ...), `virtio\qemu-ga-x86_64.msi` (the QEMU guest agent) and
the all-in-one `virtio\virtio-win-guest-tools.exe`. When the machine has VirtIO devices,
`.postinstall\oobe\05-install-virtio-guest-tools.ps1` installs the drivers MSI and then the
agent MSI, silently; on anything else it does nothing. They are installed separately because
the all-in-one installer rolls everything back, drivers and network included, when the agent
fails (as on Insider 29xxx, where the agent's VSS provider fails to register with
`VSS_E_UNEXPECTED_PROVIDER_ERROR`). Media
without the MSIs get the all-in-one installer. On failure the script prints the MSI log lines
that say why.

The installers in upstream (Fedora) virtio-win builds are unsigned; only the drivers are
(WHQL), and Windows checks those at install time. So the installer is accepted when building
the post-install ISOs if it is validly signed or unsigned (a broken signature is rejected), and the
OOBE script only runs it if it is validly signed or matches the SHA-256 recorded at build time.

The virtio-win ISO isn't downloaded automatically. The fedorapeople.org directory listings are
behind a browser challenge, though direct file links work, e.g.
`curl -LO https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso`.
Put the ISO at the `Path` of the `virtio-iso` set in `runner-config.json`
(default `Y:\IsoBuild\Cache\virtio-win.iso`); replacing it with a newer one rebuilds every ISO
on the next run. Set `Enabled` to false to turn this off.

## Microsoft Defender update

New installs would otherwise start with the Defender platform, engine, and security intelligence
that shipped on the media. Every image in `install.wim` (client and Server, including Server Core)
gets Microsoft's
[Defender update for Windows operating system installation images](https://support.microsoft.com/servicing/Management-Tools/microsoft-defender/update/microsoft-defender-update-for-windows-operating-system-installation-images)
(see also [Updates for DISM](https://learn.microsoft.com/defender-endpoint/microsoft-defender-antivirus-updates#updates-for-deployment-image-servicing-and-management-dism)).
Set `install.DefenderUpdate` to `false` in `config.json` to turn it off.

- **Download.** Once per run, the runner checks the kit at `Defender.Url` (x64:
  `https://go.microsoft.com/fwlink/?linkid=2144531`). The fwlink redirects to a URL that includes the
  package version, so a `HEAD` request (redirect URL, ETag, Last-Modified, size) tells whether it
  changed without downloading the ~250 MB zip. A changed kit is downloaded and extracted to
  `Defender.CacheDirectory` (default `Y:\IsoBuild\Cache\defender\current`). It replaces the cached kit only if
  `defender-dism-x64.cab` and `DefenderUpdateWinImage.ps1` both have valid Authenticode
  signatures from Microsoft that chain to a Microsoft root.
- **Best effort.** If the download fails, the cached kit is used, with a warning. If there is
  no usable kit, images are built without the update and the manifest gets a warning.
- **Applying.** The kit's `DefenderUpdateWinImage.ps1` mounts the WIM itself with the DISM
  cmdlets, which this project avoids (see `Find-Dism`). Inside the image, all the script does is copy the
  cab's `Platform` and `Definition Updates\Updates` folders into
  `ProgramData\Microsoft\Windows Defender`, put `package-defender.xml` in `Windows\Temp`, and
  enable the `Windows-Defender` feature on Server if it is off. `Customize-Iso.ps1 -DefenderPackage <cab>`
  does the same to the already-mounted image (`Add-DefenderUpdate`), after re-checking the cab's
  signature. Defender switches to the newer platform and definitions when the installed OS first starts.
- **Support.** The kit's own checks are applied: matching architecture, and Windows 10 1607
  (with the September 2018 update) or later. That covers Windows 10/11, Insider builds, and
  Windows Server 2016 and later. Images that fail these checks are skipped with a warning. An
  image that already has these versions or newer is left alone.
- **Verification.** After copying, the versions are read back from the files in the image
  (newest `MsMpEng.exe`, `mpengine.dll`, `mpavdlta.vdm`), and a mismatch fails the build. The
  manifest's `defender` entry records the package, platform, engine, and security intelligence
  versions, plus each image's versions before and after.
- **Cost.** The cab is expanded once per ISO (~330 MB), and each image gets ~330 MB of extra
  copying. The files are identical in every edition, so the WIM stores them only once.

**Rebuilds.** The kit's platform and engine versions are part of the runner fingerprint, so a
new monthly platform/engine release rebuilds every ISO once. Microsoft also publishes
security-intelligence-only refreshes of the kit, sometimes several a month, and these don't trigger a
rebuild. An ISO built for another reason gets whatever kit is current, and Defender
downloads current security intelligence within minutes of going online anyway. Set
`Defender.RebuildOnSignatureUpdate` to `true` to rebuild on every new kit.

## Current WinGet (App Installer)

The App Installer (WinGet) inbox in the media is whatever shipped with the release (1.21 on
24H2-based media) until the Store updates it after the first sign-in. That old client fails
with "Failed when opening source(s)", so post-install scripts using `winget` break on a fresh
install. Each run therefore provisions the current release into every image that has AppX
(Server Core doesn't, and is skipped):

- **Source:** the runner checks [microsoft/winget-cli](https://github.com/microsoft/winget-cli/releases)'s
  latest **stable** release once per run and downloads it only when the tag changed. That's the
  `.msixbundle`, the dependencies zip and the license, about 300 MB, roughly monthly.
- **Verification:** the bundle and dependencies zip must match the SHA-256 the release publishes
  next to them, and the bundle and every dependency must carry a valid Microsoft signature, before
  they replace the cached kit in `WinGet.CacheDirectory`. A failed refresh keeps the cached kit.
- **Provisioning:** `dism /Add-ProvisionedAppxPackage` with the x64 dependencies and the license;
  the provisioned version is then read back. A failure is a build warning (the image keeps its
  inbox App Installer), not a failed build.
- **Rebuilds:** the release tag is part of the runner fingerprint, so a new WinGet release rebuilds
  every ISO once. The manifest's `winget` entry records the release and each image's before/after version.

Set `install.UpdateWinGet` to `false` in `config.json` to turn it off.

## Weekly runs

`runner.ps1` customizes every ISO in `InputDirectory` (see `runner-config.json`) one at a
time. It skips an ISO when the output already exists and was built from the same input
with the same config, unattend, stubs, WinPE scripts, script, driver sets, and Defender
platform/engine version. Pass `-Force` to rebuild everything. `runner-config.json`'s `Defender`
section sets the kit URL (`Url`), the cache directory (`CacheDirectory`), and `RebuildOnSignatureUpdate`.
Exit code is non-zero if any ISO failed, so Task Scheduler's *Last Run Result* shows it.

### Deleting source ISOs (`DeleteSourceAfterBuild`)

To save space, once an ISO's customized output is current (just built, or found up to date)
the runner deletes the source ISO from `InputDirectory`, keeping its `.iso.json` and
`.iso.sha256.txt` (`DeleteSourceAfterBuild`, default `true`). It only deletes an ISO whose
`.sha256.txt` is at least as new as the ISO, and only if the `.iso.json` is there too. That is
enough for both stages to keep working:

- The runner's fingerprint uses the source's SHA-256 from the `.sha256.txt`, so it can still
  tell that an output is up to date without the ISO.
- Get-WindowsIso's `stub.ps1` skips a version when the `.iso.json` already has the latest
  uupdump build, ISO or not. A new build is downloaded as usual, customized, then deleted.

The first run after turning this on finds every output up to date and deletes the sources.

If an output needs rebuilding but its source is gone, because `config.json`, `autounattend.xml`,
the stubs, `Customize-Iso.ps1` or the virtio-win ISO changed (or with `-Force`), the runner
can't rebuild it. It reports the image as **Stale** (result `Stale`, in the summary, the
notification and the index page) with the command to fix it, and exits non-zero:

```PowerShell
Y:\src\Get-WindowsIso\stub.ps1 -Force -Version 'Windows Server 2022'   # downloads it again
.\runner.ps1                                                            # or wait for next week
```

So with this on, **any change to those inputs means downloading every image again**. Turn it
off (`"DeleteSourceAfterBuild": false`) while you are changing the configuration. To retire an
image, delete its `.iso.json` and `.iso.sha256.txt` from `InputDirectory` too; otherwise
it is reported as stale.

`register-task.ps1` registers one weekly task, running as SYSTEM, that runs Get-WindowsIso's
`stub.ps1`, then `runner.ps1`, then (with `-InstallTests`) the install tests on the Proxmox test
node, then `Send-BuildNotification.ps1` (see Notifications):

```PowerShell
.\register-task.ps1 -GetWindowsIsoPath Y:\src\Get-WindowsIso -InstallTests
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

## Install tests on Proxmox (`ci\`)

`Test-CustomizedIso.ps1` (below) checks what is in an ISO; the install tests check that it
actually installs and comes up right. `ci\Invoke-ImageTests.ps1` installs each customized ISO
in a throwaway VM on a dedicated Proxmox VE node, one at a time, and checks the running machine:

1. **Media**: the ISO and the CI post-install media (`ci\New-CiMedia.ps1`: the repo's
   `.postinstall` with `ci\postinstall` laid over it, plus the VirtIO guest tools and Office)
   are copied to the node's ISO storage, skipped when the copy there has the same SHA-256.
   The CI overlay only replaces the two "Press Enter" pauses with completion markers and keeps
   a transcript of the first-logon scripts; everything else is the real post-install media.
2. **VM** (`ci\Test-IsoOnPve.ps1`): q35, OVMF with Secure Boot keys, TPM 2.0, virtio-scsi
   disk, virtio-net, a serial port writing to a file on the node, and three DVDs: the ISO, the
   CI media, and a small per-test DVD with the expected values and the check script. The ISO's
   own `autounattend.xml` drives Setup. Multi-edition media would stop at the edition page, so
   for those the per-test DVD also gets a copy of the ISO's answer file with `/IMAGE/INDEX`
   added; it sits in the first IDE slot, and Setup reads the first `autounattend.xml` in
   drive-letter order. (A virtual USB stick would also work, but with a USB disk attached OVMF
   reads the DVD so slowly that Setup takes ages to boot.) Which editions of multi-edition ISOs
   are tested: `MultiEditionTest` (default: Datacenter with Desktop Experience).
3. **Follows** Setup on the console, taking a screenshot every few minutes. Setup keeps
   showing new things (progress, phases), so nothing new on screen for `StallMinutes` (20)
   fails the test right away: Setup is waiting at a prompt or an error (e.g. the empty disk
   list of an ISO without the storage driver) or the boot hangs. The first-logon scripts are
   followed through the serial port: the CI media streams their transcript there.
4. **Checks**: at the end of first logon the CI media runs `ci\Test-InstalledWindows.ps1`
   from the per-test DVD and sends the results over the serial port, so a broken guest agent
   or network is a failed check, not a test that can't run. They compare the machine with the
   ISO's manifest and its profile in `config.json`: specialize and first-logon
   scripts finished without errors; edition, installation type and build; the local admin;
   WinRE; boot disk on vioscsi and the image's drivers; network and internet; VirtIO guest
   tools; AppX packages and capabilities removed; every registry group in HKLM and the Default
   profile (the logged-on user's copy is a warning only, as Windows rewrites some of it);
   App Installer at least the version the build provisioned; the software the first-logon
   scripts install with WinGet (`ExpectSoftware`); Microsoft 365 Apps (version, product,
   channel) on images that should have it and not on the others; Defender platform and engine;
   critical events since install.
5. **Reports**: `ResultsDirectory\<iso>-<timestamp>\` gets `result.json`, the expected values,
   screenshots, the first-logon transcript (`serial-oobe-transcript.log`, which also lists
   devices without drivers and the network state) and, on failure, Setup's logs (through the
   guest agent, when it runs). The VM is destroyed,
   or on failure kept (stopped) for troubleshooting until the next test (`KeepFailedVm`).

An ISO that passed is not tested again until it changes (by SHA-256); failed ones are retried
every run. The run writes `LogDirectory\last-run-ci.json` for the notification (stage
"Install tests") and refreshes the index page, which shows each image's last install test.

```PowerShell
.\ci\Invoke-ImageTests.ps1                    # whatever changed
.\ci\Invoke-ImageTests.ps1 -Name '*26H2*'      # some ISOs
.\ci\Invoke-ImageTests.ps1 -Force             # everything
.\ci\Test-IsoOnPve.ps1 -IsoPath Y:\Images\Customized\WindowsServer2025.iso -Edition 'Windows Server 2025 Standard' -CiMediaPath Y:\IsoBuild\ci\ci-postinstall.iso
```

`ci\ci-config.json` says where and how: the node (`Host`, `Node`), SSH as root with a
dedicated key (`SshKey`) and a pinned host key (`KnownHostsFile`), the storages and bridge, the
VM ID and size, timeouts, and the expectations above. `KnownIssues` turns a failing check into
a warning with a reason (`Iso` and `Check` are wildcards), for problems that are understood and
waiting on someone else, so they don't fail every week; remove the entry when it's fixed. Everything goes through `ssh`/`scp` and
`qm`/`pvesh` on the node. The key and known_hosts live in `Y:\IsoBuild\Secrets`, readable only
by SYSTEM and Administrators. One test takes about 20-40 minutes; the node needs room for one
VM (10 GB RAM, a 64 GB thin disk) and three ISOs.

Setting it up on a new node:

```PowerShell
ssh-keygen -t ed25519 -N '""' -C image-tests -f Y:\IsoBuild\Secrets\pve_ed25519
# the SYSTEM task's ssh refuses a key owned by (or shared with) an individual user:
icacls Y:\IsoBuild\Secrets\pve_ed25519 /setowner *S-1-5-32-544
icacls Y:\IsoBuild\Secrets\pve_ed25519 /inheritance:r /grant:r *S-1-5-18:F *S-1-5-32-544:F
# on the node, in /root/.ssh/authorized_keys: from="<this box's IP>" <contents of pve_ed25519.pub>
# record the node's host key (check its fingerprint against ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the node):
ssh -i Y:\IsoBuild\Secrets\pve_ed25519 -o UserKnownHostsFile=Y:\IsoBuild\Secrets\known_hosts root@<node> hostname
```

## Checking a customized ISO (`Test-CustomizedIso.ps1`)

`Test-CustomizedIso.ps1` mounts a customized ISO read-only and checks it against `config.json`:
boot files, `autounattend.xml` (no `InstallFrom` when there are several editions), the `$OEM$`
stubs (against `stub-scripts\`), and for every image in `install.wim`/`install.esd`: WinRE is
present, none of the configured AppX packages/capabilities/packages is left, every value of the
enabled `Registry` groups is set (or deleted) in the image's hives, and the drivers the ISO's
manifest lists are installed. In `boot.wim` it checks the `LabConfig` values and drivers. It
uses `dism.exe /Mount-Image /ReadOnly` and `reg.exe` and changes nothing.

```PowerShell
.\Test-CustomizedIso.ps1 -IsoPath Y:\Images\Customized\WindowsServer2025.iso -OutputDirectory Y:\IsoBuild\Logs
```

It writes `Test-<name>-<timestamp>.txt` and `.json` reports (default `logs\`) and exits 0 if
every check passed, 1 otherwise. `-ConfigFile` checks against another config, `-ExpectDrivers`
overrides the drivers expected from the manifest, and `-WorkingDir` sets the scratch folder for
the mount point (an `install.esd` is exported to a WIM there first, which is slow).

Loading the image hives (`reg load`) and querying a mounted image (`dism /Image:`) need an
elevated session with backup/restore privileges; in a restricted or sandboxed session they
fail, and the script stops with a message saying so. Running it as SYSTEM always works, e.g.
through a temporary scheduled task:

```PowerShell
$Action = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -File Y:\src\Customize-WindowsIso\Test-CustomizedIso.ps1 -IsoPath Y:\Images\Customized\WindowsServer2025.iso -OutputDirectory Y:\IsoBuild\Logs'
Register-ScheduledTask -TaskName 'Test customized ISO' -Action $Action -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest) -Force
Start-ScheduledTask 'Test customized ISO'   # then read the report; Unregister-ScheduledTask when done
```

## Index page

At the end of every run (even if some ISOs failed) the runner calls `New-ImageIndex.ps1`, which
writes `index.html` and `index.json` to the output directory: for each ISO the editions and
versions, the source build, build date, size, SHA-256, removed packages, drivers added,
warnings, its status in the last run, the kept previous ISO, and the post-install ISOs. The page is
self-contained (no external resources), works on a phone, and links to the ISOs relative to
itself, so it can be opened straight from the share. Both files are written beside the target
and swapped in. Set `BuildIndex` to `false` in `runner-config.json` to turn it off, or run it
by hand:

```PowerShell
.\New-ImageIndex.ps1 -OutputDirectory Y:\Images\Customized -SourceDirectory Y:\Images\Standard
```

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
