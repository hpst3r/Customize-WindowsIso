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
- **Install tests:** `ci\Invoke-ImageTests.ps1` installs every image on the Proxmox test node and checks the running machine (see item 2 below). All seven images pass as of 2026-10-06.

## Open decisions

- [ ] **Per-user ContentDeliveryManager values don't stick** (found by the install tests on 25H2, 26H2 and 29xxx): Windows sets `ContentDeliveryAllowed` back to 1 and recreates `ContentDeliveryManager\Subscriptions` for each new user at first logon, whatever the Default profile says. The other 19 values in that group and the policy groups hold. Options: accept it, or set those two per user at logon (Active Setup or a logon task). On Pro the matching policies aren't honored.
- [ ] **BitLocker device encryption:** Windows 11 24H2+ turns on automatic device encryption at install on machines with a TPM and Secure Boot, Pro included (the test VMs' disks are encrypted). Without a Microsoft account sign-in the key isn't escrowed anywhere. Decide whether RMM manages it, or set `PreventDeviceEncryption` in a profile.
- [ ] **SPICE agent:** the VirtIO guest tools are now installed as two MSIs (drivers, guest agent), which leaves out the SPICE agent the all-in-one installer added. Only matters for SPICE consoles.

- [ ] **Notifications:** create `notify.json` from `notify.example.json` (ntfy server/topic and/or SMTP relay on 587 with STARTTLS). Store secrets with `Set-NotificationSecret.ps1`; the task already has the notification step.
- [ ] **`DeleteSourceAfterBuild`** (currently `false`): saves about 60 GB, but any change to the customization makes every image need a re-download (about 7–8 h for all). Turn it on once changes settle.
- [ ] **`iso.DiskPicker`:** turn it on after the VM tests below pass.

## Next

### 1. Test node (Proxmox, separate from prod)
The dedicated node is `llm-pve` (see item 2). Manual cases still to run there:
- **Disk picker, single virtio-scsi disk:** fully unattended install. Check that `C:\Windows\Panther\unattend.xml` targets disk 0.
- **Disk picker, two disks:** the menu appears; pick disk 1; disk 0 is untouched; the `S` key opens Setup's own disk page.
- **Disk picker, USB disk attached:** the USB disk is never offered.
- **Disk picker, SeaBIOS/MBR:** the BIOS install path works.
- **Disk picker, Server 2022:** old Setup works with the picker.
- **Disk picker, no storage driver:** the "no disk" screen appears, then `L` loads `vioscsi.inf` and a rescan finds the disk.
- **VirtIO:** Setup sees the disk with no driver prompt, the network is up at first logon, the guest tools install, and the QEMU guest agent reports.
- **Defender:** the installed machine uses the updated platform at first start.

Full disk-picker steps are in the README.

### 2. Automated install test (#1): built
`ci\Invoke-ImageTests.ps1` on `llm-pve` (node `800g4m`, PVE 9.2, i5-8500, 16 GB), over SSH; see the README. A full run (all seven images) takes about 2.5 hours; one image 10-25 minutes. To do:
- [ ] Register it in the weekly task (after merging): `register-task.ps1 -GetWindowsIsoPath Y:\src\Get-WindowsIso -InstallTests`.
- [ ] Known issue to recheck with each virtio-win release: the QEMU guest agent doesn't install on Insider 29xxx (its VSS provider fails to register); `KnownIssues` in `ci\ci-config.json`.
- [ ] More cases: the disk picker (item 1), the other Server editions, BIOS/SeaBIOS boot, a second disk.

What the first runs found and fixed:
- Six of seven published ISOs predated the VirtIO driver sets, so Setup saw no disk on virtio-scsi (rebuilt).
- First logon hung at an interactive NuGet prompt when the network was down (`15-install-winget.ps1`).
- On Insider 29xxx the guest agent's MSI fails, and the all-in-one guest tools installer then rolled back the drivers too, leaving the machine without network (now two MSIs).
- The sample `10-create-user.ps1` password fails Server's complexity policy: no account, no autologon, first logon stuck at Ctrl-Alt-Del (documented; it warns now).
- WinGet scripts errored on Server Core, where WinGet isn't supported (they skip now).
- `Set-GeckoExtension.ps1` errored on every fresh machine (fixed).
- A build and `New-PostinstallIso.ps1` running at once could detach the virtio-win ISO from under each other (named mutex).

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
- **Windows OpenSSH as SYSTEM** refuses a private key owned by, or granting access to, an individual user ("bad permissions"). Own it by Administrators; grant only SYSTEM and Administrators.
- **`qm guest exec --pass-stdin` times out** against the Windows guest agent. Write data into the guest with the agent's file-write (`pvesh create .../agent/file-write`) and exec without stdin.
- **.NET writes a UTF-8 BOM to a child's stdin** before your data; strip it on the receiving side.
- **QEMU HMP `screendump`** takes the filename first: `screendump /tmp/x.png -f png`.
- **A USB disk on an OVMF VM makes the firmware read the boot DVD extremely slowly** (Setup takes most of an hour to boot). Put extra files on another DVD instead.
- **`XmlDocument.Save(StringWriter)` declares `encoding="utf-16"`**; sent as UTF-8, Server 2022 Setup ignores that answer file. Save to a file.
- **`$(if ...)` inside a hashtable literal** serializes "nothing" as `{}`, which is truthy. Write `if (...) { x } else { $null }`.
- **Single quotes in a scheduled task's `powershell -File` arguments are passed literally** (`-Name 'X*'` filters for `'X*'`).
- **Disk-image mounts are machine-wide:** whoever mounts the virtio-win ISO may have it dismounted by another script (now a named mutex).
- **Filtering processes by command line also matches the shell running the filter.** Exclude `$PID`.
- **fedorapeople.org directory listings are behind a browser challenge,** but direct file links download fine.
