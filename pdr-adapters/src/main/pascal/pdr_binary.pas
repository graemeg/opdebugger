{
  PDR Debugger - Binary Format Abstraction Layer

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Abstracts binary file format reading behind a common interface so the
  debugger can load OPDF sections from ELF (Linux/FreeBSD), PE/COFF
  (Windows), and Mach-O (macOS) binaries without format-specific code
  leaking into the adapter layer.
}
unit pdr_binary;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, opdf_types;

type
  TBinaryFormat = (bfUnknown, bfELF, bfPE, bfMachO);

  IBinaryReader = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    function ExtractSection(const Name: String): TMemoryStream;
    function FindSymbolAddress(const Name: String): QWord;
    function GetPointerSize: Byte;
    function GetArchitecture: TTargetArch;
  end;

  { Detect binary format from the first bytes of a file or stream }
  function DetectBinaryFormat(const FilePath: String): TBinaryFormat;
  function DetectBinaryFormatFromStream(AStream: TStream): TBinaryFormat;

  { Factory: create the appropriate reader for a binary file.
    Returns nil if the format is unrecognised or the file cannot be opened. }
  function CreateBinaryReader(const FilePath: String): IBinaryReader;


{ ====================================================================
  ELF Reader — supports ELF32 and ELF64
  ==================================================================== }
type
  TELFBinaryReader = class(TInterfacedObject, IBinaryReader)
  private
    FFilePath: String;
    FStream: TFileStream;
    FIs64Bit: Boolean;

    { ELF64 structures }
    function ExtractSection64(const Name: String): TMemoryStream;
    function FindSymbolAddress64(const Name: String): QWord;

    { ELF32 structures }
    function ExtractSection32(const Name: String): TMemoryStream;
    function FindSymbolAddress32(const Name: String): QWord;
  public
    constructor Create(const AFilePath: String);
    destructor Destroy; override;
    function ExtractSection(const Name: String): TMemoryStream;
    function FindSymbolAddress(const Name: String): QWord;
    function GetPointerSize: Byte;
    function GetArchitecture: TTargetArch;
  end;


{ ====================================================================
  PE/COFF Reader — supports PE32 and PE32+ (64-bit)
  ==================================================================== }
type
  TPEBinaryReader = class(TInterfacedObject, IBinaryReader)
  private
    FFilePath: String;
    FStream: TFileStream;
    FIs64Bit: Boolean;
    FMachine: Word;
    FSectionHeaderOffset: Int64;
    FNumberOfSections: Word;

    function ReadPEHeaders: Boolean;
    function FindSectionByName(const Name: String;
      out Offset: QWord; out Size: QWord): Boolean;
  public
    constructor Create(const AFilePath: String);
    destructor Destroy; override;
    function ExtractSection(const Name: String): TMemoryStream;
    function FindSymbolAddress(const Name: String): QWord;
    function GetPointerSize: Byte;
    function GetArchitecture: TTargetArch;
  end;


{ ====================================================================
  Mach-O Reader — supports 32-bit, 64-bit, and fat/universal binaries
  ==================================================================== }
type
  TMachOBinaryReader = class(TInterfacedObject, IBinaryReader)
  private
    FFilePath: String;
    FStream: TFileStream;
    FIs64Bit: Boolean;
    FCPUType: Cardinal;
    FBaseOffset: Int64;

    function FindSliceForHost(out SliceOffset, SliceSize: QWord): Boolean;
    function ReadMachOHeaders: Boolean;
    function FindSection(const SegName, SectName: String;
      out Offset: QWord; out Size: QWord): Boolean;
  public
    constructor Create(const AFilePath: String);
    destructor Destroy; override;
    function ExtractSection(const Name: String): TMemoryStream;
    function FindSymbolAddress(const Name: String): QWord;
    function GetPointerSize: Byte;
    function GetArchitecture: TTargetArch;
  end;


implementation

{ ====================================================================
  Constants and packed record types
  ==================================================================== }

const
  { ELF }
  ELF_MAGIC: array[0..3] of Byte = ($7F, $45, $4C, $46);
  ELFCLASS32 = 1;
  ELFCLASS64 = 2;
  SHT_SYMTAB = 2;

  { ELF machine types }
  EM_386     = 3;
  EM_ARM     = 40;
  EM_X86_64  = 62;
  EM_AARCH64 = 183;
  EM_PPC     = 20;
  EM_PPC64   = 21;

  { PE }
  PE_MAGIC: array[0..1] of Byte = ($4D, $5A);  { 'MZ' }
  PE_SIGNATURE: Cardinal = $00004550;            { 'PE\0\0' }
  PE_OPT_MAGIC_32  = $010B;
  PE_OPT_MAGIC_64  = $020B;

  { PE machine types }
  IMAGE_FILE_MACHINE_I386  = $014C;
  IMAGE_FILE_MACHINE_AMD64 = $8664;
  IMAGE_FILE_MACHINE_ARM   = $01C0;
  IMAGE_FILE_MACHINE_ARM64 = $AA64;

  { Mach-O }
  MH_MAGIC_32    = $FEEDFACE;
  MH_MAGIC_64    = $FEEDFACF;
  MH_CIGAM_32    = $CEFAEDFE;   { byte-swapped 32-bit }
  MH_CIGAM_64    = $CFFAEDFE;   { byte-swapped 64-bit }
  FAT_MAGIC      = $CAFEBABE;
  FAT_CIGAM      = $BEBAFECA;

  { Mach-O load command types }
  LC_SEGMENT     = $01;
  LC_SYMTAB      = $02;
  LC_SEGMENT_64  = $19;

  { Mach-O CPU types }
  CPU_TYPE_I386    = 7;
  CPU_TYPE_X86_64  = 7 or $01000000;
  CPU_TYPE_ARM     = 12;
  CPU_TYPE_ARM64   = 12 or $01000000;
  CPU_TYPE_POWERPC = 18;
  CPU_TYPE_POWERPC64 = 18 or $01000000;

type
  { ELF64 header }
  TElf64Header = packed record
    e_ident: array[0..15] of Byte;
    e_type: Word;
    e_machine: Word;
    e_version: Cardinal;
    e_entry: QWord;
    e_phoff: QWord;
    e_shoff: QWord;
    e_flags: Cardinal;
    e_ehsize: Word;
    e_phentsize: Word;
    e_phnum: Word;
    e_shentsize: Word;
    e_shnum: Word;
    e_shstrndx: Word;
  end;

  TElf64SectionHeader = packed record
    sh_name: Cardinal;
    sh_type: Cardinal;
    sh_flags: QWord;
    sh_addr: QWord;
    sh_offset: QWord;
    sh_size: QWord;
    sh_link: Cardinal;
    sh_info: Cardinal;
    sh_addralign: QWord;
    sh_entsize: QWord;
  end;

  TElf64Sym = packed record
    st_name: Cardinal;
    st_info: Byte;
    st_other: Byte;
    st_shndx: Word;
    st_value: QWord;
    st_size: QWord;
  end;

  { ELF32 header }
  TElf32Header = packed record
    e_ident: array[0..15] of Byte;
    e_type: Word;
    e_machine: Word;
    e_version: Cardinal;
    e_entry: Cardinal;
    e_phoff: Cardinal;
    e_shoff: Cardinal;
    e_flags: Cardinal;
    e_ehsize: Word;
    e_phentsize: Word;
    e_phnum: Word;
    e_shentsize: Word;
    e_shnum: Word;
    e_shstrndx: Word;
  end;

  TElf32SectionHeader = packed record
    sh_name: Cardinal;
    sh_type: Cardinal;
    sh_flags: Cardinal;
    sh_addr: Cardinal;
    sh_offset: Cardinal;
    sh_size: Cardinal;
    sh_link: Cardinal;
    sh_info: Cardinal;
    sh_addralign: Cardinal;
    sh_entsize: Cardinal;
  end;

  TElf32Sym = packed record
    st_name: Cardinal;
    st_value: Cardinal;
    st_size: Cardinal;
    st_info: Byte;
    st_other: Byte;
    st_shndx: Word;
  end;

  { PE/COFF structures }
  TPECOFFHeader = packed record
    Machine: Word;
    NumberOfSections: Word;
    TimeDateStamp: Cardinal;
    PointerToSymbolTable: Cardinal;
    NumberOfSymbols: Cardinal;
    SizeOfOptionalHeader: Word;
    Characteristics: Word;
  end;

  TPESectionHeader = packed record
    Name: array[0..7] of Byte;
    VirtualSize: Cardinal;
    VirtualAddress: Cardinal;
    SizeOfRawData: Cardinal;
    PointerToRawData: Cardinal;
    PointerToRelocations: Cardinal;
    PointerToLinenumbers: Cardinal;
    NumberOfRelocations: Word;
    NumberOfLinenumbers: Word;
    Characteristics: Cardinal;
  end;

  TPECOFFSymbol = packed record
    Name: array[0..7] of Byte;
    Value: Cardinal;
    SectionNumber: SmallInt;
    SymType: Word;
    StorageClass: Byte;
    NumberOfAuxSymbols: Byte;
  end;

  { Mach-O structures }
  TMachHeader32 = packed record
    magic: Cardinal;
    cputype: Cardinal;
    cpusubtype: Cardinal;
    filetype: Cardinal;
    ncmds: Cardinal;
    sizeofcmds: Cardinal;
    flags: Cardinal;
  end;

  TMachHeader64 = packed record
    magic: Cardinal;
    cputype: Cardinal;
    cpusubtype: Cardinal;
    filetype: Cardinal;
    ncmds: Cardinal;
    sizeofcmds: Cardinal;
    flags: Cardinal;
    reserved: Cardinal;
  end;

  TLoadCommand = packed record
    cmd: Cardinal;
    cmdsize: Cardinal;
  end;

  TSegmentCommand32 = packed record
    cmd: Cardinal;
    cmdsize: Cardinal;
    segname: array[0..15] of Char;
    vmaddr: Cardinal;
    vmsize: Cardinal;
    fileoff: Cardinal;
    filesize: Cardinal;
    maxprot: Cardinal;
    initprot: Cardinal;
    nsects: Cardinal;
    flags: Cardinal;
  end;

  TSegmentCommand64 = packed record
    cmd: Cardinal;
    cmdsize: Cardinal;
    segname: array[0..15] of Char;
    vmaddr: QWord;
    vmsize: QWord;
    fileoff: QWord;
    filesize: QWord;
    maxprot: Cardinal;
    initprot: Cardinal;
    nsects: Cardinal;
    flags: Cardinal;
  end;

  TMachOSection32 = packed record
    sectname: array[0..15] of Char;
    segname: array[0..15] of Char;
    addr: Cardinal;
    size: Cardinal;
    offset: Cardinal;
    align_: Cardinal;
    reloff: Cardinal;
    nreloc: Cardinal;
    flags: Cardinal;
    reserved1: Cardinal;
    reserved2: Cardinal;
  end;

  TMachOSection64 = packed record
    sectname: array[0..15] of Char;
    segname: array[0..15] of Char;
    addr: QWord;
    size: QWord;
    offset: Cardinal;
    align_: Cardinal;
    reloff: Cardinal;
    nreloc: Cardinal;
    flags: Cardinal;
    reserved1: Cardinal;
    reserved2: Cardinal;
    reserved3: Cardinal;
  end;

  TSymtabCommand = packed record
    cmd: Cardinal;
    cmdsize: Cardinal;
    symoff: Cardinal;
    nsyms: Cardinal;
    stroff: Cardinal;
    strsize: Cardinal;
  end;

  TNList32 = packed record
    n_strx: Cardinal;
    n_type: Byte;
    n_sect: Byte;
    n_desc: SmallInt;
    n_value: Cardinal;
  end;

  TNList64 = packed record
    n_strx: Cardinal;
    n_type: Byte;
    n_sect: Byte;
    n_desc: Word;
    n_value: QWord;
  end;

  TFatHeader = packed record
    magic: Cardinal;
    nfat_arch: Cardinal;
  end;

  TFatArch = packed record
    cputype: Cardinal;
    cpusubtype: Cardinal;
    offset: Cardinal;
    size: Cardinal;
    align_: Cardinal;
  end;


{ Helper: read a null-terminated string from a byte array }
function ExtractNullTermString(const Buf: array of Byte; StartIdx: Cardinal;
  BufLen: Cardinal): String;
var
  Idx: Cardinal;
begin
  Result := '';
  Idx := StartIdx;
  while (Idx < BufLen) and (Buf[Idx] <> 0) do
  begin
    Result := Result + Chr(Buf[Idx]);
    Inc(Idx);
  end;
end;

function SwapDWord(V: Cardinal): Cardinal;
begin
  Result := ((V and $FF) shl 24) or
            ((V and $FF00) shl 8) or
            ((V and $FF0000) shr 8) or
            ((V and $FF000000) shr 24);
end;

{ Extract a fixed-length null-padded C string (e.g. section names) }
function FixedCString(const Buf: array of Char; Len: Integer): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Len - 1 do
  begin
    if Buf[I] = #0 then
      Break;
    Result := Result + Buf[I];
  end;
end;

function FixedCStringFromBytes(const Buf: array of Byte; Len: Integer): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Len - 1 do
  begin
    if Buf[I] = 0 then
      Break;
    Result := Result + Chr(Buf[I]);
  end;
end;


{ ====================================================================
  Format Detection
  ==================================================================== }

function DetectBinaryFormatFromStream(AStream: TStream): TBinaryFormat;
var
  Magic: array[0..3] of Byte;
  SavePos: Int64;
  BytesRead: Integer;
begin
  Result := bfUnknown;
  SavePos := AStream.Position;
  try
    if AStream.Size < 4 then
      Exit;
    AStream.Position := 0;
    BytesRead := AStream.Read(Magic, 4);
    if BytesRead < 2 then
      Exit;

    { ELF: 7F 45 4C 46 }
    if (BytesRead >= 4) and
       (Magic[0] = $7F) and (Magic[1] = $45) and
       (Magic[2] = $4C) and (Magic[3] = $46) then
    begin
      Result := bfELF;
      Exit;
    end;

    { PE: starts with 'MZ' }
    if (Magic[0] = $4D) and (Magic[1] = $5A) then
    begin
      Result := bfPE;
      Exit;
    end;

    { Mach-O: various magic values (including fat/universal) }
    if BytesRead >= 4 then
    begin
      case PCardinal(@Magic[0])^ of
        MH_MAGIC_32, MH_MAGIC_64, MH_CIGAM_32, MH_CIGAM_64,
        FAT_MAGIC, FAT_CIGAM:
          Result := bfMachO;
      end;
    end;
  finally
    AStream.Position := SavePos;
  end;
end;

function DetectBinaryFormat(const FilePath: String): TBinaryFormat;
var
  F: TFileStream;
begin
  Result := bfUnknown;
  if not FileExists(FilePath) then
    Exit;
  try
    F := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
    try
      Result := DetectBinaryFormatFromStream(F);
    finally
      F.Free;
    end;
  except
    Result := bfUnknown;
  end;
end;


{ ====================================================================
  Factory
  ==================================================================== }

function CreateBinaryReader(const FilePath: String): IBinaryReader;
var
  Fmt: TBinaryFormat;
begin
  Result := nil;
  Fmt := DetectBinaryFormat(FilePath);
  case Fmt of
    bfELF:   Result := TELFBinaryReader.Create(FilePath);
    bfPE:    Result := TPEBinaryReader.Create(FilePath);
    bfMachO: Result := TMachOBinaryReader.Create(FilePath);
  end;
end;


{ ====================================================================
  TELFBinaryReader
  ==================================================================== }

constructor TELFBinaryReader.Create(const AFilePath: String);
var
  ELFClass: Byte;
begin
  inherited Create;
  FFilePath := AFilePath;
  FStream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);

  if FStream.Size < 5 then
    raise Exception.Create('File too small to be an ELF binary');

  FStream.Position := 4;  { skip magic }
  FStream.ReadBuffer(ELFClass, 1);
  FIs64Bit := (ELFClass = ELFCLASS64);
end;

destructor TELFBinaryReader.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

function TELFBinaryReader.GetPointerSize: Byte;
begin
  if FIs64Bit then
    Result := 8
  else
    Result := 4;
end;

function TELFBinaryReader.GetArchitecture: TTargetArch;
var
  Machine: Word;
begin
  FStream.Position := 18;  { e_machine offset is the same for ELF32 and ELF64 }
  FStream.ReadBuffer(Machine, 2);
  case Machine of
    EM_386:     Result := archI386;
    EM_X86_64:  Result := archX86_64;
    EM_ARM:     Result := archARM;
    EM_AARCH64: Result := archAArch64;
    EM_PPC:     Result := archPowerPC;
    EM_PPC64:   Result := archPowerPC64;
  else
    Result := archUnknown;
  end;
end;

function TELFBinaryReader.ExtractSection(const Name: String): TMemoryStream;
begin
  if FIs64Bit then
    Result := ExtractSection64(Name)
  else
    Result := ExtractSection32(Name);
end;

function TELFBinaryReader.FindSymbolAddress(const Name: String): QWord;
begin
  if FIs64Bit then
    Result := FindSymbolAddress64(Name)
  else
    Result := FindSymbolAddress32(Name);
end;

{ ELF64 section extraction }
function TELFBinaryReader.ExtractSection64(const Name: String): TMemoryStream;
var
  Header: TElf64Header;
  SecHeader, StrSecHeader: TElf64SectionHeader;
  StrTable: array of Byte;
  SecName: String;
  I: Integer;
  Buf: array of Byte;
begin
  Result := nil;
  FStream.Position := 0;
  FStream.ReadBuffer(Header, SizeOf(Header));

  if (Header.e_shoff = 0) or (Header.e_shnum = 0) or
     (Header.e_shstrndx >= Header.e_shnum) then
    Exit;

  { Read section header string table }
  FStream.Position := Header.e_shoff + (Header.e_shstrndx * Header.e_shentsize);
  FStream.ReadBuffer(StrSecHeader, SizeOf(StrSecHeader));
  SetLength(StrTable, StrSecHeader.sh_size);
  FStream.Position := StrSecHeader.sh_offset;
  FStream.ReadBuffer(StrTable[0], StrSecHeader.sh_size);

  for I := 0 to Header.e_shnum - 1 do
  begin
    FStream.Position := Header.e_shoff + (I * Header.e_shentsize);
    FStream.ReadBuffer(SecHeader, SizeOf(SecHeader));

    if SecHeader.sh_name >= Cardinal(Length(StrTable)) then
      Continue;

    SecName := ExtractNullTermString(StrTable, SecHeader.sh_name, Length(StrTable));
    if SecName = Name then
    begin
      if SecHeader.sh_size = 0 then
        Exit;
      Result := TMemoryStream.Create;
      SetLength(Buf, SecHeader.sh_size);
      FStream.Position := SecHeader.sh_offset;
      FStream.ReadBuffer(Buf[0], SecHeader.sh_size);
      Result.WriteBuffer(Buf[0], SecHeader.sh_size);
      Result.Position := 0;
      Exit;
    end;
  end;
end;

{ ELF64 symbol lookup }
function TELFBinaryReader.FindSymbolAddress64(const Name: String): QWord;
var
  Header: TElf64Header;
  SecHeader, StrSecHeader: TElf64SectionHeader;
  SymEntry: TElf64Sym;
  StrTable: array of Byte;
  I, J, NumSymbols: Integer;
  SymName, UpperName: String;
begin
  Result := 0;
  UpperName := UpperCase(Name);
  FStream.Position := 0;
  FStream.ReadBuffer(Header, SizeOf(Header));

  if (Header.e_shoff = 0) or (Header.e_shnum = 0) then
    Exit;

  for I := 0 to Header.e_shnum - 1 do
  begin
    FStream.Position := Header.e_shoff + (I * Header.e_shentsize);
    FStream.ReadBuffer(SecHeader, SizeOf(SecHeader));

    if SecHeader.sh_type <> SHT_SYMTAB then
      Continue;

    if SecHeader.sh_link >= Header.e_shnum then
      Exit;

    FStream.Position := Header.e_shoff + (SecHeader.sh_link * Header.e_shentsize);
    FStream.ReadBuffer(StrSecHeader, SizeOf(StrSecHeader));
    SetLength(StrTable, StrSecHeader.sh_size);
    FStream.Position := StrSecHeader.sh_offset;
    FStream.ReadBuffer(StrTable[0], StrSecHeader.sh_size);

    NumSymbols := SecHeader.sh_size div SizeOf(TElf64Sym);
    for J := 0 to NumSymbols - 1 do
    begin
      FStream.Position := SecHeader.sh_offset + (J * SizeOf(TElf64Sym));
      FStream.ReadBuffer(SymEntry, SizeOf(SymEntry));

      if SymEntry.st_name >= Cardinal(Length(StrTable)) then
        Continue;

      SymName := ExtractNullTermString(StrTable, SymEntry.st_name, Length(StrTable));
      if UpperCase(SymName) = UpperName then
      begin
        Result := SymEntry.st_value;
        Exit;
      end;
    end;
    Break;  { only process first .symtab }
  end;
end;

{ ELF32 section extraction }
function TELFBinaryReader.ExtractSection32(const Name: String): TMemoryStream;
var
  Header: TElf32Header;
  SecHeader, StrSecHeader: TElf32SectionHeader;
  StrTable: array of Byte;
  SecName: String;
  I: Integer;
  Buf: array of Byte;
begin
  Result := nil;
  FStream.Position := 0;
  FStream.ReadBuffer(Header, SizeOf(Header));

  if (Header.e_shoff = 0) or (Header.e_shnum = 0) or
     (Header.e_shstrndx >= Header.e_shnum) then
    Exit;

  FStream.Position := Header.e_shoff + (Header.e_shstrndx * Header.e_shentsize);
  FStream.ReadBuffer(StrSecHeader, SizeOf(StrSecHeader));
  SetLength(StrTable, StrSecHeader.sh_size);
  FStream.Position := StrSecHeader.sh_offset;
  FStream.ReadBuffer(StrTable[0], StrSecHeader.sh_size);

  for I := 0 to Header.e_shnum - 1 do
  begin
    FStream.Position := Header.e_shoff + (I * Header.e_shentsize);
    FStream.ReadBuffer(SecHeader, SizeOf(SecHeader));

    if SecHeader.sh_name >= Cardinal(Length(StrTable)) then
      Continue;

    SecName := ExtractNullTermString(StrTable, SecHeader.sh_name, Length(StrTable));
    if SecName = Name then
    begin
      if SecHeader.sh_size = 0 then
        Exit;
      Result := TMemoryStream.Create;
      SetLength(Buf, SecHeader.sh_size);
      FStream.Position := SecHeader.sh_offset;
      FStream.ReadBuffer(Buf[0], SecHeader.sh_size);
      Result.WriteBuffer(Buf[0], SecHeader.sh_size);
      Result.Position := 0;
      Exit;
    end;
  end;
end;

{ ELF32 symbol lookup }
function TELFBinaryReader.FindSymbolAddress32(const Name: String): QWord;
var
  Header: TElf32Header;
  SecHeader, StrSecHeader: TElf32SectionHeader;
  SymEntry: TElf32Sym;
  StrTable: array of Byte;
  I, J, NumSymbols: Integer;
  SymName, UpperName: String;
begin
  Result := 0;
  UpperName := UpperCase(Name);
  FStream.Position := 0;
  FStream.ReadBuffer(Header, SizeOf(Header));

  if (Header.e_shoff = 0) or (Header.e_shnum = 0) then
    Exit;

  for I := 0 to Header.e_shnum - 1 do
  begin
    FStream.Position := Header.e_shoff + (I * Header.e_shentsize);
    FStream.ReadBuffer(SecHeader, SizeOf(SecHeader));

    if SecHeader.sh_type <> SHT_SYMTAB then
      Continue;

    if SecHeader.sh_link >= Header.e_shnum then
      Exit;

    FStream.Position := Header.e_shoff + (SecHeader.sh_link * Header.e_shentsize);
    FStream.ReadBuffer(StrSecHeader, SizeOf(StrSecHeader));
    SetLength(StrTable, StrSecHeader.sh_size);
    FStream.Position := StrSecHeader.sh_offset;
    FStream.ReadBuffer(StrTable[0], StrSecHeader.sh_size);

    NumSymbols := SecHeader.sh_size div SizeOf(TElf32Sym);
    for J := 0 to NumSymbols - 1 do
    begin
      FStream.Position := SecHeader.sh_offset + (J * SizeOf(TElf32Sym));
      FStream.ReadBuffer(SymEntry, SizeOf(SymEntry));

      if SymEntry.st_name >= Cardinal(Length(StrTable)) then
        Continue;

      SymName := ExtractNullTermString(StrTable, SymEntry.st_name, Length(StrTable));
      if UpperCase(SymName) = UpperName then
      begin
        Result := QWord(SymEntry.st_value);
        Exit;
      end;
    end;
    Break;
  end;
end;


{ ====================================================================
  TPEBinaryReader
  ==================================================================== }

constructor TPEBinaryReader.Create(const AFilePath: String);
begin
  inherited Create;
  FFilePath := AFilePath;
  FStream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
  if not ReadPEHeaders then
    raise Exception.Create('Invalid or unsupported PE binary: ' + AFilePath);
end;

destructor TPEBinaryReader.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

function TPEBinaryReader.ReadPEHeaders: Boolean;
var
  DOSHeader: packed record
    e_magic: Word;
    e_padding: array[0..28] of Word;
    e_lfanew: Cardinal;
  end;
  PESig: Cardinal;
  COFFHeader: TPECOFFHeader;
  OptMagic: Word;
begin
  Result := False;

  if FStream.Size < SizeOf(DOSHeader) then
    Exit;

  { Read DOS header to find PE signature offset }
  FStream.Position := 0;
  FStream.ReadBuffer(DOSHeader, SizeOf(DOSHeader));
  if DOSHeader.e_magic <> $5A4D then  { 'MZ' }
    Exit;

  if DOSHeader.e_lfanew + 4 > Cardinal(FStream.Size) then
    Exit;

  { Read PE signature }
  FStream.Position := DOSHeader.e_lfanew;
  FStream.ReadBuffer(PESig, 4);
  if PESig <> PE_SIGNATURE then
    Exit;

  { Read COFF header }
  FStream.ReadBuffer(COFFHeader, SizeOf(COFFHeader));
  FMachine := COFFHeader.Machine;
  FNumberOfSections := COFFHeader.NumberOfSections;

  { Determine PE32 vs PE32+ from optional header magic }
  if COFFHeader.SizeOfOptionalHeader > 0 then
  begin
    FStream.ReadBuffer(OptMagic, 2);
    FIs64Bit := (OptMagic = PE_OPT_MAGIC_64);
    { Skip rest of optional header }
    FStream.Position := FStream.Position - 2 + COFFHeader.SizeOfOptionalHeader;
  end
  else
    FIs64Bit := False;

  FSectionHeaderOffset := FStream.Position;
  Result := True;
end;

function TPEBinaryReader.FindSectionByName(const Name: String;
  out Offset: QWord; out Size: QWord): Boolean;
var
  I: Integer;
  SecHeader: TPESectionHeader;
  SecName: String;
begin
  Result := False;
  Offset := 0;
  Size := 0;

  for I := 0 to FNumberOfSections - 1 do
  begin
    FStream.Position := FSectionHeaderOffset + (I * SizeOf(TPESectionHeader));
    FStream.ReadBuffer(SecHeader, SizeOf(SecHeader));

    SecName := FixedCStringFromBytes(SecHeader.Name, 8);
    if SecName = Name then
    begin
      Offset := SecHeader.PointerToRawData;
      Size := SecHeader.SizeOfRawData;
      Result := True;
      Exit;
    end;
  end;
end;

function TPEBinaryReader.ExtractSection(const Name: String): TMemoryStream;
var
  Offset, Size: QWord;
  Buf: array of Byte;
begin
  Result := nil;
  if not FindSectionByName(Name, Offset, Size) then
    Exit;
  if Size = 0 then
    Exit;

  Result := TMemoryStream.Create;
  try
    SetLength(Buf, Size);
    FStream.Position := Offset;
    FStream.ReadBuffer(Buf[0], Size);
    Result.WriteBuffer(Buf[0], Size);
    Result.Position := 0;
  except
    FreeAndNil(Result);
  end;
end;

function TPEBinaryReader.FindSymbolAddress(const Name: String): QWord;
var
  DOSHeader: packed record
    e_magic: Word;
    e_padding: array[0..28] of Word;
    e_lfanew: Cardinal;
  end;
  PESig: Cardinal;
  COFFHeader: TPECOFFHeader;
  SymEntry: TPECOFFSymbol;
  StrTableOffset: QWord;
  StrTableSize: Cardinal;
  StrTable: array of Byte;
  I: Integer;
  SymName, UpperName: String;
  NameOffset: Cardinal;
begin
  Result := 0;
  UpperName := UpperCase(Name);

  FStream.Position := 0;
  FStream.ReadBuffer(DOSHeader, SizeOf(DOSHeader));
  if DOSHeader.e_magic <> $5A4D then
    Exit;

  FStream.Position := DOSHeader.e_lfanew;
  FStream.ReadBuffer(PESig, 4);
  if PESig <> PE_SIGNATURE then
    Exit;

  FStream.ReadBuffer(COFFHeader, SizeOf(COFFHeader));

  if (COFFHeader.PointerToSymbolTable = 0) or (COFFHeader.NumberOfSymbols = 0) then
    Exit;

  { Read COFF string table (immediately follows symbol table) }
  StrTableOffset := QWord(COFFHeader.PointerToSymbolTable) +
                    QWord(COFFHeader.NumberOfSymbols) * SizeOf(TPECOFFSymbol);
  if StrTableOffset + 4 <= QWord(FStream.Size) then
  begin
    FStream.Position := StrTableOffset;
    FStream.ReadBuffer(StrTableSize, 4);
    if (StrTableSize > 4) and (StrTableOffset + StrTableSize <= QWord(FStream.Size)) then
    begin
      SetLength(StrTable, StrTableSize);
      FStream.Position := StrTableOffset;
      FStream.ReadBuffer(StrTable[0], StrTableSize);
    end
    else
      SetLength(StrTable, 0);
  end
  else
    SetLength(StrTable, 0);

  { Scan symbols }
  for I := 0 to COFFHeader.NumberOfSymbols - 1 do
  begin
    FStream.Position := COFFHeader.PointerToSymbolTable + (I * SizeOf(TPECOFFSymbol));
    FStream.ReadBuffer(SymEntry, SizeOf(SymEntry));

    { COFF symbol name: if first 4 bytes are zero, bytes 4-7 are string table offset }
    if (SymEntry.Name[0] = 0) and (SymEntry.Name[1] = 0) and
       (SymEntry.Name[2] = 0) and (SymEntry.Name[3] = 0) then
    begin
      NameOffset := PCardinal(@SymEntry.Name[4])^;
      if (Length(StrTable) > 0) and (NameOffset < Cardinal(Length(StrTable))) then
        SymName := ExtractNullTermString(StrTable, NameOffset, Length(StrTable))
      else
        Continue;
    end
    else
      SymName := FixedCStringFromBytes(SymEntry.Name, 8);

    if UpperCase(SymName) = UpperName then
    begin
      Result := QWord(SymEntry.Value);
      Exit;
    end;
  end;
end;

function TPEBinaryReader.GetPointerSize: Byte;
begin
  if FIs64Bit then
    Result := 8
  else
    Result := 4;
end;

function TPEBinaryReader.GetArchitecture: TTargetArch;
begin
  case FMachine of
    IMAGE_FILE_MACHINE_I386:  Result := archI386;
    IMAGE_FILE_MACHINE_AMD64: Result := archX86_64;
    IMAGE_FILE_MACHINE_ARM:   Result := archARM;
    IMAGE_FILE_MACHINE_ARM64: Result := archAArch64;
  else
    Result := archUnknown;
  end;
end;


{ ====================================================================
  TMachOBinaryReader
  ==================================================================== }

constructor TMachOBinaryReader.Create(const AFilePath: String);
begin
  inherited Create;
  FFilePath := AFilePath;
  FBaseOffset := 0;
  FStream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
  if not ReadMachOHeaders then
    raise Exception.Create('Invalid or unsupported Mach-O binary: ' + AFilePath);
end;

destructor TMachOBinaryReader.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

function TMachOBinaryReader.FindSliceForHost(out SliceOffset, SliceSize: QWord): Boolean;
var
  FatHdr: TFatHeader;
  FatEntry: TFatArch;
  Magic: Cardinal;
  I: Integer;
  NArch: Cardinal;
  Swapped: Boolean;
begin
  Result := False;
  SliceOffset := 0;
  SliceSize := 0;

  FStream.Position := 0;
  FStream.ReadBuffer(Magic, 4);

  if (Magic <> FAT_MAGIC) and (Magic <> FAT_CIGAM) then
  begin
    { Not a fat binary — the entire file is the Mach-O }
    SliceOffset := 0;
    SliceSize := FStream.Size;
    Result := True;
    Exit;
  end;

  Swapped := (Magic = FAT_CIGAM);

  FStream.Position := 0;
  FStream.ReadBuffer(FatHdr, SizeOf(FatHdr));
  NArch := FatHdr.nfat_arch;
  if Swapped then
    NArch := SwapDWord(NArch);

  { Prefer x86_64, then i386, then first entry }
  for I := 0 to NArch - 1 do
  begin
    FStream.ReadBuffer(FatEntry, SizeOf(FatEntry));
    if Swapped then
    begin
      FatEntry.cputype := SwapDWord(FatEntry.cputype);
      FatEntry.offset := SwapDWord(FatEntry.offset);
      FatEntry.size := SwapDWord(FatEntry.size);
    end;

    if FatEntry.cputype = Cardinal(CPU_TYPE_X86_64) then
    begin
      SliceOffset := FatEntry.offset;
      SliceSize := FatEntry.size;
      Result := True;
      Exit;
    end;
  end;

  { Fall back: take first slice }
  FStream.Position := SizeOf(TFatHeader);
  FStream.ReadBuffer(FatEntry, SizeOf(FatEntry));
  if Swapped then
  begin
    FatEntry.offset := SwapDWord(FatEntry.offset);
    FatEntry.size := SwapDWord(FatEntry.size);
  end;
  SliceOffset := FatEntry.offset;
  SliceSize := FatEntry.size;
  Result := True;
end;

function TMachOBinaryReader.ReadMachOHeaders: Boolean;
var
  Magic: Cardinal;
  SliceOffset, SliceSize: QWord;
begin
  Result := False;

  if FStream.Size < 4 then
    Exit;

  if not FindSliceForHost(SliceOffset, SliceSize) then
    Exit;

  FBaseOffset := SliceOffset;
  FStream.Position := FBaseOffset;
  FStream.ReadBuffer(Magic, 4);

  case Magic of
    MH_MAGIC_64:
      begin
        FIs64Bit := True;
        FStream.Position := FBaseOffset + 4;  { after magic, read cputype }
        FStream.ReadBuffer(FCPUType, 4);
        Result := True;
      end;
    MH_MAGIC_32:
      begin
        FIs64Bit := False;
        FStream.Position := FBaseOffset + 4;
        FStream.ReadBuffer(FCPUType, 4);
        Result := True;
      end;
  else
    Result := False;
  end;
end;

function TMachOBinaryReader.FindSection(const SegName, SectName: String;
  out Offset: QWord; out Size: QWord): Boolean;
var
  Hdr32: TMachHeader32;
  Hdr64: TMachHeader64;
  LC: TLoadCommand;
  Seg32: TSegmentCommand32;
  Seg64: TSegmentCommand64;
  Sect32: TMachOSection32;
  Sect64: TMachOSection64;
  NCmds: Cardinal;
  CmdPos: Int64;
  I, J: Integer;
  CurSegName, CurSectName: String;
begin
  Result := False;
  Offset := 0;
  Size := 0;

  FStream.Position := FBaseOffset;
  if FIs64Bit then
  begin
    FStream.ReadBuffer(Hdr64, SizeOf(Hdr64));
    NCmds := Hdr64.ncmds;
  end
  else
  begin
    FStream.ReadBuffer(Hdr32, SizeOf(Hdr32));
    NCmds := Hdr32.ncmds;
  end;

  for I := 0 to NCmds - 1 do
  begin
    CmdPos := FStream.Position;
    FStream.ReadBuffer(LC, SizeOf(LC));
    FStream.Position := CmdPos;  { rewind to read full command }

    if FIs64Bit and (LC.cmd = LC_SEGMENT_64) then
    begin
      FStream.ReadBuffer(Seg64, SizeOf(Seg64));
      CurSegName := FixedCString(Seg64.segname, 16);

      for J := 0 to Seg64.nsects - 1 do
      begin
        FStream.ReadBuffer(Sect64, SizeOf(Sect64));
        CurSectName := FixedCString(Sect64.sectname, 16);

        if (CurSegName = SegName) and (CurSectName = SectName) then
        begin
          Offset := Sect64.offset;
          Size := Sect64.size;
          Result := True;
          Exit;
        end;
      end;
    end
    else if (not FIs64Bit) and (LC.cmd = LC_SEGMENT) then
    begin
      FStream.ReadBuffer(Seg32, SizeOf(Seg32));
      CurSegName := FixedCString(Seg32.segname, 16);

      for J := 0 to Seg32.nsects - 1 do
      begin
        FStream.ReadBuffer(Sect32, SizeOf(Sect32));
        CurSectName := FixedCString(Sect32.sectname, 16);

        if (CurSegName = SegName) and (CurSectName = SectName) then
        begin
          Offset := Sect32.offset;
          Size := Sect32.size;
          Result := True;
          Exit;
        end;
      end;
    end
    else
      FStream.Position := CmdPos + LC.cmdsize;
  end;
end;

function TMachOBinaryReader.ExtractSection(const Name: String): TMemoryStream;
var
  Offset, Size: QWord;
  Buf: array of Byte;
  SegName, SectName: String;
begin
  Result := nil;

  { Mach-O sections are addressed as segment,section.
    Convention: '.opdf' maps to '__DATA,__opdf'.
    If caller passes the ELF-style name, map it. }
  if (Length(Name) > 0) and (Name[1] = '.') then
  begin
    SegName := '__DATA';
    SectName := '__' + Copy(Name, 2, Length(Name) - 1);
  end
  else if Pos(',', Name) > 0 then
  begin
    SegName := Copy(Name, 1, Pos(',', Name) - 1);
    SectName := Copy(Name, Pos(',', Name) + 1, Length(Name));
  end
  else
  begin
    SegName := '__DATA';
    SectName := Name;
  end;

  if not FindSection(SegName, SectName, Offset, Size) then
    Exit;
  if Size = 0 then
    Exit;

  Result := TMemoryStream.Create;
  try
    SetLength(Buf, Size);
    FStream.Position := FBaseOffset + Int64(Offset);
    FStream.ReadBuffer(Buf[0], Size);
    Result.WriteBuffer(Buf[0], Size);
    Result.Position := 0;
  except
    FreeAndNil(Result);
  end;
end;

function TMachOBinaryReader.FindSymbolAddress(const Name: String): QWord;
var
  Hdr32: TMachHeader32;
  Hdr64: TMachHeader64;
  LC: TLoadCommand;
  SymCmd: TSymtabCommand;
  NCmds: Cardinal;
  CmdPos: Int64;
  I, J: Integer;
  StrTable: array of Byte;
  NL64: TNList64;
  NL32: TNList32;
  SymName, UpperName: String;
begin
  Result := 0;
  UpperName := UpperCase(Name);

  FStream.Position := FBaseOffset;
  if FIs64Bit then
  begin
    FStream.ReadBuffer(Hdr64, SizeOf(Hdr64));
    NCmds := Hdr64.ncmds;
  end
  else
  begin
    FStream.ReadBuffer(Hdr32, SizeOf(Hdr32));
    NCmds := Hdr32.ncmds;
  end;

  for I := 0 to NCmds - 1 do
  begin
    CmdPos := FStream.Position;
    FStream.ReadBuffer(LC, SizeOf(LC));

    if LC.cmd = LC_SYMTAB then
    begin
      FStream.Position := CmdPos;
      FStream.ReadBuffer(SymCmd, SizeOf(SymCmd));

      { Read string table }
      SetLength(StrTable, SymCmd.strsize);
      FStream.Position := FBaseOffset + SymCmd.stroff;
      FStream.ReadBuffer(StrTable[0], SymCmd.strsize);

      { Scan symbols }
      for J := 0 to SymCmd.nsyms - 1 do
      begin
        FStream.Position := FBaseOffset + SymCmd.symoff;
        if FIs64Bit then
        begin
          FStream.Position := FBaseOffset + SymCmd.symoff + (J * SizeOf(TNList64));
          FStream.ReadBuffer(NL64, SizeOf(NL64));

          if NL64.n_strx >= Cardinal(Length(StrTable)) then
            Continue;

          SymName := ExtractNullTermString(StrTable, NL64.n_strx, Length(StrTable));
          { Mach-O symbols have a leading underscore }
          if (Length(SymName) > 0) and (SymName[1] = '_') then
            Delete(SymName, 1, 1);

          if UpperCase(SymName) = UpperName then
          begin
            Result := NL64.n_value;
            Exit;
          end;
        end
        else
        begin
          FStream.Position := FBaseOffset + SymCmd.symoff + (J * SizeOf(TNList32));
          FStream.ReadBuffer(NL32, SizeOf(NL32));

          if NL32.n_strx >= Cardinal(Length(StrTable)) then
            Continue;

          SymName := ExtractNullTermString(StrTable, NL32.n_strx, Length(StrTable));
          if (Length(SymName) > 0) and (SymName[1] = '_') then
            Delete(SymName, 1, 1);

          if UpperCase(SymName) = UpperName then
          begin
            Result := QWord(NL32.n_value);
            Exit;
          end;
        end;
      end;
      Exit;  { only process first LC_SYMTAB }
    end
    else
      FStream.Position := CmdPos + LC.cmdsize;
  end;
end;

function TMachOBinaryReader.GetPointerSize: Byte;
begin
  if FIs64Bit then
    Result := 8
  else
    Result := 4;
end;

function TMachOBinaryReader.GetArchitecture: TTargetArch;
begin
  case FCPUType of
    CPU_TYPE_I386:      Result := archI386;
    CPU_TYPE_X86_64:    Result := archX86_64;
    CPU_TYPE_ARM:       Result := archARM;
    CPU_TYPE_ARM64:     Result := archAArch64;
    CPU_TYPE_POWERPC:   Result := archPowerPC;
    CPU_TYPE_POWERPC64: Result := archPowerPC64;
  else
    Result := archUnknown;
  end;
end;


end.
