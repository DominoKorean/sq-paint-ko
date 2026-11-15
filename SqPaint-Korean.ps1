[CmdletBinding()]
param(
    [ValidateSet('Export', 'Apply', 'SaveTranslations')]
    [string]$Mode = 'Apply',
    [string]$AppFolder,
    [string]$Catalog,
    [string]$Translations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$Catalog) { $Catalog = Join-Path $PSScriptRoot 'strings.local.json' }
if (!$Translations) { $Translations = Join-Path $PSScriptRoot 'translations.ko.json' }

# All file offsets below belong to this exact Windows x64 build.
$originalHash = 'D00DB46B461D4A9E32E02B94984E66DF97D2EBBB0640FEDBAC91A5C7576D9AF0'
$resourceDataOffset = 15287074

function Select-AppFolder {
    # Windows PowerShell 5.1's FolderBrowserDialog uses the legacy tree picker.
    if (-not ('SqPaintFolderPicker' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SqPaintFolderPicker
{
    private const uint PickFolders = 0x20;
    private const uint ForceFileSystem = 0x40;
    private const uint FileSystemPath = 0x80058000;
    private const int Cancelled = unchecked((int)0x800704C7);

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    private class FileOpenDialog { }

    // COM requires the native method order, including unused entries.
    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, IntPtr types);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem folder);
        void SetFolder(IShellItem folder);
        void GetFolder(out IShellItem folder);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint format, [MarshalAs(UnmanagedType.LPWStr)] out string name);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        string path, IntPtr bindContext, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    public static string Select(string startFolder)
    {
        var dialog = (IFileDialog)new FileOpenDialog();
        IShellItem folder = null;
        IShellItem selection = null;
        try
        {
            uint options;
            dialog.GetOptions(out options);
            dialog.SetOptions(options | PickFolders | ForceFileSystem);
            dialog.SetTitle("Select the extracted SQ Paint 0.9.0 folder");

            Guid shellItemId = typeof(IShellItem).GUID;
            SHCreateItemFromParsingName(startFolder, IntPtr.Zero, ref shellItemId, out folder);
            dialog.SetDefaultFolder(folder);

            int status = dialog.Show(IntPtr.Zero);
            if (status == Cancelled) return null;
            Marshal.ThrowExceptionForHR(status);

            dialog.GetResult(out selection);
            string path;
            selection.GetDisplayName(FileSystemPath, out path);
            return path;
        }
        finally
        {
            if (selection != null) Marshal.ReleaseComObject(selection);
            if (folder != null) Marshal.ReleaseComObject(folder);
            Marshal.ReleaseComObject(dialog);
        }
    }
}
'@
    }
    return [SqPaintFolderPicker]::Select($PSScriptRoot)
}

function Read-StringResource([byte[]]$Image, [int]$Offset, [int]$Size) {
    $stream = [IO.MemoryStream]::new($Image, $Offset, $Size, $false)
    try {
        $reader = [Resources.ResourceReader]::new($stream)
        try {
            $table = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            foreach ($entry in $reader) {
                if ($entry.Value -isnot [string]) { throw "Unexpected resource type for $($entry.Key)." }
                $table.Add($entry.Key, $entry.Value)
            }
            return $table
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Read-Translations([string]$Path, $English, $Japanese) {
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (!$json -or !$json.TrimStart().StartsWith('[')) {
        throw "Expected a JSON array at '$Path'."
    }
    try { $rows = ConvertFrom-Json -InputObject $json }
    catch { throw "Invalid JSON at '$Path'. Check the quotes, commas, and brackets." }

    $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        if ($row -isnot [pscustomobject] -or
            $null -eq $row.PSObject.Properties['key'] -or $row.key -isnot [string] -or
            $null -eq $row.PSObject.Properties['ko'] -or $row.ko -isnot [string]) {
            throw "Every JSON entry in '$Path' must have string fields 'key' and 'ko'."
        }
        $key = $row.key
        if ([string]::IsNullOrEmpty($key) -or !$English.ContainsKey($key)) { throw "Unknown resource key '$key'." }
        if ($values.ContainsKey($key)) { throw "Duplicate resource key '$key'." }
        $translation = $row.ko
        if (![string]::IsNullOrWhiteSpace($translation)) {
            $source = $Japanese[$key]
            $pattern = '(?<!\{)\{(\d+)(?=[},:])'
            $expected = @([regex]::Matches($source, $pattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $actual = @([regex]::Matches($translation, $pattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            if (($actual -join ',') -cne ($expected -join ',')) {
                throw "Keep the same placeholders as the source for '$key'."
            }
            if ($expected.Count -gt 0) {
                $arguments = [object[]]::new(1 + [int]($expected | Measure-Object -Maximum).Maximum)
                try { [void][string]::Format($translation, $arguments) }
                catch [FormatException] { throw "Invalid format placeholders for '$key'." }
            }
        }
        $values.Add($key, $translation)
    }
    return $values
}

function Write-AtomicFile([string]$Path, [byte[]]$Bytes, [switch]$Replace) {
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $temp = Join-Path ([IO.Path]::GetDirectoryName($destination)) ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ($Replace -and [IO.File]::Exists($destination)) {
            [IO.File]::Replace($temp, $destination, [NullString]::Value)
        } else {
            [IO.File]::Move($temp, $destination)
        }
    } finally {
        [IO.File]::Delete($temp)
    }
}

function Write-Catalog([string]$Path, [object[]]$Rows, [switch]$Replace) {
    $json = ConvertTo-Json -InputObject $Rows
    Write-AtomicFile $Path ([Text.Encoding]::UTF8.GetBytes($json + "`n")) -Replace:$Replace
}

function New-KoreanResource($Source, $Values, [string[]]$Keys) {
    $stream = [IO.MemoryStream]::new()
    try {
        $writer = [Resources.ResourceWriter]::new($stream)
        try {
            foreach ($key in $Keys) {
                $value = $Source[$key]
                if ($Values.ContainsKey($key) -and ![string]::IsNullOrWhiteSpace($Values[$key])) {
                    $value = $Values[$key]
                }
                $writer.AddResource($key, $value)
            }
            $writer.Generate()
            return ,$stream.ToArray()
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Write-NativeUInt($Writer, [int]$Value, [int]$Width) {
    if ($Value -ge (1 -shl (7 * $Width))) { throw 'The Korean resource table is too large for this build.' }
    $bytes = [BitConverter]::GetBytes([uint32](($Value -shl $Width) -bor ((1 -shl ($Width - 1)) - 1)))
    $Writer.Write($bytes, 0, $Width)
}

function Add-ResourceSection([byte[]]$Original, [byte[]]$EnglishResource, [byte[]]$JapaneseResource) {
    # Repack all eight resources. Put the largest asset last among entries whose
    # starting offset must fit in a 3-byte NativeAOT integer.
    $entries = @(
        @{ Index = 17845509; Width = 1; Offset = 0;       Size = 170548 }
        @{ Index = 17845757; Width = 3; Offset = 2048405; Size = 3241 }
        @{ Index = 17845872; Width = 3; Offset = 2051646; Size = 493 }
        @{ Index = 17846097; Width = 3; Offset = 2082706; Size = 141807 }
        @{ Index = 17845983; Width = 3; Bytes = $EnglishResource; Size = $EnglishResource.Length }
        @{ Index = 17845621; Width = 3; Offset = 170548;  Size = 1877857 }
        @{ Index = 17846185; Width = 4; Offset = 2224513; Size = 299477 }
        @{ Index = 17846306; Width = 4; Bytes = $JapaneseResource; Size = $JapaneseResource.Length }
    )

    $peOffset = 256
    $optionalHeader = $peOffset + 24
    $newHeader = 760
    $newRva = [BitConverter]::ToUInt32($Original, $optionalHeader + 56)
    $fileAlignment = [BitConverter]::ToUInt32($Original, $optionalHeader + 36)
    $sectionAlignment = [BitConverter]::ToUInt32($Original, $optionalHeader + 32)
    $rawStart = $Original.Length
    $dataSize = ($entries | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum
    $rawSize = [int]([Math]::Ceiling($dataSize / $fileAlignment) * $fileAlignment)
    $virtualSizeAligned = [int]([Math]::Ceiling($dataSize / $sectionAlignment) * $sectionAlignment)
    $imageBase = [BitConverter]::ToUInt64($Original, $optionalHeader + 24)
    $newImage = [byte[]]::new($rawStart + $rawSize)
    [Array]::Copy($Original, $newImage, $Original.Length)
    $stream = [IO.MemoryStream]::new($newImage)
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        # Add a read-only PE section and update the image header.
        $stream.Position = $peOffset + 6
        $writer.Write([uint16]7)
        $stream.Position = $optionalHeader + 8
        $writer.Write([uint32]([BitConverter]::ToUInt32($Original, $optionalHeader + 8) + $rawSize))
        $stream.Position = $optionalHeader + 56
        $writer.Write([uint32]($newRva + $virtualSizeAligned))
        $stream.Position = $optionalHeader + 64
        $writer.Write([uint32]0)
        $stream.Position = $newHeader
        $writer.Write([Text.Encoding]::ASCII.GetBytes(".sqko`0`0`0"))
        $writer.Write([uint32]$dataSize)
        $writer.Write([uint32]$newRva)
        $writer.Write([uint32]$rawSize)
        $writer.Write([uint32]$rawStart)
        $stream.Position = $newHeader + 36
        $writer.Write([uint32]0x40000040)

        # NativeAOT section 325 (resource data), with two existing relocated VAs.
        $stream.Position = 24115144
        $writer.Write([uint64]($imageBase + $newRva))
        $writer.Write([uint64]($imageBase + $newRva + $dataSize))

        $offset = 0
        foreach ($entry in $entries) {
            $stream.Position = $entry.Index
            Write-NativeUInt $writer $offset $entry.Width
            if ($entry.ContainsKey('Bytes')) {
                Write-NativeUInt $writer $entry.Size 3
                [Array]::Copy($entry.Bytes, 0, $newImage, ($rawStart + $offset), $entry.Size)
            } else {
                [Array]::Copy($Original, ($resourceDataOffset + $entry.Offset), $newImage, ($rawStart + $offset), $entry.Size)
            }
            $offset += $entry.Size
        }
    } finally {
        $writer.Dispose()
    }
    return ,$newImage
}

if ([string]::IsNullOrWhiteSpace($AppFolder)) {
    $AppFolder = Select-AppFolder
    if (!$AppFolder) { return }
}
$folder = (Resolve-Path -LiteralPath $AppFolder).ProviderPath
$data = Join-Path $folder 'data'
$exe = Join-Path $data 'SqPaint.exe'
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw "SqPaint.exe was not found at '$exe'." }
$image = [IO.File]::ReadAllBytes($exe)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $hash = [BitConverter]::ToString($sha.ComputeHash($image)).Replace('-', '')
} finally {
    $sha.Dispose()
}
if ($hash -cne $originalHash) { throw 'This tool requires the original Windows 64-bit SqPaint 0.9.0 executable.' }

$english = Read-StringResource $image 17339213 30567
$japanese = Read-StringResource $image 17811064 34315
$keys = [string[]]@($english.Keys)
[Array]::Sort($keys, [StringComparer]::Ordinal)

switch ($Mode) {
    'Export' {
        $values = Read-Translations $Translations $english $japanese
        $rows = foreach ($key in $keys) {
            [pscustomobject]@{
                key = $key
                group = ($key -split '_', 2)[0]
                en = $english[$key]
                ja = $japanese[$key]
                ko = [string]$values[$key]
            }
        }
        Write-Catalog $Catalog $rows
        Write-Host "Exported $($keys.Count) strings to '$Catalog'."
    }
    'SaveTranslations' {
        $values = Read-Translations $Catalog $english $japanese
        $rows = foreach ($key in $keys) {
            [pscustomobject]@{ key = $key; ko = [string]$values[$key] }
        }
        Write-Catalog $Translations $rows -Replace
        Write-Host "Saved translation-only JSON to '$Translations'."
    }
    'Apply' {
        $catalogPath = $Catalog
        if (!$PSBoundParameters.ContainsKey('Catalog') -and !(Test-Path -LiteralPath $Catalog -PathType Leaf)) {
            $catalogPath = $Translations
        }
        $values = Read-Translations $catalogPath $english $japanese
        $translated = @($values.Values | Where-Object { ![string]::IsNullOrWhiteSpace($_) }).Count
        if ($translated -eq 0) {
            Write-Host 'The Korean strings are empty. No patched executable was generated.'
            return
        }
        $englishResource = New-KoreanResource $english $values $keys
        $japaneseResource = New-KoreanResource $japanese $values $keys
        $patched = Add-ResourceSection $image $englishResource $japaneseResource
        $output = Join-Path $data 'SqPaint.Korean.exe'
        $launcher = Join-Path $folder 'SqPaint-Korean.cmd'
        $launchText = '@echo off' + "`r`n" + 'setlocal DisableDelayedExpansion' + "`r`n" +
            'start "" /d "%~dp0data" "%~dp0data\SqPaint.Korean.exe"' + "`r`n"
        $hasLauncher = Test-Path -LiteralPath $launcher
        if ($hasLauncher) {
            if ([IO.File]::ReadAllText($launcher) -cne $launchText) { throw "A different launcher already exists at '$launcher'." }
        }
        Write-AtomicFile $output $patched -Replace
        if (!$hasLauncher) {
            Write-AtomicFile $launcher ([Text.Encoding]::ASCII.GetBytes($launchText))
        }
        Write-Host "Applied $translated of $($keys.Count) strings. Open '$launcher'."
    }
}
