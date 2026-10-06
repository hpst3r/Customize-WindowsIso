# Install media: USB, Ventoy and VMs

An install needs two things: the **Windows ISO** (from the share) and the **post-install media**
(the `.postinstall` scripts, plus Office and the VirtIO guest tools). They can be on the same
stick.

## Physical machines: a Ventoy drive (recommended)

[Ventoy](https://www.ventoy.net) boots any ISO copied onto the stick, and leaves the rest of the
stick as a normal drive, which is where the post-install files go:

```text
E:\                                 (the Ventoy data partition)
  Windows11Professional,version26H2.iso
  WindowsServer2025.iso
  ...
  .postinstall\                     \
  office\                            > from the share's postinstall\ folder
  virtio\                           /
```

Copy (and later refresh) the post-install files with `Copy-PostinstallMedia.ps1`. It mirrors only
those three folders, copies only what changed, and touches nothing else on the drive, ISOs
included:

```powershell
.\Copy-PostinstallMedia.ps1 -Source \\<build box>\Customized\postinstall -Destination E:\
```

- `-SkipOffice` leaves out `office\` (3.7 GB): use it for a server-only stick or a slow one.
  Clients then download Office at first logon instead (needs internet; slower).
- `-Source` can also be `postinstall-server.iso` or `postinstall-client.iso`.
- Office installs fastest from an SSD-based stick: Setup reads ~4 GB from it.

Then boot the stick, pick the ISO in Ventoy's menu, and the install runs on its own. The stubs
find `.postinstall` on the Ventoy partition. The [disk picker](disk-picker.md) never offers the
Ventoy stick itself.

## Physical machines: a plain USB stick

Write the ISO to a stick with [Rufus](https://rufus.ie) in its default ISO mode (not DD: Windows
ISOs aren't hybrid images), and turn off Rufus's own "customize Windows installation" options, which
would add a second answer file. Then copy the post-install files onto the same stick, next to
`sources\`, with `Copy-PostinstallMedia.ps1 -Destination <stick>:\`. Or use Ventoy: it's simpler.

Notes:

- The ISO boots **without "press any key"**: remove it after Setup, or the next reboot reinstalls.
- Without the disk picker, **disk 0 is wiped without asking**. With several disks, turn on the
  picker or check which disk is 0.
- `install.esd`/`install.wim` can be over 4 GB; FAT32-only tools may refuse it. Ventoy and Rufus
  handle it.

## Virtual machines (Proxmox)

Attach the Windows ISO and the matching post-install ISO as two DVD drives:

| VM | Second DVD |
|---|---|
| client | `postinstall-client.iso` (scripts, guest tools, Office) |
| server | `postinstall-server.iso` (scripts, guest tools) |

Suggested VM settings (what the install tests use): machine `q35`, BIOS `OVMF (UEFI)` with an EFI
disk with pre-enrolled keys, a TPM 2.0 state disk (Windows 11), SCSI controller
`VirtIO SCSI single`, the disk on `scsi0`, network `VirtIO`, QEMU guest agent on. The images
have the VirtIO storage and network drivers, so Setup sees the disk and the network works at first
logon; the guest tools (balloon, serial, guest agent) install during the first logon.

Avoid attaching a USB disk to an OVMF VM during Setup: the firmware then reads the DVD so slowly
that Setup takes most of an hour to start.

## The post-install folder and ISOs

The weekly run rebuilds them when something changed (scripts, the virtio-win ISO, a new Office
build):

| | Contents | Size |
|---|---|---|
| `postinstall\` (folder on the share) | `.postinstall`, `virtio`, `office` | ~3.7 GB |
| `postinstall-client.iso` | the same, as an ISO | ~3.7 GB |
| `postinstall-server.iso` | `.postinstall`, `virtio` | ~30 MB |

Build one by hand from another folder, e.g. to try script changes on a VM:

```powershell
.\New-PostinstallIso.ps1 -Source C:\temp\my-postinstall -OutPath C:\temp\postinstall-test.iso `
  -VirtIOIsoPath Y:\IsoBuild\Cache\virtio-win.iso -OfficePath Y:\IsoBuild\Cache\office\current
```

`-Source` is the folder that becomes `.postinstall` (with `specialize` and `oobe` in it).
