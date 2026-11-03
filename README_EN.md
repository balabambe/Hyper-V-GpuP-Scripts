[繁體中文](README.md) | [English](README_EN.md)
# Hyper-V GPU-P Setup and Virtual Disk Mounting Tool
> **Compatible with both AMD and NVIDIA graphics cards.**

## Terminology

- **Host Windows**: The Windows operating system installed on the physical computer that runs Hyper-V and this script. The physical GPU is managed by Host Windows.
- **VM (Virtual Machine)**: A virtual machine created and managed by Hyper-V.
- **Guest Windows**: The Windows operating system installed and running inside a VM.
- **Physical GPU**: A graphics card installed in the physical computer. GPU-P makes a portion of its resources available to a VM.

This document uses `Host Windows` and `Guest Windows` to distinguish the Windows environment outside a VM from the one inside it. When referring to hardware, it uses the terms "physical computer" and "physical GPU."

## Overview

`Setup-GpuP-Portable.ps1` provides two operations: configure GPU Partitioning (GPU-P) for a VM, or mount the virtual disk currently used by a VM in read/write mode for manual file transfers. GPU-P allows Host Windows and one or more VMs to share the same physical GPU without dedicating the entire GPU to a single VM.

- **GPU setup**: Select a VM, a physical GPU managed by Host Windows, and the virtual disk containing Guest Windows. The script copies the GPU driver files currently used by Host Windows to the appropriate locations in the offline Guest Windows installation, configures the VM's memory-mapped I/O and caching options, and adds a GPU partition adapter for the selected GPU.
- **Disk mounting**: Select a VM and one of its currently attached virtual disks, mount it in read/write mode, and copy files manually. After closing files opened on the disk, press Enter and the script dismounts it. This mode selects the VM's active differencing disk when applicable instead of guessing the base VHD/VHDX filename.

## Use Cases

- **Multiple game instances or account isolation**: Create multiple VMs running Guest Windows, run a separate game client in each VM, and let them share the physical GPU. This can be useful when login environments, configuration files, or application data need to remain isolated.
- **GPU sharing between Host Windows and VMs**: Keep the Host Windows desktop and daily work environment available while providing GPU acceleration to VMs, without installing a separate graphics card for each VM.
- **Testing multiple software environments**: Test drivers, games, graphics applications, or Windows configurations in separate VMs to reduce the risk of test changes affecting Host Windows.
- **Graphics and compute workloads**: Provide supported 3D, video processing, rendering, or GPU compute capabilities to a VM. Available features depend on GPU, driver, and application compatibility.
- **Offline file transfers**: Copy files directly to a VM's virtual disk without starting the VM, then let the script dismount the disk when finished.

GPU-P provides shared resources; it does not give every VM the full performance of the physical GPU. The number of VMs or game instances that can run simultaneously depends on GPU performance and VRAM, CPU capacity, system memory, and workload. Some games may also block or fail to run in a VM because of anti-cheat systems, license terms, or virtualization detection. Check the rules and compatibility of each game before use.

This script only configures the GPU-P adapter and required driver files for one VM. It does not install games, create VMs, adjust game settings, or automatically start multiple VMs. To use the GPU with multiple VMs, run the setup separately for each VM.

The script does not start the VM automatically. After setup completes, start the VM manually and confirm in Device Manager inside Guest Windows that the GPU is working correctly.

## Requirements

- Run the script on Host Windows with Hyper-V enabled.
- Use Windows PowerShell 5.1 and run it as Administrator.
- GPU setup mode requires a physical GPU that supports Hyper-V GPU Partitioning and a working GPU driver installed on Host Windows.
- For GPU setup mode, Guest Windows must be an x64 edition of Windows 10 or Windows 11.
- The VM must be completely shut down before running the script (**it must be Off, not Running or Saved**). Disk-mount mode does not wait for shutdown; it stops immediately if the selected VM is not `Off`.
- The selected virtual disk must not already be mounted by another application, and the volume you intend to use must be accessible. If the Guest Windows disk is locked with BitLocker, GPU setup mode cannot write driver files, and disk-mount mode must be unlocked before you can copy files.
- If you create a complete VM backup in GPU setup mode, the destination must have enough free space for the exported Hyper-V configuration and virtual disks.

## Changes Made by the Script

### GPU Setup Mode

1. Collects the selected GPU's driver packages and related files from Host Windows.
2. Creates a new VM backup, reuses an existing backup, or skips backup according to your selection.
3. Temporarily mounts the selected virtual disk, copies driver files into Guest Windows, and verifies the copied files with SHA-256.
4. Dismounts the virtual disk, then configures `GuestControlledCacheTypes`, Low MMIO, and High MMIO for the VM.
5. Adds the selected physical GPU as the VM's GPU partition adapter.

Before copying drivers, the script creates a file list and a log directory. If you skip backup, all changes are written directly to the virtual disk and no Hyper-V export created by this script will be available for recovery.

### Disk-Mount Mode

1. Confirms that the selected VM is `Off` and prompts you to select one of its currently attached virtual disks.
2. Confirms that the disk file is accessible and not already mounted, then mounts it in read/write mode.
3. Displays each available volume's drive letter, label, file system, and size while you copy files manually.
4. After you close files opened on the disk and press Enter, dismounts the disk mounted by this operation.

This mode does not create a VM backup; every change is written directly to the selected disk. Keep the VM Off and the PowerShell window open while the disk is mounted. If no drive letter is available, inspect the disk in Disk Management, but **do not initialize or format it**.

> **Note:** If the VHDX is stored under `C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\`, File Explorer may report "Access denied" when you open the mounted drive. In that case, use `Copy-Item` in PowerShell running as Administrator, and replace the destination drive letter with the one assigned to the mounted disk:
>
> ```powershell
> Copy-Item -LiteralPath 'C:\YourFolder' -Destination 'D:\' -Recurse
> ```

## Quick Start

1. Place the script in any folder on Host Windows.
2. Completely shut down the target VM from inside Guest Windows **(shut it down; do not save its state)**.
3. For GPU setup, make sure checkpoints are disabled for the target VM. Disk-mount mode uses the disk currently attached to the VM, including an active differencing disk.
4. Open Windows PowerShell 5.1 as Administrator.
5. Change to the folder containing the script, for example:

   ```powershell
   Set-Location "C:\Hyper-V-GpuP-Scripts"
   ```

6. Run the script:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1"
   ```

7. Select an operation, then follow its prompts:

   - **Configure GPU-P and copy GPU drivers**: Select the VM, GPU, virtual disk containing Guest Windows, and backup option. After `SUCCESS` appears, start the VM manually and check the GPU status in Device Manager.
   - **Mount a Hyper-V VM disk READ/WRITE**: Select the VM and disk, then copy files manually after it is mounted. Close files opened on the disk, return to PowerShell, and press Enter to dismount it. Start the VM only after the confirmation message says it is safe to do so.

Do not start the VM or turn off the physical computer while the script is running. The VM's virtual disk will be mounted in Host Windows. In GPU setup mode, ignore any new drive window that opens. In disk-mount mode, use that drive to copy files; the script dismounts it when you finish.

If the script fails, confirm that the terminal reports that the virtual disk was successfully dismounted before attempting to start the VM. If disk-mount mode cannot dismount it, keep the VM Off, close every file opened on the disk, and run the `Dismount-DiskImage` command shown in the terminal.

## Parameters

The following parameters apply to the GPU setup workflow. Disk-mount mode does not create logs or backups.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `-LogRoot <path>` | String | `GpuP-Logs` under the script directory | Specifies the root directory for run logs. Each run creates a subdirectory named with a timestamp and random ID and writes `Files.csv` inside it. |
| `-BackupRoot <path>` | String | Not specified | Specifies the root directory for new complete VM backups. When you choose to create a new backup, the script creates a run-ID subdirectory under this path. If omitted, the script asks for a backup location and defaults to `VM-Backup` under the current run's log directory. |
| `-ReuseBackupPath <path>` | String | Not specified | Specifies where to search for an existing Hyper-V export to reuse. The path must contain exactly one exported backup that matches the selected VM ID and includes virtual disks. No new backup is created. |
| `-SkipBackup` | Switch | Off | Skips the search for existing backups and does not create a new VM backup. Changes are written directly to the virtual disk. This option cannot be used together with `-ReuseBackupPath`. |

Path parameters support environment variables. Relative paths are resolved from PowerShell's current directory when the script is started.

## Backup Options

This section applies only to GPU setup mode. The interactive backup menu appears only when neither `-ReuseBackupPath` nor `-SkipBackup` is specified. When either parameter is provided, the backup menu is skipped, but the interactive menus for selecting a VM, GPU, and virtual disk still appear. Disk-mount mode never displays the backup menu or creates a backup.

- Enter `0` to create a new complete VM backup.
- Enter the number of an existing backup to reuse it.
- Enter `S` to skip backup.
- Enter `Q` to cancel.

Skipping backup writes changes directly to the VM's virtual disk and leaves no Hyper-V export available for recovery.

## Examples

Write logs to a specific location:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -LogRoot "D:\GpuP-Logs"
```

Create new backups under a specific root directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -BackupRoot "E:\Hyper-V-Backups"
```

Reuse an existing backup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -ReuseBackupPath "E:\Hyper-V-Backups\20261014-120000-abcd1234"
```

Skip backup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -SkipBackup
```

Specify both log and new-backup root directories:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -LogRoot "D:\GpuP-Logs" -BackupRoot "E:\Hyper-V-Backups"
```

## References

1. [GPU partitioning](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/gpu-partitioning)
2. [Partition and assign a GPU to a virtual machine](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/partition-assign-vm-gpu?tabs=windows-admin-center)

## Support This Project

If you encounter any issues with the script, please open an Issue to let me know. Contributions are also welcome—fork the project and open a Pull Request (PR). Thank you!

If this script helped you, please consider giving this project a ⭐ Star!
