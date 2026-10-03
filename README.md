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

Besides the drivers in the images, `postinstall.iso` gets `virtio\virtio-win-guest-tools.exe`
from the (first) `virtio-iso` set and its SHA-256, and
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
Put the ISO at the `Path` of the `virtio-iso` set in `runner-config.json`
(default `Y:\IsoBuild\Cache\virtio-win.iso`); replacing it with a newer one rebuilds every ISO
on the next run. Set `Enabled` to false to turn this off.

## Weekly runs

`runner.ps1` customizes every ISO in `InputDirectory` (see `runner-config.json`) one at a
time. It skips an ISO when the output already exists and was built from the same input
with the same config, unattend, stubs, and script. Pass `-Force` to rebuild everything.
Exit code is non-zero if any ISO failed, so Task Scheduler's *Last Run Result* shows it.

`register-task.ps1` registers one weekly task, running as SYSTEM, that runs Get-WindowsIso's
`stub.ps1` and then `runner.ps1`:

```PowerShell
.\register-task.ps1 -GetWindowsIsoPath Y:\src\Get-WindowsIso
```

Logs are in `LogDirectory` (default `Y:\IsoBuild\Logs`). Each ISO has its own
`Customize-<name>-<timestamp>.log`, and DISM's log is in the working directory.
A failed build leaves its working directory in place for troubleshooting.
The next run cleans it up, including any stale mounts.
