#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$LogRoot,
    [string]$BackupRoot,
    [string]$ReuseBackupPath,
    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to the caller's PowerShell location.
function Resolve-PortablePath {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($expanded)
}

if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $PSScriptRoot 'GpuP-Logs'
}
$LogRoot = Resolve-PortablePath $LogRoot

if (![string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Resolve-PortablePath $BackupRoot
}
if (![string]::IsNullOrWhiteSpace($ReuseBackupPath)) {
    $ReuseBackupPath = Resolve-PortablePath $ReuseBackupPath
}
if ($SkipBackup -and ![string]::IsNullOrWhiteSpace($ReuseBackupPath)) {
    throw 'SkipBackup and ReuseBackupPath cannot be used together.'
}

# Find exported backups by VM ID, not by a fixed VM name or user path.
function Find-PortableBackups {
    param([string[]]$Roots, [guid]$VMId)

    $found = @{}
    foreach ($root in $Roots) {
        if (!$root -or !(Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $configs = @(Get-ChildItem -LiteralPath $root `
            -Filter '*.vmcx' -Recurse -File -ErrorAction SilentlyContinue)

        foreach ($config in $configs) {
            if ($config.BaseName -ne $VMId.ToString() -or
                $config.Directory.Name -ne 'Virtual Machines') {
                continue
            }

            $vmFolder = $config.Directory.Parent.FullName
            $diskFolder = Join-Path $vmFolder 'Virtual Hard Disks'
            if (!(Test-Path -LiteralPath $diskFolder -PathType Container)) {
                continue
            }

            $disks = @(Get-ChildItem -LiteralPath $diskFolder -File |
                Where-Object { $_.Extension -in '.vhd', '.vhdx', '.avhd', '.avhdx' })

            if (!$disks.Count) { continue }

            $exportRoot = $config.Directory.Parent.Parent.FullName
            $found[$exportRoot] = [pscustomobject]@{
                Root       = $exportRoot
                Config     = $config.FullName
                Disks      = $disks
                Modified   = $config.LastWriteTime
            }
        }
    }

    $found.Values | Sort-Object Modified -Descending
}
Import-Module Hyper-V
Import-Module Storage

function Choose {
    param([object[]]$Items, [string]$Title, [scriptblock]$Label)

    if (!$Items.Count) { throw "Nothing available: $Title" }

    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i + 1), (& $Label $Items[$i]))
    }

    while ($true) {
        $answer = Read-Host 'Enter number, or Q to cancel'
        if ($answer -eq 'Q') { throw 'Cancelled.' }

        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and
            $n -ge 1 -and $n -le $Items.Count) {
            return $Items[$n - 1]
        }
        Write-Host 'Invalid number.' -ForegroundColor Yellow
    }
}

$windowsPrefix = $env:windir.TrimEnd('\') + '\'
$repository = Join-Path $windowsPrefix 'System32\DriverStore\FileRepository\'
$sources = @{}
$packageFolders = @{}

function Add-File {
    param([string]$Path)

    if ([IO.Path]::GetExtension($Path) -ieq '.log') { return }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith(
        $windowsPrefix, [StringComparison]::OrdinalIgnoreCase
    )) { return }

    $relative = $full.Substring($windowsPrefix.Length)
    $storePrefix = 'System32\DriverStore\FileRepository\'

    if ($relative.StartsWith(
        $storePrefix, [StringComparison]::OrdinalIgnoreCase
    )) {
        $relative = 'System32\HostDriverStore\FileRepository\' +
            $relative.Substring($storePrefix.Length)
    }

    $sources[$relative] = $full
}

function Add-Package {
    param([string]$InfPath)

    $folder = Split-Path $InfPath
    if ($packageFolders.ContainsKey($folder)) { return }

    if (!$folder.StartsWith(
        $repository, [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Unexpected driver package path: $folder"
    }

    $packageFolders[$folder] = $true
    Get-ChildItem -LiteralPath $folder -Recurse -File |
        ForEach-Object { Add-File $_.FullName }

    # Include renamed system files listed in INF destination sections.
    $sections = @{}
    $section = ''

    foreach ($raw in Get-Content -LiteralPath $InfPath) {
        $line = ($raw -split ';', 2)[0].Trim()

        if ($line -match '^\[([^\]]+)\]$') {
            $section = $Matches[1]
            if (!$sections.ContainsKey($section)) {
                $sections[$section] =
                    [Collections.Generic.List[string]]::new()
            }
        }
        elseif ($section -and $line) {
            $sections[$section].Add($line)
        }
    }

    if (!$sections.ContainsKey('DestinationDirs')) { return }

    foreach ($line in $sections['DestinationDirs']) {
        if ($line -notmatch '^([^=]+)=\s*(10|11|12)(?:\s*,\s*(.*))?$') {
            continue
        }

        $name = $Matches[1].Trim()
        $id = $Matches[2]
        $sub = $Matches[3]

        if (!$sections.ContainsKey($name)) { continue }

        $base = switch ($id) {
            '10' { $env:windir }
            '11' { Join-Path $env:windir 'System32' }
            '12' { Join-Path $env:windir 'System32\drivers' }
        }

        if ($sub) { $base = Join-Path $base $sub.Trim().Trim('"') }

        foreach ($entry in $sections[$name]) {
            $filename = ($entry -split ',')[0].Trim().Trim('"')
            if ($filename -and $filename -notmatch '[%=\\/]') {
                Add-File (Join-Path $base $filename)
            }
        }
    }
}

$mounted = $false
$vhdPath = $null
$backupCompleted = $false
$backupDir = $null
$backupSkipped = $SkipBackup.IsPresent
$vm = $null

try {
    $vm = Choose @(Get-VM | Sort-Object Name) 'Select VM' {
        param($x)
        '{0} | {1} | Generation {2}' -f $x.Name, $x.State, $x.Generation
    }

    $signed = @(Get-CimInstance Win32_PnPSignedDriver)

    $gpus = @(foreach ($gpu in Get-VMHostPartitionableGpu) {
        if ($gpu.Name -notmatch '^\\\\\?\\([^#]+)#([^#]+)#([^#]+)#') {
            continue
        }

        $id = '{0}\{1}\{2}' -f $Matches[1], $Matches[2], $Matches[3]
        $driver = @($signed | Where-Object DeviceID -eq $id)
        if ($driver.Count -ne 1) { continue }

        [pscustomobject]@{
            Name         = $driver[0].DeviceName
            DeviceId     = $id
            InstancePath = $gpu.Name
            Driver       = $driver[0]
        }
    })

    $selected = Choose $gpus 'Select GPU' {
        param($x)
        '{0} | Driver {1}' -f $x.Name, $x.Driver.DriverVersion
    }

    if ((Get-VM -Id $vm.Id).State -ne 'Off') {
        Write-Host "`nSave your work and shut down the VM from Windows." `
            -ForegroundColor Yellow
        $null = Read-Host 'When the VM is fully Off, press Enter'
    }

    $vm = Get-VM -Id $vm.Id
    if ($vm.State -ne 'Off') {
        throw 'VM must be Off, not Running or Saved.'
    }

    $disks = @(Get-VMHardDiskDrive -VM $vm | Where-Object Path)
    $disk = Choose $disks 'Select the disk containing guest Windows' {
        param($x)
        $x.Path
    }

    if ((Get-VHD -Path $disk.Path).Attached) {
        throw 'The disk is already attached. Close other mounts first.'
    }

    Write-Host "`nDiscovering drivers..."
    $packages = @(Get-WindowsDriver -Online)
    $main = @($packages |
        Where-Object Driver -eq $selected.Driver.InfName)

    if ($main.Count -ne 1) {
        throw 'Cannot identify the selected display driver package.'
    }

    Add-Package $main[0].OriginalFileName

    $associated = @(
    $escapedId = $selected.Driver.DeviceID.Replace('\', '\\')

    foreach ($link in Get-WmiObject `
        -Class Win32_PnPSignedDriverCIMDataFile `
        -ErrorAction Stop) {

        $expected = '*DeviceID="' + $escapedId + '"'
        if ($link.Antecedent -notlike $expected) {
            continue
        }

        if ($link.Dependent -match '\.Name="(.*)"$') {
            [pscustomobject]@{
                Name = $Matches[1].Replace('\\', '\').Replace('\"', '"')
            }
        }
    }
)

    if (!$associated.Count) {
        throw 'Cannot enumerate device-associated driver files.'
    }

    foreach ($file in $associated) {
        Add-File $file.Name

        if ($file.Name.StartsWith(
            $repository, [StringComparison]::OrdinalIgnoreCase
        )) {
            $folderName =
                $file.Name.Substring($repository.Length).Split('\')[0]
            $folder = Join-Path $repository $folderName

            Get-ChildItem -LiteralPath $folder -Filter '*.inf' -File |
                ForEach-Object { Add-Package $_.FullName }
        }
    }

    # AMD uses separate current OpenCL and support packages.
    if ($selected.DeviceId -like 'PCI\VEN_1002*') {
        $activeInfs = @($signed |
            Select-Object -ExpandProperty InfName -Unique)

        foreach ($package in $packages) {
            $name = Split-Path $package.OriginalFileName -Leaf

            if ($package.Driver -in $activeInfs -and
                $package.ProviderName -match 'AMD|Advanced Micro Devices|ATI' -and
                $name -match '^(amdocl|amdwin-[^\\]+|amdfendr|uwppair|amdfdans|amdxe|atihdwt6|amdafd)\.inf$') {
                Add-Package $package.OriginalFileName
            }
        }
    }

    if (!$sources.Count) { throw 'No driver files found.' }

    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    $logDir = Join-Path $LogRoot $runId
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    $plan = @(foreach ($relative in ($sources.Keys | Sort-Object)) {
        [pscustomobject]@{
            RelativePath = $relative
            Source       = $sources[$relative]
        }
    })
    $plan | Export-Csv (Join-Path $logDir 'Files.csv') `
        -NoTypeInformation -Encoding UTF8

    Write-Host 'Checking that all source driver files can be read...'
    foreach ($entry in $plan) {
        $hash = (Get-FileHash -LiteralPath $entry.Source -Algorithm SHA256).Hash
        $entry | Add-Member -NotePropertyName SourceHash -NotePropertyValue $hash
    }

    Write-Host "`nVM: $($vm.Name)"
    Write-Host "GPU: $($selected.Name)"
    Write-Host "Files: $($plan.Count)"
    $backupCompleted = $false
    $chosenBackup = $null

    if ($backupSkipped) {
        Write-Warning 'VM backup was skipped by the SkipBackup parameter.'
        Write-Warning 'Changes will be written directly to the virtual disk without a recovery backup.'
    }
    elseif (![string]::IsNullOrWhiteSpace($ReuseBackupPath)) {
        Write-Host 'Preparing a complete VM export before changes...'
        $matches = @(Find-PortableBackups `
            -Roots @($ReuseBackupPath) -VMId $vm.Id)

        if ($matches.Count -ne 1) {
            throw 'ReuseBackupPath must contain exactly one exported backup of the selected VM.'
        }
        $chosenBackup = $matches[0]
    }
    else {
        Write-Host 'Preparing a complete VM export before changes...'
        $candidates = @(Find-PortableBackups `
            -Roots @($LogRoot, $BackupRoot) -VMId $vm.Id)

        Write-Host "`nBackup options:"
        Write-Host '[0] Create a new complete VM backup'
        Write-Host '[S] Skip backup'

        if ($candidates.Count) {
            Write-Host "`nExisting backups matching the selected VM:"
            for ($i = 0; $i -lt $candidates.Count; $i++) {
                Write-Host ('[{0}] {1}' -f
                    ($i + 1), $candidates[$i].Root)
            }
        }

        while ($true) {
            $answer = Read-Host 'Choose backup option, or Q to cancel'
            if ($answer -eq 'Q') { throw 'Cancelled.' }
            if ($answer -eq 'S') {
                $backupSkipped = $true
                break
            }

            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and
                $number -ge 0 -and
                $number -le $candidates.Count) {

                if ($number -gt 0) {
                    $chosenBackup = $candidates[$number - 1]
                }
                break
            }

            Write-Host 'Invalid backup option.' -ForegroundColor Yellow
        }
    }

    if ((Get-VM -Id $vm.Id).State -ne 'Off') {
        throw 'VM must remain Off during backup and driver setup.'
    }

    if ($backupSkipped) {
        Write-Warning 'Continuing without a VM backup.'
    }
    elseif ($chosenBackup) {
        # Validate disk headers/chains before accepting the backup.
        foreach ($backupDisk in $chosenBackup.Disks) {
            $null = Get-VHD -Path $backupDisk.FullName -ErrorAction Stop
        }

        $backupDir = $chosenBackup.Root
        Write-Host "Using existing backup: $backupDir"
        Write-Host 'This backup represents its original export time.'
    }
    else {
        if (![string]::IsNullOrWhiteSpace($BackupRoot)) {
            $backupDir = Join-Path $BackupRoot $runId
        }
        else {
            $defaultBackup = Join-Path $logDir 'VM-Backup'
            Write-Host "Default backup folder: $defaultBackup"
            $parent = Read-Host 'Enter another backup parent folder, or Enter for default'

            $backupDir = if ([string]::IsNullOrWhiteSpace($parent)) {
                $defaultBackup
            }
            else {
                Join-Path (Resolve-PortablePath $parent.Trim().Trim('"')) $runId
            }
        }

        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Write-Host "Exporting complete VM backup to: $backupDir"
        Write-Host 'This includes virtual disks and may take several minutes.'

        Export-VM -VM $vm -Path $backupDir -ErrorAction Stop
        Write-Host 'VM export completed.'
    }

    if (!$backupSkipped) {
        $backupCompleted = $true
        Write-Host 'Backup ready. Continuing with driver copy.'
    }

    # Read the current VM disk attachment before mounting.
    $currentDisk = @(Get-VMHardDiskDrive -VM $vm |
        Where-Object {
            $_.ControllerType -eq $disk.ControllerType -and
            $_.ControllerNumber -eq $disk.ControllerNumber -and
            $_.ControllerLocation -eq $disk.ControllerLocation
        })

    if ($currentDisk.Count -ne 1) {
        throw 'Cannot identify the active Windows disk after checkpoint.'
    }

    $vhdPath = $currentDisk[0].Path
    if ((Get-VM -Id $vm.Id).State -ne 'Off') {
        throw 'VM state changed; aborting.'
    }
    if ((Get-VHD -Path $vhdPath).Attached) {
        throw 'The active disk is already attached.'
    }

    $mount = Mount-VHD -Path $vhdPath -PassThru
    $mounted = $true

    $volumes = @($mount | Get-Disk | Get-Partition | Get-Volume |
        Where-Object DriveLetter)

    $roots = @(foreach ($volume in $volumes) {
        $root = '{0}:\' -f $volume.DriveLetter
        if (Test-Path -LiteralPath (
            Join-Path $root 'Windows\System32\config\SYSTEM'
        )) {
            $root
        }
    })

    if ($roots.Count -ne 1) {
        throw 'Cannot find one accessible Windows volume. Check disk selection or BitLocker.'
    }

    $guestWindows = Join-Path $roots[0] 'Windows'
    $kernel = Get-Item -LiteralPath (
        Join-Path $guestWindows 'System32\ntoskrnl.exe'
    )
    if ($kernel.VersionInfo.FileMajorPart -ne 10) {
        throw 'Guest must be Windows 10 or Windows 11.'
    }

    $stream = [IO.File]::OpenRead($kernel.FullName)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        $stream.Position = $offset + 4
        if ($reader.ReadUInt16() -ne 0x8664) {
            throw 'Guest must be x64.'
        }
    }
    finally {
        $stream.Dispose()
    }

    $count = 0
    foreach ($entry in $plan) {
        $count++
        Write-Progress -Activity 'Copying and verifying GPU drivers' `
            -Status "$count / $($plan.Count)" `
            -PercentComplete (100 * $count / $plan.Count)

        $target = Join-Path $guestWindows $entry.RelativePath
        New-Item -ItemType Directory -Path (Split-Path $target) `
            -Force | Out-Null

        Copy-Item -LiteralPath $entry.Source -Destination $target -Force

        if ($entry.SourceHash -ne
            (Get-FileHash -LiteralPath $target).Hash) {
            throw "File verification failed: $target"
        }
    }
    Write-Progress -Activity 'Copying and verifying GPU drivers' -Completed

    # Detach before changing VM configuration.
    Dismount-VHD -Path $vhdPath
    $mounted = $false

    $vm = Get-VM -Id $vm.Id
    if ($vm.State -ne 'Off') { throw 'VM state changed; aborting.' }

    Set-VM -VM $vm -GuestControlledCacheTypes $true `
        -LowMemoryMappedIoSpace (
            [uint64][Math]::Max([double]$vm.LowMemoryMappedIoSpace, 1GB)
        ) `
        -HighMemoryMappedIoSpace (
            [uint64][Math]::Max([double]$vm.HighMemoryMappedIoSpace, 8GB)
        )

    $adapters = @(Get-VMGpuPartitionAdapter -VMName $vm.Name)
    $alreadySelected = $adapters.Count -eq 1 -and
        $adapters[0].InstancePath -eq $selected.InstancePath

    if (!$alreadySelected) {
        if ($adapters.Count) {
            Remove-VMGpuPartitionAdapter -VMName $vm.Name
        }
        Add-VMGpuPartitionAdapter -VMName $vm.Name `
            -InstancePath $selected.InstancePath
    }

    $actual = @(Get-VMGpuPartitionAdapter -VMName $vm.Name)
    if ($actual.Count -ne 1 -or
        $actual[0].InstancePath -ne $selected.InstancePath) {
        throw 'GPU selection verification failed.'
    }

    Write-Host "`nSUCCESS: $count files copied and verified." `
        -ForegroundColor Green
    Write-Host "GPU: $($selected.Name)"
    if ($backupCompleted) {
        Write-Host "Complete VM backup: $backupDir"
    }
    else {
        Write-Warning 'Complete VM backup: Skipped'
    }
    Write-Host "File list: $logDir"
    Write-Host 'Start the VM manually and check Device Manager.'
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($backupCompleted -and $vm) {
        Write-Host "Complete VM backup available: $backupDir"
        Write-Host 'If recovery is needed, use Import Virtual Machine after the disk is detached.'
    }
    elseif ($backupSkipped) {
        Write-Warning 'No VM backup is available because backup was skipped.'
    }
    throw
}
finally {
    if ($mounted) {
        try {
            Dismount-VHD -Path $vhdPath -ErrorAction Stop
        }
        catch {
            Write-Warning "Disk remains attached: $vhdPath"
            Write-Warning 'Do not start the VM until the disk is detached.'
        }
    }
}


