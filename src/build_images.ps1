param(
    [string]$BootSectorPath = "boot_sector.bin",
    [string]$BootPath = "boot.bin",
    [string]$KernelPath = "kernel.bin",
    [UInt32]$BootEntryOffset = 0,
    [UInt32]$KernelEntryOffset = 0,
    [string]$RepoRoot = (Resolve-Path "..\..").Path,
    [string]$OutputDir = ".",
    [int]$ImageSizeMB = 64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SectorSize = 512
$MbrPartitionStartLba = [UInt32]2048
$BootRelLba = [UInt32]32
$BootSectors = [UInt32]128
$KernelRelLba = [UInt32]160
$KernelSectors = [UInt32]128
$SuperblockRelLba = [UInt32]8
$PreloadRelLba = [UInt32]288
$XdvfsPartitionType = [byte]0xE3

function Align-Up([int64]$Value, [int64]$Alignment) {
    if ($Alignment -le 0) {
        throw "Alignment must be positive"
    }
    $remainder = $Value % $Alignment
    if ($remainder -eq 0) {
        return $Value
    }
    return $Value + ($Alignment - $remainder)
}

function Write-UInt16Le([byte[]]$Buffer, [int]$Offset, [UInt16]$Value) {
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Copy($bytes, 0, $Buffer, $Offset, 2)
}

function Write-UInt32Le([byte[]]$Buffer, [int]$Offset, [UInt32]$Value) {
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Copy($bytes, 0, $Buffer, $Offset, 4)
}

function Write-UInt64Le([byte[]]$Buffer, [int]$Offset, [UInt64]$Value) {
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Copy($bytes, 0, $Buffer, $Offset, 8)
}

function Write-Ascii([byte[]]$Buffer, [int]$Offset, [string]$Text) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Text)
    [Array]::Copy($bytes, 0, $Buffer, $Offset, $bytes.Length)
}

function Set-Bytes([byte[]]$Buffer, [int64]$Offset, [byte[]]$Data) {
    $end = $Offset + $Data.LongLength
    if ($Offset -lt 0 -or $end -gt $Buffer.LongLength) {
        throw "Write outside of image bounds (offset=$Offset length=$($Data.Length) buffer=$($Buffer.Length))"
    }
    [Array]::Copy($Data, 0, $Buffer, [int]$Offset, $Data.Length)
}

function Get-Crc32([byte[]]$Data) {
    $crc = [uint32]4294967295
    foreach ($b in $Data) {
        $crc = $crc -bxor [uint32]$b
        for ($i = 0; $i -lt 8; $i++) {
            if (($crc -band [uint32]1) -ne 0) {
                $crc = ($crc -shr 1) -bxor [uint32]3988292384
            } else {
                $crc = $crc -shr 1
            }
        }
    }
    return [uint32](-bnot $crc)
}

function Get-RepoRelativePath([string]$RootPath, [string]$Path) {
    $rootResolved = (Resolve-Path $RootPath).Path
    $pathResolved = (Resolve-Path $Path).Path
    if ($pathResolved.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathResolved.Substring($rootResolved.Length).TrimStart([char[]]@('\', '/'))
    }
    return $pathResolved
}

function New-PreloadPayload([string]$RepoRootPath, [int]$SizeMb) {
    $entries = New-Object System.Collections.Generic.List[object]
    $payloadRoots = @(
        "xdv-os\src",
        "xdv-core\src",
        "xdv-edx\src",
        "xdv-shell\src"
    )

$manifestText = @"
XDV preload manifest
image-size-mb=$SizeMb
boot-bin-rel-lba=$BootRelLba
kernel-bin-rel-lba=$KernelRelLba
packages=xdv-os,xdv-core,xdv-edx,xdv-shell
boot-chain=xdv-boot->xdv-kernel->xdv-shell
shell-prompt=#:
commands=cd ls cat mkdir rm echo ps help exit edx
"@
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestText)
    $entries.Add([PSCustomObject]@{
        Path = "xdv/preload.manifest"
        Data = $manifestBytes
    })

    foreach ($rootRel in $payloadRoots) {
        $fullRoot = Join-Path $RepoRootPath $rootRel
        if (-not (Test-Path $fullRoot)) {
            throw "Missing preload root: $fullRoot"
        }
        $files = Get-ChildItem -Path $fullRoot -File -Recurse -Filter *.ds |
            Where-Object { $_.FullName -notmatch '[\\/]target[\\/]' } |
            Sort-Object FullName
        foreach ($file in $files) {
            $entries.Add([PSCustomObject]@{
                Path = (Get-RepoRelativePath $RepoRootPath $file.FullName)
                Data = [System.IO.File]::ReadAllBytes($file.FullName)
            })
        }
    }

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream, [System.Text.Encoding]::UTF8, $true)
    $writer.Write([System.Text.Encoding]::ASCII.GetBytes("XDVFSPLD"))
    $writer.Write([UInt32]1)
    $writer.Write([UInt32]$entries.Count)
    foreach ($entry in $entries) {
        $entryPath = ($entry.Path -replace '\\', '/')
        $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($entryPath)
        if ($pathBytes.Length -gt 65535) {
            throw "Preload path is too long: $entryPath"
        }
        $writer.Write([UInt16]$pathBytes.Length)
        $writer.Write([UInt32]$entry.Data.Length)
        $writer.Write($pathBytes)
        $writer.Write([byte[]]$entry.Data)
    }
    $writer.Flush()
    $payloadBytes = $stream.ToArray()
    $writer.Dispose()
    $stream.Dispose()
    return $payloadBytes
}

function Write-MbrPartitionEntry([byte[]]$Sector, [int]$Index, [byte]$Status, [byte]$Type, [UInt32]$StartLba, [UInt32]$SectorCount) {
    $offset = 446 + (16 * $Index)
    $Sector[$offset + 0] = $Status
    $Sector[$offset + 1] = 0x00
    $Sector[$offset + 2] = 0x02
    $Sector[$offset + 3] = 0x00
    $Sector[$offset + 4] = $Type
    $Sector[$offset + 5] = 0xFE
    $Sector[$offset + 6] = 0xFF
    $Sector[$offset + 7] = 0xFF
    Write-UInt32Le $Sector ($offset + 8) $StartLba
    Write-UInt32Le $Sector ($offset + 12) $SectorCount
}

function Write-XdvfsLayout(
    [byte[]]$Image,
    [UInt32]$PartitionStartLba,
    [UInt32]$PartitionSectorCount,
    [byte[]]$BootBytes,
    [byte[]]$KernelBytes,
    [byte[]]$PayloadBytes,
    [UInt32]$BootEntryOffset,
    [UInt32]$KernelEntryOffset
) {
    if ($BootBytes.Length -gt ($BootSectors * $SectorSize)) {
        throw "boot.bin exceeds configured boot loader read window ($BootSectors sectors)"
    }
    if ($KernelBytes.Length -gt ($KernelSectors * $SectorSize)) {
        throw "kernel.bin exceeds configured kernel window ($KernelSectors sectors)"
    }

    $payloadSectors = [UInt32][Math]::Ceiling($PayloadBytes.Length / [double]$SectorSize)
    $payloadEnd = $PreloadRelLba + $payloadSectors
    if ($payloadEnd -ge $PartitionSectorCount) {
        throw "Preload payload does not fit in partition"
    }

    $bootRecord = New-Object byte[] $SectorSize
    Write-Ascii $bootRecord 0 "XDVFSBR0"
    Write-UInt32Le $bootRecord 8 1
    Write-UInt32Le $bootRecord 12 $SuperblockRelLba
    Write-UInt32Le $bootRecord 16 $BootRelLba
    Write-UInt32Le $bootRecord 20 $BootSectors
    Write-UInt32Le $bootRecord 24 $PreloadRelLba
    Write-UInt32Le $bootRecord 28 ([UInt32]$PayloadBytes.Length)
    Write-UInt32Le $bootRecord 32 $KernelRelLba
    Write-UInt32Le $bootRecord 36 $KernelSectors
    Write-UInt32Le $bootRecord 40 $BootEntryOffset
    Write-UInt32Le $bootRecord 44 $KernelEntryOffset
    $bootRecord[510] = 0x55
    $bootRecord[511] = 0xAA
    Set-Bytes $Image ([int64]$PartitionStartLba * $SectorSize) $bootRecord

    $superblock = New-Object byte[] $SectorSize
    Write-UInt32Le $superblock 0 1479858246
    Write-UInt16Le $superblock 4 1
    Write-UInt16Le $superblock 6 0
    Write-UInt32Le $superblock 8 4096
    Write-UInt64Le $superblock 12 2
    Write-UInt64Le $superblock 20 $PartitionStartLba
    Write-UInt64Le $superblock 28 $PartitionSectorCount
    Write-UInt32Le $superblock 36 $BootRelLba
    Write-UInt32Le $superblock 40 $BootSectors
    Write-UInt32Le $superblock 44 $PreloadRelLba
    Write-UInt32Le $superblock 48 ([UInt32]$PayloadBytes.Length)
    Write-UInt32Le $superblock 52 $KernelRelLba
    Write-UInt32Le $superblock 56 $KernelSectors
    Write-Ascii $superblock 64 "XDVFS-64M"
    Set-Bytes $Image ([int64]($PartitionStartLba + $SuperblockRelLba) * $SectorSize) $superblock

    Set-Bytes $Image ([int64]($PartitionStartLba + $BootRelLba) * $SectorSize) $BootBytes
    Set-Bytes $Image ([int64]($PartitionStartLba + $KernelRelLba) * $SectorSize) $KernelBytes
    Set-Bytes $Image ([int64]($PartitionStartLba + $PreloadRelLba) * $SectorSize) $PayloadBytes
}

function Write-GptPartitionEntry(
    [byte[]]$EntryArray,
    [int]$Index,
    [Guid]$TypeGuid,
    [Guid]$UniqueGuid,
    [UInt64]$FirstLba,
    [UInt64]$LastLba,
    [UInt64]$Attributes,
    [string]$Name
) {
    $offset = $Index * 128
    [Array]::Copy($TypeGuid.ToByteArray(), 0, $EntryArray, $offset, 16)
    [Array]::Copy($UniqueGuid.ToByteArray(), 0, $EntryArray, $offset + 16, 16)
    Write-UInt64Le $EntryArray ($offset + 32) $FirstLba
    Write-UInt64Le $EntryArray ($offset + 40) $LastLba
    Write-UInt64Le $EntryArray ($offset + 48) $Attributes
    $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($Name)
    if ($nameBytes.Length -gt 72) {
        $trimmed = New-Object byte[] 72
        [Array]::Copy($nameBytes, 0, $trimmed, 0, 72)
        $nameBytes = $trimmed
    }
    [Array]::Copy($nameBytes, 0, $EntryArray, $offset + 56, $nameBytes.Length)
}

function Write-GptHeader(
    [byte[]]$Image,
    [UInt64]$CurrentLba,
    [UInt64]$BackupLba,
    [UInt64]$FirstUsableLba,
    [UInt64]$LastUsableLba,
    [byte[]]$DiskGuidBytes,
    [UInt64]$PartitionEntryLba,
    [UInt32]$PartitionEntryCount,
    [UInt32]$PartitionEntrySize,
    [UInt32]$PartitionEntriesCrc32
) {
    $header = New-Object byte[] $SectorSize
    Write-Ascii $header 0 "EFI PART"
    Write-UInt32Le $header 8 0x00010000
    Write-UInt32Le $header 12 92
    Write-UInt32Le $header 16 0
    Write-UInt32Le $header 20 0
    Write-UInt64Le $header 24 $CurrentLba
    Write-UInt64Le $header 32 $BackupLba
    Write-UInt64Le $header 40 $FirstUsableLba
    Write-UInt64Le $header 48 $LastUsableLba
    [Array]::Copy($DiskGuidBytes, 0, $header, 56, 16)
    Write-UInt64Le $header 72 $PartitionEntryLba
    Write-UInt32Le $header 80 $PartitionEntryCount
    Write-UInt32Le $header 84 $PartitionEntrySize
    Write-UInt32Le $header 88 $PartitionEntriesCrc32

    $crcData = New-Object byte[] 92
    [Array]::Copy($header, 0, $crcData, 0, 92)
    $headerCrc = Get-Crc32 $crcData
    Write-UInt32Le $header 16 $headerCrc

    Set-Bytes $Image ([int64]$CurrentLba * $SectorSize) $header
}

function Write-FatDirEntry([byte[]]$Buffer, [int]$Offset, [string]$Name11, [byte]$Attr, [UInt16]$Cluster, [UInt32]$FileSize) {
    if ($Name11.Length -ne 11) {
        throw "FAT entry name must be exactly 11 chars: '$Name11'"
    }
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($Name11), 0, $Buffer, $Offset, 11)
    $Buffer[$Offset + 11] = $Attr
    Write-UInt16Le $Buffer ($Offset + 26) $Cluster
    Write-UInt32Le $Buffer ($Offset + 28) $FileSize
}

function New-UefiStubBinary() {
    $messageBytes = [System.Text.Encoding]::Unicode.GetBytes("XDV UEFI stage online`r`n" + [char]0)
    $codePrefix = [byte[]]@(
        0x48, 0x83, 0xEC, 0x28,
        0x48, 0x8B, 0x42, 0x40,
        0x48, 0x85, 0xC0,
        0x74, 0x10,
        0x48, 0x89, 0xC1,
        0x48, 0x8D, 0x15, 0x0E, 0x00, 0x00, 0x00,
        0x48, 0x8B, 0x41, 0x08,
        0xFF, 0xD0,
        0x48, 0x83, 0xC4, 0x28,
        0x31, 0xC0,
        0xEB, 0xFE
    )

    $sectionSize = $codePrefix.Length + $messageBytes.Length
    $rawSize = [int](Align-Up $sectionSize 0x200)
    $fileSize = 0x200 + $rawSize
    $binary = New-Object byte[] $fileSize

    $binary[0] = 0x4D
    $binary[1] = 0x5A
    Write-UInt32Le $binary 0x3C 0x80

    Write-Ascii $binary 0x80 "PE"
    $binary[0x82] = 0x00
    $binary[0x83] = 0x00

    $coff = 0x84
    Write-UInt16Le $binary ($coff + 0) 0x8664
    Write-UInt16Le $binary ($coff + 2) 1
    Write-UInt32Le $binary ($coff + 4) ([UInt32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Write-UInt32Le $binary ($coff + 8) 0
    Write-UInt32Le $binary ($coff + 12) 0
    Write-UInt16Le $binary ($coff + 16) 0x00F0
    Write-UInt16Le $binary ($coff + 18) 0x0023

    $opt = 0x98
    Write-UInt16Le $binary ($opt + 0) 0x020B
    $binary[$opt + 2] = 14
    $binary[$opt + 3] = 0
    Write-UInt32Le $binary ($opt + 4) ([UInt32]$rawSize)
    Write-UInt32Le $binary ($opt + 8) 0
    Write-UInt32Le $binary ($opt + 12) 0
    Write-UInt32Le $binary ($opt + 16) 0x1000
    Write-UInt32Le $binary ($opt + 20) 0x1000
    Write-UInt64Le $binary ($opt + 24) 0x0000000000100000
    Write-UInt32Le $binary ($opt + 32) 0x1000
    Write-UInt32Le $binary ($opt + 36) 0x200
    Write-UInt16Le $binary ($opt + 40) 2
    Write-UInt16Le $binary ($opt + 42) 0
    Write-UInt16Le $binary ($opt + 44) 0
    Write-UInt16Le $binary ($opt + 46) 0
    Write-UInt16Le $binary ($opt + 48) 2
    Write-UInt16Le $binary ($opt + 50) 0
    Write-UInt32Le $binary ($opt + 52) 0
    Write-UInt32Le $binary ($opt + 56) 0x2000
    Write-UInt32Le $binary ($opt + 60) 0x200
    Write-UInt32Le $binary ($opt + 64) 0
    Write-UInt16Le $binary ($opt + 68) 10
    Write-UInt16Le $binary ($opt + 70) 0
    Write-UInt64Le $binary ($opt + 72) 0x100000
    Write-UInt64Le $binary ($opt + 80) 0x1000
    Write-UInt64Le $binary ($opt + 88) 0x100000
    Write-UInt64Le $binary ($opt + 96) 0x1000
    Write-UInt32Le $binary ($opt + 104) 0
    Write-UInt32Le $binary ($opt + 108) 16

    $section = 0x188
    Write-Ascii $binary $section ".text"
    Write-UInt32Le $binary ($section + 8) ([UInt32]$sectionSize)
    Write-UInt32Le $binary ($section + 12) 0x1000
    Write-UInt32Le $binary ($section + 16) ([UInt32]$rawSize)
    Write-UInt32Le $binary ($section + 20) 0x200
    Write-UInt32Le $binary ($section + 24) 0
    Write-UInt32Le $binary ($section + 28) 0
    Write-UInt16Le $binary ($section + 32) 0
    Write-UInt16Le $binary ($section + 34) 0
    Write-UInt32Le $binary ($section + 36) 0x60000020

    [Array]::Copy($codePrefix, 0, $binary, 0x200, $codePrefix.Length)
    [Array]::Copy($messageBytes, 0, $binary, 0x200 + $codePrefix.Length, $messageBytes.Length)
    return $binary
}

function New-Fat16EspVolume([int]$TotalSectors, [byte[]]$EfiBinary) {
    $bytesPerSector = 512
    $sectorsPerCluster = 1
    $reservedSectors = 1
    $numFats = 2
    $rootEntries = 512
    $sectorsPerFat = 64
    $rootDirSectors = [int](($rootEntries * 32 + ($bytesPerSector - 1)) / $bytesPerSector)
    $firstFatSector = $reservedSectors
    $secondFatSector = $firstFatSector + $sectorsPerFat
    $firstRootSector = $reservedSectors + ($numFats * $sectorsPerFat)
    $firstDataSector = $firstRootSector + $rootDirSectors
    $clusterCapacity = $TotalSectors - $firstDataSector

    $fileClusterCount = [int][Math]::Ceiling($EfiBinary.Length / [double]$bytesPerSector)
    $clusterEfiDir = [UInt16]2
    $clusterBootDir = [UInt16]3
    $clusterFileStart = [UInt16]4
    $clusterFileLast = [UInt16]($clusterFileStart + $fileClusterCount - 1)

    if (($clusterFileLast - 2) -ge $clusterCapacity) {
        throw "ESP is too small for BOOTX64.EFI payload"
    }

    $volume = New-Object byte[] ([int64]$TotalSectors * $bytesPerSector)
    $boot = New-Object byte[] 512
    $boot[0] = 0xEB
    $boot[1] = 0x3C
    $boot[2] = 0x90
    Write-Ascii $boot 3 "XDVFAT16"
    Write-UInt16Le $boot 11 $bytesPerSector
    $boot[13] = [byte]$sectorsPerCluster
    Write-UInt16Le $boot 14 $reservedSectors
    $boot[16] = [byte]$numFats
    Write-UInt16Le $boot 17 $rootEntries
    Write-UInt16Le $boot 19 ([UInt16]$TotalSectors)
    $boot[21] = 0xF8
    Write-UInt16Le $boot 22 $sectorsPerFat
    Write-UInt16Le $boot 24 63
    Write-UInt16Le $boot 26 255
    Write-UInt32Le $boot 28 0
    Write-UInt32Le $boot 32 0
    $boot[36] = 0x80
    $boot[38] = 0x29
    Write-UInt32Le $boot 39 0x58445620
    Write-Ascii $boot 43 "XDVESP     "
    Write-Ascii $boot 54 "FAT16   "
    $boot[510] = 0x55
    $boot[511] = 0xAA
    Set-Bytes $volume 0 $boot

    $fatEntries = ($sectorsPerFat * $bytesPerSector) / 2
    $fat = New-Object UInt16[] $fatEntries
    $fat[0] = 0xFFF8
    $fat[1] = 0xFFFF
    $fat[$clusterEfiDir] = 0xFFFF
    $fat[$clusterBootDir] = 0xFFFF
    for ($cluster = [int]$clusterFileStart; $cluster -le [int]$clusterFileLast; $cluster++) {
        if ($cluster -eq [int]$clusterFileLast) {
            $fat[$cluster] = 0xFFFF
        } else {
            $fat[$cluster] = [UInt16]($cluster + 1)
        }
    }

    $fatBytes = New-Object byte[] ($sectorsPerFat * $bytesPerSector)
    for ($i = 0; $i -lt $fatEntries; $i++) {
        Write-UInt16Le $fatBytes ($i * 2) $fat[$i]
    }
    Set-Bytes $volume ([int64]$firstFatSector * $bytesPerSector) $fatBytes
    Set-Bytes $volume ([int64]$secondFatSector * $bytesPerSector) $fatBytes

    $rootOffset = [int]([int64]$firstRootSector * $bytesPerSector)
    Write-FatDirEntry $volume $rootOffset "EFI        " 0x10 $clusterEfiDir 0

    $efiDirOffset = [int]([int64]($firstDataSector + ($clusterEfiDir - 2)) * $bytesPerSector)
    Write-FatDirEntry $volume ($efiDirOffset + 0) ".          " 0x10 $clusterEfiDir 0
    Write-FatDirEntry $volume ($efiDirOffset + 32) "..         " 0x10 0 0
    Write-FatDirEntry $volume ($efiDirOffset + 64) "BOOT       " 0x10 $clusterBootDir 0

    $bootDirOffset = [int]([int64]($firstDataSector + ($clusterBootDir - 2)) * $bytesPerSector)
    Write-FatDirEntry $volume ($bootDirOffset + 0) ".          " 0x10 $clusterBootDir 0
    Write-FatDirEntry $volume ($bootDirOffset + 32) "..         " 0x10 $clusterEfiDir 0
    Write-FatDirEntry $volume ($bootDirOffset + 64) "BOOTX64 EFI" 0x20 $clusterFileStart ([UInt32]$EfiBinary.Length)

    $bytesRemaining = $EfiBinary.Length
    $srcOffset = 0
    for ($cluster = [int]$clusterFileStart; $cluster -le [int]$clusterFileLast; $cluster++) {
        $dstOffset = [int]([int64]($firstDataSector + ($cluster - 2)) * $bytesPerSector)
        $copyLen = [int][Math]::Min($bytesPerSector, $bytesRemaining)
        [Array]::Copy($EfiBinary, $srcOffset, $volume, $dstOffset, $copyLen)
        $srcOffset += $copyLen
        $bytesRemaining -= $copyLen
    }

    return $volume
}

function Build-MbrImage(
    [byte[]]$BootSector,
    [byte[]]$BootBytes,
    [byte[]]$KernelBytes,
    [byte[]]$PayloadBytes,
    [UInt32]$BootEntryOffset,
    [UInt32]$KernelEntryOffset,
    [int]$SizeMb,
    [string]$OutDir
) {
    $totalSectors = [UInt32](($SizeMb * 1024 * 1024) / $SectorSize)
    if ($totalSectors -le $MbrPartitionStartLba) {
        throw "Image is too small to host a partitioned xdvfs layout"
    }

    $partitionSectors = [UInt32]($totalSectors - $MbrPartitionStartLba)
    $image = New-Object byte[] ([int64]$totalSectors * $SectorSize)
    Set-Bytes $image 0 $BootSector
    Write-MbrPartitionEntry $image 0 0x80 $XdvfsPartitionType $MbrPartitionStartLba $partitionSectors
    Write-UInt16Le $image 510 0xAA55

    Write-XdvfsLayout $image $MbrPartitionStartLba $partitionSectors $BootBytes $KernelBytes $PayloadBytes $BootEntryOffset $KernelEntryOffset

    $outPath = Join-Path $OutDir "xdv-os-mbr-64m.img"
    [System.IO.File]::WriteAllBytes($outPath, $image)
    [System.IO.File]::WriteAllBytes((Join-Path $OutDir "xdv-os.img"), $image)
    return $outPath
}

function Build-UefiImage(
    [byte[]]$BootSector,
    [byte[]]$BootBytes,
    [byte[]]$KernelBytes,
    [byte[]]$PayloadBytes,
    [UInt32]$BootEntryOffset,
    [UInt32]$KernelEntryOffset,
    [int]$SizeMb,
    [string]$OutDir
) {
    $totalSectors = [UInt64](($SizeMb * 1024 * 1024) / $SectorSize)
    $espStartLba = [UInt64]2048
    $espSectors = [UInt64]16384
    $partitionEntryCount = [UInt32]128
    $partitionEntrySize = [UInt32]128
    $partitionArraySectors = [UInt64](($partitionEntryCount * $partitionEntrySize) / $SectorSize)
    $firstUsableLba = [UInt64](2 + $partitionArraySectors)
    $lastUsableLba = [UInt64]($totalSectors - 34)
    $xdvfsStartLba = [UInt64]($espStartLba + $espSectors)
    if ($xdvfsStartLba -gt $lastUsableLba) {
        throw "Image is too small for ESP + XDVFS partition layout"
    }
    $xdvfsSectors = [UInt64]($lastUsableLba - $xdvfsStartLba + 1)

    $image = New-Object byte[] ([int64]$totalSectors * $SectorSize)
    Set-Bytes $image 0 $BootSector
    $protectiveCount = [UInt32][Math]::Min([double]($totalSectors - 1), [double]4294967295)
    Write-MbrPartitionEntry $image 0 0x00 0xEE 1 $protectiveCount
    Write-MbrPartitionEntry $image 1 0x80 $XdvfsPartitionType ([UInt32]$xdvfsStartLba) ([UInt32]$xdvfsSectors)
    Write-UInt16Le $image 510 0xAA55

    $entryArrayBytes = New-Object byte[] ($partitionEntryCount * $partitionEntrySize)
    Write-GptPartitionEntry $entryArrayBytes 0 ([Guid]"C12A7328-F81F-11D2-BA4B-00A0C93EC93B") ([Guid]::NewGuid()) $espStartLba ($espStartLba + $espSectors - 1) 0 "XDV ESP"
    Write-GptPartitionEntry $entryArrayBytes 1 ([Guid]"0FC63DAF-8483-4772-8E79-3D69D8477DE4") ([Guid]::NewGuid()) $xdvfsStartLba ($xdvfsStartLba + $xdvfsSectors - 1) 0 "XDVFS"
    $entryCrc = Get-Crc32 $entryArrayBytes

    $primaryArrayLba = [UInt64]2
    $backupHeaderLba = [UInt64]($totalSectors - 1)
    $backupArrayLba = [UInt64]($totalSectors - 1 - $partitionArraySectors)
    Set-Bytes $image ([int64]$primaryArrayLba * $SectorSize) $entryArrayBytes
    Set-Bytes $image ([int64]$backupArrayLba * $SectorSize) $entryArrayBytes

    $diskGuid = [Guid]::NewGuid().ToByteArray()
    Write-GptHeader $image 1 $backupHeaderLba $firstUsableLba $lastUsableLba $diskGuid $primaryArrayLba $partitionEntryCount $partitionEntrySize $entryCrc
    Write-GptHeader $image $backupHeaderLba 1 $firstUsableLba $lastUsableLba $diskGuid $backupArrayLba $partitionEntryCount $partitionEntrySize $entryCrc

    $efiBinary = New-UefiStubBinary
    $espVolume = New-Fat16EspVolume ([int]$espSectors) $efiBinary
    Set-Bytes $image ([int64]$espStartLba * $SectorSize) $espVolume

    Write-XdvfsLayout $image ([UInt32]$xdvfsStartLba) ([UInt32]$xdvfsSectors) $BootBytes $KernelBytes $PayloadBytes $BootEntryOffset $KernelEntryOffset

    $outPath = Join-Path $OutDir "xdv-os-uefi-64m.img"
    [System.IO.File]::WriteAllBytes($outPath, $image)
    return $outPath
}

if (-not (Test-Path $BootSectorPath)) {
    throw "Missing boot sector: $BootSectorPath"
}
if (-not (Test-Path $BootPath)) {
    throw "Missing boot binary: $BootPath"
}
if (-not (Test-Path $KernelPath)) {
    throw "Missing kernel binary: $KernelPath"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$bootSector = [System.IO.File]::ReadAllBytes((Resolve-Path $BootSectorPath))
if ($bootSector.Length -ne 512) {
    throw "boot_sector.bin must be exactly 512 bytes"
}
$bootBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $BootPath))
$kernelBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $KernelPath))
$preloadPayload = New-PreloadPayload $RepoRoot $ImageSizeMB

$mbrImage = Build-MbrImage $bootSector $bootBytes $kernelBytes $preloadPayload $BootEntryOffset $KernelEntryOffset $ImageSizeMB $OutputDir
$uefiImage = Build-UefiImage $bootSector $bootBytes $kernelBytes $preloadPayload $BootEntryOffset $KernelEntryOffset $ImageSizeMB $OutputDir

Write-Host "Generated images:"
Write-Host "  - $mbrImage"
Write-Host "  - $uefiImage"
Write-Host "  - $(Join-Path $OutputDir 'xdv-os.img') (compat alias to MBR image)"
