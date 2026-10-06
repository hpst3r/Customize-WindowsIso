# Install tests

`Test-CustomizedIso.ps1` checks what's *in* an ISO. The install tests check that it actually
**installs and comes up right**: every week, each new ISO is installed in a throwaway VM on the
Proxmox test node (`llm-pve`, node `800g4m`), and the running machine is checked against what the
ISO's manifest and profile promised.

## What a test does

1. **Uploads** the ISO and the CI post-install media to the node (skipped if the node has the same
   SHA-256 already). The CI media is the real `.postinstall` with `ci\postinstall` laid over it:
   the two *Press Enter* pauses become completion markers, the sample account gets a random
   complex password, and the first-logon output is streamed to a serial port.
2. **Creates a VM** like the real targets: q35, OVMF with Secure Boot keys, TPM 2.0,
   virtio-scsi disk, virtio-net. Plus a small per-test DVD with the expected values and the check
   script, and for multi-edition ISOs a copy of the answer file with the edition to test.
3. **Follows Setup** with console screenshots. If nothing new appears on screen for 20 minutes,
   Setup is stuck (a prompt, an error, a boot loop) and the test fails right away with the
   screenshot.
4. **Follows the first logon** through the serial port, where the CI media streams the
   transcript of every script.
5. **Checks** the machine at the end of the first logon (the CI media runs the checks and sends
   the results over the serial port, so they work without the network or the guest agent):

   | Check | Passes when |
   |---|---|
   | post-install: specialize / first-logon scripts | both ran to the end, no script threw; non-terminating errors and `WARNING:` lines are warnings |
   | os: edition, build | the edition, installation type and build are the image's |
   | os: local admin, WinRE | the admin exists and is an administrator; WinRE is enabled |
   | virtio: boot disk, drivers | Windows is on the virtio-scsi disk; the image's drivers are installed |
   | network: adapter, internet | an adapter has an address; msftconnecttest.com answers |
   | virtio: guest tools | the drivers MSI is installed and the QEMU guest agent runs |
   | profile: AppX, capabilities, registry | nothing the profile removes is back; every registry value is set in HKLM and the default profile (the user's own copy: warning) |
   | winget | the provisioned App Installer is at least the version the build added; the software the scripts install with WinGet is there |
   | office | Microsoft 365 Apps is installed, with the right version, product and channel, on images that should have it; absent on the others |
   | defender | platform and engine at least the versions the build added |
   | events | no critical events since install (warning) |

6. **Reports** and destroys the VM. A failed test's VM is kept, stopped, until the next test.

A multi-edition ISO is tested with the editions in `MultiEditionTest` (Datacenter with Desktop
Experience). One test takes 10-25 minutes; all seven images about 2.5 hours.

## When they run

As step 3 of the weekly task (`register-task.ps1 -InstallTests`). An ISO that passed isn't
tested again until it changes; failed ones are retried every run. By hand:

```powershell
cd Y:\src\Customize-WindowsIso\ci
.\Invoke-ImageTests.ps1                      # whatever changed or failed
.\Invoke-ImageTests.ps1 -Name *26H2*         # some ISOs
.\Invoke-ImageTests.ps1 -Force               # everything
.\Test-IsoOnPve.ps1 -IsoPath Y:\Images\Customized\WindowsServer2025.iso `
  -Edition 'Windows Server 2025 Standard' -CiMediaPath Y:\IsoBuild\ci\ci-postinstall.iso
```

Run them as SYSTEM or an administrator (the SSH key is readable only by those).

## Reading the results

- **The notification** has an *Install tests* section; the email version lists each failed and
  warning check.
- **The index page** shows each image's last install test.
- **The details** are in `Y:\IsoBuild\Logs\ci\<iso>-<time>\`:

  | File | |
  |---|---|
  | `result.json` | outcome, timings, every check with its detail |
  | `serial-oobe-transcript.log` | everything the first-logon scripts printed, then the devices without drivers and the network state |
  | `NNNm-*.png` | console screenshots (only new frames are kept) |
  | `expected.json` | what the checks compared against |
  | `autounattend-ci.xml` | the answer file used for multi-edition media |
  | `test.log` | the test's own log |

- **A kept VM** (`9100` on the node) can be started from the Proxmox UI to look around.

## Known issues

A check that fails for a reason that's understood and waiting on someone else can be turned into a
warning in `ci\ci-config.json`, so it doesn't fail every week:

```json
"KnownIssues": [
  { "Iso": "*InsiderPreview29xxx*", "Check": "virtio: guest tools",
    "Reason": "virtio-win 0.1.302's guest agent can't register its VSS provider on Insider 29xxx...",
    "Since": "2026-10-05" }
]
```

Remove the entry when it's fixed: the check then fails again if it isn't.

## Configuration (`ci\ci-config.json`)

| Setting | |
|---|---|
| `Host`, `Node`, `SshUser`, `SshKey`, `KnownHostsFile` | the node and how to reach it (SSH key in `Y:\IsoBuild\Secrets`, readable by SYSTEM and Administrators only; the node's host key is pinned) |
| `IsoStorage`, `IsoDirectory`, `DiskStorage`, `Bridge`, `WorkDirectoryOnNode` | where ISOs and disks go on the node |
| `VmId`, `Cores`, `MemoryMB`, `DiskGB`, `KeepFailedVm` | the test VM |
| `SetupTimeoutMinutes`, `PostinstallTimeoutMinutes`, `StallMinutes`, `ScreenshotMinutes` | patience |
| `ImageDirectory`, `Exclude`, `MultiEditionTest` | what to test |
| `ExpectSoftware` | what the WinGet scripts should have installed, per installation type |
| `KnownIssues` | see above |

The node needs room for one VM (10 GB RAM, a 64 GB thin disk) and three ISOs (~15 GB).

### A new test node

```powershell
ssh-keygen -t ed25519 -N '""' -C image-tests -f Y:\IsoBuild\Secrets\pve_ed25519
# Windows OpenSSH running as SYSTEM refuses a key owned by, or shared with, an individual user:
icacls Y:\IsoBuild\Secrets\pve_ed25519 /setowner *S-1-5-32-544
icacls Y:\IsoBuild\Secrets\pve_ed25519 /inheritance:r /grant:r *S-1-5-18:F *S-1-5-32-544:F
```

On the node, add `from="<build box IP>" <contents of pve_ed25519.pub>` to
`/root/.ssh/authorized_keys`. Then record its host key, after checking the fingerprint against
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the node:

```powershell
ssh -i Y:\IsoBuild\Secrets\pve_ed25519 -o UserKnownHostsFile=Y:\IsoBuild\Secrets\known_hosts root@<node> hostname
```

and set `Host`, `Node` and the storages in `ci\ci-config.json`.
