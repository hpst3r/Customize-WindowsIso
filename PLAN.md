# Plan

Status and roadmap for the weekly image pipeline: [Get-WindowsIso](https://github.com/hpst3r/Get-WindowsIso)
downloads fully-updated ISOs from uupdump, and this repo customizes them. Last updated 2026-10-05.

## Where things are

| What | Where |
|---|---|
| Build box | `CLAUDE-1` (Windows Server 2025, ADK Deployment Tools 26100) |
| Checkouts the task runs from | `Y:\src\Get-WindowsIso`, `Y:\src\Customize-WindowsIso` (both on `main`) |
| Weekly task | `Weekly Windows Image Build`, SYSTEM, Wednesdays 01:00: `stub.ps1` → `runner.ps1` → `Send-BuildNotification.ps1` |
| Source ISOs | `Y:\Images\Standard` |
| Customized ISOs | `Y:\Images\Customized` (SMB share `Customized`), plus `postinstall-client.iso` / `postinstall-server.iso`, the `postinstall` folder for USB/Ventoy, `index.html`/`index.json` |
| Logs | `Y:\IsoBuild\Logs` (customize), `Y:\src\Get-WindowsIso\logs` (download); `last-run-*.json` summaries |
| Caches | `Y:\IsoBuild\Cache\virtio-win.iso` (updated by hand), `Y:\IsoBuild\Cache\defender`, `winget`, `office` (refreshed by the runner) |

Images built weekly: Windows 11 Pro 25H2, 26H2, Insider 29xxx (latest), Server 2022, Server 2025, Server 2022/2025 Datacenter Core.

## Done

- **Reliable unattended runs:** builds run one at a time, failures clean up after themselves, an ISO is only replaced after the new one is verified, and unchanged images and builds are skipped.
- **Every edition customized:** multi-edition media asks which edition to install. The removal list is trimmed to ads, consumer apps and retired apps. Registry settings land in the default user profile.
- **Driver sets:** VirtIO (vioscsi, viostor, NetKVM) go into Setup, the installed OS and WinRE. Folder sets are available for other boot-critical drivers.
- **Guest tools:** both post-install ISOs carry the VirtIO guest tools and install them silently on VirtIO machines.
- **Microsoft 365 Apps:** client images install Current Channel Office at first logon from the post-install media (`postinstall-client.iso`, or the folder copied to an SSD), with the CDN as fallback.
- **Defender:** Microsoft's offline update is applied to every image; a new platform or engine (about monthly) rebuilds.
- **WinPE disk picker:** built, **off by default** (`iso.DiskPicker`).
- **Ops:** notifications (ntfy and SMTP relay), keeping the previous ISO, the share index, optional deletion of source ISOs with stale detection, and `Test-CustomizedIso.ps1`.
- **ESD output:** optional (`install.Format`).

## Open decisions

- [ ] **Notifications:** create `notify.json` from `notify.example.json` (ntfy server/topic and/or SMTP relay on 587 with STARTTLS). Store secrets with `Set-NotificationSecret.ps1`; the task already has the notification step.
- [ ] **`DeleteSourceAfterBuild`** (currently `false`): saves about 60 GB, but any change to the customization makes every image need a re-download (about 7–8 h for all). Turn it on once changes settle.
- [ ] **`iso.DiskPicker`:** turn it on after the VM tests below pass.

## Next

### 1. Test node (Proxmox, separate from prod)
A dedicated PVE node is coming. Use it for:
- **Disk picker, single virtio-scsi disk:** fully unattended install. Check that `C:\Windows\Panther\unattend.xml` targets disk 0.
- **Disk picker, two disks:** the menu appears; pick disk 1; disk 0 is untouched; the `S` key opens Setup's own disk page.
- **Disk picker, USB disk attached:** the USB disk is never offered.
- **Disk picker, SeaBIOS/MBR:** the BIOS install path works.
- **Disk picker, Server 2022:** old Setup works with the picker.
- **Disk picker, no storage driver:** the "no disk" screen appears, then `L` loads `vioscsi.inf` and a rescan finds the disk.
- **VirtIO:** Setup sees the disk with no driver prompt, the network is up at first logon, the guest tools install, and the QEMU guest agent reports.
- **Defender:** the installed machine uses the updated platform at first start.

Full disk-picker steps are in the README.

### 2. Automated install test (#1)
After each weekly run, on the test node:
1. Boot each new ISO with `postinstall-client.iso` or `postinstall-server.iso` in a throwaway VM (virtio-scsi, no TPM).
2. Wait for the QEMU guest agent.
3. Check the build, the account, the network, that the removed apps are absent, and (clients) that Office installed.
4. Destroy the VM.
5. Report through the notification step.

Needs a Proxmox API token scoped to the test node.

### 3. Switch Dell storage to AHCI from WinPE
Avoids the "no disk" problem without carrying the Intel RST/VMD driver (we run AHCI for performance anyway).
- **What we have:**
  - Dell Command | Configure 5.2.3 is installed on the build box. Its `X86_64` folder (`cctk.exe` and DLLs) runs from a folder.
  - Windows Setup's own `boot.wim` already includes WMI and Windows Script Host, which is what Dell's WinPE recipe adds (`winpe-wmi`, `winpe-scripting`, `net start winmgmt`).
- **To do:**
  1. Run `\\CLAUDE-1\Y$\IsoBuild\dell\Get-DellStorageBiosInfo.ps1` (read-only, or the portable `.zip`) on a few Dell models, at least one with RAID/VMD on. Put the reports in `Y:\IsoBuild\dell\reports`.
  2. Use the reports to learn the setting names and values per model (`EmbSataRaid`/`SataOperation`/VMD) and the controller PCI IDs for detection.
  3. Disk picker: on a Dell with RAID/VMD active, offer "switch storage to AHCI and reboot" with a confirmation. Prompt for the BIOS password if one is set (never stored).
  4. Build: copy the DCC `X86_64` folder (configured path on the build box; Dell's binaries are not in the repo) into the Setup image.
  5. Test on Dell hardware.
- **Later:** HP (BIOS Configuration Utility) and Lenovo, which likely need WMI.

### 4. Housekeeping
- [ ] Delete `*-virtio-test.iso` and `postinstall-virtio-test.iso` from the share once the weekly build includes VirtIO. 26H2 was rebuilt with it on 2026-10-05; the rest follow on the next run.
- [ ] Remote branches `reliability`, `esd-output`, `virtio-drivers` and `next` are merged and can be deleted.
- [ ] Get-WindowsIso's README lists versions that are no longer built weekly; its weekly list is in `config.json`.

## Later

- **HTTP(S) boot:** UEFI HTTP boot or iPXE/wimboot into `boot.wim`, with the disk-picker launcher and the share index as building blocks.
- **Non-English media:** the disk picker parses English diskpart output.
- **Port 465 email:** TLS from the first byte isn't supported by `System.Net.Mail`; use 587 with STARTTLS.
- **Server 2012 R2 Defender:** Microsoft's kit script rejects it, and we follow the script.
- **Intel RST/VMD driver set:** optional if the BIOS switch isn't possible. Extract Intel's F6 package to `Y:\IsoBuild\Drivers\Storage` and enable the `Storage` driver set.

## Gotchas learned the hard way

- **Run DISM servicing through `dism.exe`, not the PowerShell DISM cmdlets.** The cmdlets load the servicing stack in-process, and a transaction left open after a capability removal made the commit fail (0x80071A90) and the discard hang.
- **Never run `dism /Cleanup-Mountpoints` while another build is active.** It acts on every mount on the machine; one build's cleanup removed another's mount record mid-save.
- **uupdump's converter always mounts at `<drive>:\MountUUP`.** Two conversions on one drive corrupt each other, so builds run one at a time.
- **Don't mount `install.wim` with `/Optimize` before removing capabilities.** On newer images the removal fails with 4350.
- **Windows PowerShell 5.1 quirks:**
  - In an advanced script, `$PSScriptRoot` is empty in parameter defaults.
  - `Start-Process -PassThru` reports no exit code unless you touch `.Handle`.
  - Under StrictMode, single results unroll to scalars.
  - `-not @(0)` is true.
  - `[1]` in `-like` is a character class.
- **Sandboxed shells can't load hives or service a mounted image** (error 87, "filename too long"). Run those tests as SYSTEM via a scheduled task.
- **fedorapeople.org directory listings are behind a browser challenge,** but direct file links download fine.
