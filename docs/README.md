# Customize-WindowsIso documentation

Fully updated, trimmed, unattended Windows install media, rebuilt and install-tested every week,
with your own post-install scripts per client and site.

**Start here**

- [How it fits together](overview.md): the weekly pipeline, what's on the share, what happens
  during an install, what's in the repository.
- [An install, step by step](install-walkthrough.md): screenshots of a whole install, from boot to
  the desktop, with the disk picker and the client picker.

**Using it**

- [Install media: USB, Ventoy and VMs](media.md): getting the ISO and the post-install files onto a
  stick or a VM.
- [Post-install scripts](post-install-scripts.md): the `specialize` and `oobe` folders, clients and
  sites, the scripts that come with the repo, Office, the VirtIO guest tools, writing your own.
- [The disk picker](disk-picker.md): choosing the install disk on machines with more than one.

**Running it**

- [Configuration](configuration.md): `config.json` (profiles, what's removed, Setup bypasses),
  `runner-config.json` (paths, driver sets), the answer file, Office.
- [The weekly pipeline](weekly-pipeline.md): the scheduled task, what gets rebuilt, the index page,
  notifications, logs, disk space.
- [Install tests](install-tests.md): the Proxmox test VMs, what's checked, reading the results,
  known issues.
- [Troubleshooting](troubleshooting.md): where to look when an install or a build goes wrong.

The repository's [README](../README.md) is the reference for every script and setting, and
[PLAN.md](../PLAN.md) lists what's done, what's open and the gotchas learned along the way.

## Quick start

**Install a machine**

1. Copy the ISO from `\\<build box>\Customized` and the post-install files
   (`Copy-PostinstallMedia.ps1 -Source \\<build box>\Customized\postinstall -Destination E:\`)
   to a Ventoy stick ([media](media.md)).
2. Boot it, pick the ISO. **It doesn't ask "press any key".** With one disk it installs there without asking; with several the
   [disk picker](disk-picker.md) asks which.
3. Wait. At the first logon, pick the client (and site) in the menu; the scripts run; press Enter.

**Install a VM (Proxmox)**: attach the ISO and `postinstall-client.iso` (or `-server`) as two
DVDs to a q35/OVMF VM with a VirtIO SCSI disk, and start it.

**Add a client**: create `<Client>\` with its scripts (and `<Client>\<Site>\` for per-site ones)
under `oobe` in the post-install source folder: a private copy of `.postinstall` set as
`PostinstallSource` in `runner-config.json`, since client scripts often hold credentials and the
repository is public. The next weekly run puts it on the share; refresh your sticks with
`Copy-PostinstallMedia.ps1` ([post-install scripts](post-install-scripts.md#clients-and-sites-the-picker)).

**Change what's removed from Windows 11**: edit the profile in `config.json`; the next run
rebuilds every ISO ([configuration](configuration.md#profiles-what-each-edition-gets)).
