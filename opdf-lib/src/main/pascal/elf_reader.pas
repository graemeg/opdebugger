{
  ELF Section Reader - Minimal ELF64 parser for extracting sections

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit provides functionality to extract named sections from
  ELF binaries, used to read embedded OPDF debug data from the
  .opdf section.
}
unit elf_reader;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { Minimal ELF section reader }
  TELFSectionReader = class
  public
    { Check if a file is an ELF binary by reading magic bytes }
    class function IsELFBinary(const FilePath: String): Boolean;

    { Extract a named section from an ELF binary.
      Returns a TMemoryStream containing the section data, or nil if not found.
      Caller owns the returned stream. }
    class function ExtractSection(const BinaryPath: String;
      const SectionName: String): TMemoryStream;

    { Find a symbol's virtual address by name in the ELF .symtab section.
      Returns the symbol's st_value (virtual address), or 0 if not found.
      Comparison is case-insensitive (FPC emits uppercase aliases). }
    class function FindSymbolAddress(const BinaryPath: String;
      const SymbolName: String): QWord;
  end;

implementation

const
  { ELF magic bytes }
  ELF_MAGIC: array[0..3] of Byte = ($7F, $45, $4C, $46); { 0x7F 'E' 'L' 'F' }

  { ELF class }
  ELFCLASS64 = 2;

  { ELF section types }
  SHT_SYMTAB = 2;

type
  { ELF64 header (relevant fields only) }
  TElf64Header = packed record
    e_ident: array[0..15] of Byte;  { Magic number and other info }
    e_type: Word;                    { Object file type }
    e_machine: Word;                 { Architecture }
    e_version: Cardinal;             { Object file version }
    e_entry: QWord;                  { Entry point virtual address }
    e_phoff: QWord;                  { Program header table file offset }
    e_shoff: QWord;                  { Section header table file offset }
    e_flags: Cardinal;               { Processor-specific flags }
    e_ehsize: Word;                  { ELF header size in bytes }
    e_phentsize: Word;               { Program header table entry size }
    e_phnum: Word;                   { Program header table entry count }
    e_shentsize: Word;               { Section header table entry size }
    e_shnum: Word;                   { Section header table entry count }
    e_shstrndx: Word;                { Section header string table index }
  end;

  { ELF64 symbol table entry }
  TElf64Sym = packed record
    st_name  : Cardinal;               { Symbol name (string table index) }
    st_info  : Byte;                   { Symbol type and binding }
    st_other : Byte;                   { Symbol visibility }
    st_shndx : Word;                   { Section index }
    st_value : QWord;                  { Symbol value (virtual address) }
    st_size  : QWord;                  { Symbol size }
  end;

  { ELF64 section header }
  TElf64SectionHeader = packed record
    sh_name: Cardinal;               { Section name (string table index) }
    sh_type: Cardinal;               { Section type }
    sh_flags: QWord;                 { Section flags }
    sh_addr: QWord;                  { Section virtual addr at execution }
    sh_offset: QWord;                { Section file offset }
    sh_size: QWord;                  { Section size in bytes }
    sh_link: Cardinal;               { Link to another section }
    sh_info: Cardinal;               { Additional section information }
    sh_addralign: QWord;             { Section alignment }
    sh_entsize: QWord;               { Entry size if section holds table }
  end;

{ TELFSectionReader }

class function TELFSectionReader.IsELFBinary(const FilePath: String): Boolean;
var
  F: TFileStream;
  Magic: array[0..3] of Byte;
begin
  Result := False;

  if not FileExists(FilePath) then
    Exit;

  try
    F := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
    try
      if F.Size < SizeOf(TElf64Header) then
        Exit;
      F.ReadBuffer(Magic, 4);
      Result := (Magic[0] = ELF_MAGIC[0]) and
                (Magic[1] = ELF_MAGIC[1]) and
                (Magic[2] = ELF_MAGIC[2]) and
                (Magic[3] = ELF_MAGIC[3]);
    finally
      F.Free;
    end;
  except
    Result := False;
  end;
end;

class function TELFSectionReader.ExtractSection(const BinaryPath: String;
  const SectionName: String): TMemoryStream;
var
  F: TFileStream;
  Header: TElf64Header;
  SecHeader: TElf64SectionHeader;
  StrSecHeader: TElf64SectionHeader;
  StrTable: array of Byte;
  SecName: String;
  I: Integer;
  NameIdx: Cardinal;
  Buf: array of Byte;
begin
  Result := nil;

  if not FileExists(BinaryPath) then
    Exit;

  try
    F := TFileStream.Create(BinaryPath, fmOpenRead or fmShareDenyNone);
    try
      { Read ELF header }
      if F.Size < SizeOf(TElf64Header) then
        Exit;
      F.ReadBuffer(Header, SizeOf(Header));

      { Validate ELF magic and class }
      if (Header.e_ident[0] <> ELF_MAGIC[0]) or
         (Header.e_ident[1] <> ELF_MAGIC[1]) or
         (Header.e_ident[2] <> ELF_MAGIC[2]) or
         (Header.e_ident[3] <> ELF_MAGIC[3]) then
        Exit;

      { Only support ELF64 }
      if Header.e_ident[4] <> ELFCLASS64 then
        Exit;

      { Validate section header info }
      if (Header.e_shoff = 0) or (Header.e_shnum = 0) or
         (Header.e_shstrndx >= Header.e_shnum) then
        Exit;

      { Read the section header string table section header }
      F.Position := Header.e_shoff + (Header.e_shstrndx * Header.e_shentsize);
      F.ReadBuffer(StrSecHeader, SizeOf(StrSecHeader));

      { Read the string table contents }
      SetLength(StrTable, StrSecHeader.sh_size);
      F.Position := StrSecHeader.sh_offset;
      F.ReadBuffer(StrTable[0], StrSecHeader.sh_size);

      { Scan all section headers looking for our section }
      for I := 0 to Header.e_shnum - 1 do
      begin
        F.Position := Header.e_shoff + (I * Header.e_shentsize);
        F.ReadBuffer(SecHeader, SizeOf(SecHeader));

        NameIdx := SecHeader.sh_name;
        if NameIdx >= Length(StrTable) then
          Continue;

        { Extract null-terminated section name from string table }
        SecName := '';
        while (NameIdx < Cardinal(Length(StrTable))) and (StrTable[NameIdx] <> 0) do
        begin
          SecName := SecName + Chr(StrTable[NameIdx]);
          Inc(NameIdx);
        end;

        { Check if this is the section we want }
        if SecName = SectionName then
        begin
          if SecHeader.sh_size = 0 then
            Exit;

          { Read section contents into memory stream }
          Result := TMemoryStream.Create;
          SetLength(Buf, SecHeader.sh_size);
          F.Position := SecHeader.sh_offset;
          F.ReadBuffer(Buf[0], SecHeader.sh_size);
          Result.WriteBuffer(Buf[0], SecHeader.sh_size);
          Result.Position := 0;
          Exit;
        end;
      end;
    finally
      F.Free;
    end;
  except
    FreeAndNil(Result);
  end;
end;

class function TELFSectionReader.FindSymbolAddress(const BinaryPath: String;
  const SymbolName: String): QWord;
var
  F: TFileStream;
  Header: TElf64Header;
  SecHeader, StrSecHeader: TElf64SectionHeader;
  SymEntry: TElf64Sym;
  StrTable: array of Byte;
  I, J: Integer;
  NumSymbols: Integer;
  NameIdx: Cardinal;
  Name: String;
  UpperSymName: String;
begin
  Result := 0;

  if not FileExists(BinaryPath) then
    Exit;

  UpperSymName := UpperCase(SymbolName);

  try
    F := TFileStream.Create(BinaryPath, fmOpenRead or fmShareDenyNone);
    try
      { Read ELF header }
      if F.Size < SizeOf(TElf64Header) then
        Exit;
      F.ReadBuffer(Header, SizeOf(Header));

      { Validate ELF magic and class }
      if (Header.e_ident[0] <> ELF_MAGIC[0]) or
         (Header.e_ident[1] <> ELF_MAGIC[1]) or
         (Header.e_ident[2] <> ELF_MAGIC[2]) or
         (Header.e_ident[3] <> ELF_MAGIC[3]) then
        Exit;

      if Header.e_ident[4] <> ELFCLASS64 then
        Exit;

      if (Header.e_shoff = 0) or (Header.e_shnum = 0) then
        Exit;

      { Scan section headers for SHT_SYMTAB }
      for I := 0 to Header.e_shnum - 1 do
      begin
        F.Position := Header.e_shoff + (I * Header.e_shentsize);
        F.ReadBuffer(SecHeader, SizeOf(SecHeader));

        if SecHeader.sh_type <> SHT_SYMTAB then
          Continue;

        { Found .symtab — read associated string table (sh_link) }
        if SecHeader.sh_link >= Header.e_shnum then
          Exit;

        F.Position := Header.e_shoff + (SecHeader.sh_link * Header.e_shentsize);
        F.ReadBuffer(StrSecHeader, SizeOf(StrSecHeader));

        SetLength(StrTable, StrSecHeader.sh_size);
        F.Position := StrSecHeader.sh_offset;
        F.ReadBuffer(StrTable[0], StrSecHeader.sh_size);

        { Iterate symbol entries }
        NumSymbols := SecHeader.sh_size div SizeOf(TElf64Sym);
        for J := 0 to NumSymbols - 1 do
        begin
          F.Position := SecHeader.sh_offset + (J * SizeOf(TElf64Sym));
          F.ReadBuffer(SymEntry, SizeOf(SymEntry));

          NameIdx := SymEntry.st_name;
          if NameIdx >= Cardinal(Length(StrTable)) then
            Continue;

          { Extract null-terminated symbol name }
          Name := '';
          while (NameIdx < Cardinal(Length(StrTable))) and (StrTable[NameIdx] <> 0) do
          begin
            Name := Name + Chr(StrTable[NameIdx]);
            Inc(NameIdx);
          end;

          { Case-insensitive comparison }
          if UpperCase(Name) = UpperSymName then
          begin
            Result := SymEntry.st_value;
            Exit;
          end;
        end;

        { Only process first .symtab section }
        Break;
      end;
    finally
      F.Free;
    end;
  except
    Result := 0;
  end;
end;

end.
