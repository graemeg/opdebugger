{
  Binary Reader Unit Tests

  Builds synthetic ELF32, ELF64, PE32, PE32+, Mach-O 32, and Mach-O 64
  binaries in temporary files, then verifies that the binary format
  abstraction layer can correctly:
    - detect the format
    - extract named sections
    - look up symbol addresses
    - report pointer size and architecture

  Also tests edge cases: missing sections, empty files, corrupt headers,
  and the factory function.
}
program test_binary_readers;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, pdr_binary, opdf_types;

const
  { ELF machine types }
  TEST_EM_386     = 3;
  TEST_EM_ARM     = 40;
  TEST_EM_X86_64  = 62;
  TEST_EM_AARCH64 = 183;

  { PE machine types }
  TEST_IMAGE_FILE_MACHINE_I386  = $014C;
  TEST_IMAGE_FILE_MACHINE_AMD64 = $8664;
  TEST_IMAGE_FILE_MACHINE_ARM   = $01C0;
  TEST_IMAGE_FILE_MACHINE_ARM64 = $AA64;

  { Mach-O magic values }
  TEST_MH_MAGIC_32 = $FEEDFACE;
  TEST_MH_MAGIC_64 = $FEEDFACF;

  { Mach-O load command types }
  TEST_LC_SEGMENT    = $01;
  TEST_LC_SYMTAB     = $02;
  TEST_LC_SEGMENT_64 = $19;

  { Mach-O CPU types }
  TEST_CPU_TYPE_I386      = 7;
  TEST_CPU_TYPE_X86_64    = 7 or $01000000;
  TEST_CPU_TYPE_ARM       = 12;
  TEST_CPU_TYPE_ARM64     = 12 or $01000000;

var
  GTotalTests: Integer = 0;
  GPassedTests: Integer = 0;
  GFailedTests: Integer = 0;
  GTempDir: String;

{ ====================================================================
  Test framework helpers
  ==================================================================== }

procedure Check(Condition: Boolean; const TestName: String);
begin
  Inc(GTotalTests);
  if Condition then
  begin
    Inc(GPassedTests);
    WriteLn('  PASS: ', TestName);
  end
  else
  begin
    Inc(GFailedTests);
    WriteLn('  FAIL: ', TestName);
  end;
end;

procedure Section(const Name: String);
begin
  WriteLn;
  WriteLn('=== ', Name, ' ===');
end;

function TempFile(const Name: String): String;
begin
  Result := GTempDir + Name;
end;

{ ====================================================================
  Helper: write raw bytes to a stream
  ==================================================================== }

procedure WriteBytes(S: TStream; const Data: array of Byte);
begin
  if Length(Data) > 0 then
    S.WriteBuffer(Data[0], Length(Data));
end;

procedure WriteCardinal(S: TStream; V: Cardinal);
begin
  S.WriteBuffer(V, 4);
end;

procedure WriteWord(S: TStream; V: Word);
begin
  S.WriteBuffer(V, 2);
end;

procedure WriteByte(S: TStream; V: Byte);
begin
  S.WriteBuffer(V, 1);
end;

procedure WriteQWord(S: TStream; V: QWord);
begin
  S.WriteBuffer(V, 8);
end;

procedure WritePadding(S: TStream; Count: Integer);
var
  Zero: Byte;
  I: Integer;
begin
  Zero := 0;
  for I := 1 to Count do
    S.WriteBuffer(Zero, 1);
end;

procedure WriteString(S: TStream; const Str: String);
var
  I: Integer;
  B: Byte;
begin
  for I := 1 to Length(Str) do
  begin
    B := Ord(Str[I]);
    S.WriteBuffer(B, 1);
  end;
end;

procedure WriteNullTermString(S: TStream; const Str: String);
var
  Zero: Byte;
begin
  WriteString(S, Str);
  Zero := 0;
  S.WriteBuffer(Zero, 1);
end;


{ ====================================================================
  Synthetic ELF64 builder
  ==================================================================== }

function BuildELF64(const SectionName: String; const SectionData: array of Byte;
  const SymbolName: String; SymbolValue: QWord; Machine: Word): String;
var
  F: TFileStream;
  FilePath: String;
  StringTableData: TMemoryStream;
  SymStringTableData: TMemoryStream;
  SymbolTable: TMemoryStream;
  SHOffset: QWord;
  StrTabOffset, SymTabOffset, SymStrOffset: QWord;
  SectNameIdx, StrTabNameIdx, SymTabNameIdx, SymStrNameIdx: Cardinal;
  SectDataOffset: QWord;
  NumSections: Word;
  SymNameIdx: Cardinal;
begin
  FilePath := TempFile('test_elf64.bin');
  F := TFileStream.Create(FilePath, fmCreate);
  try
    { Build section header string table (.shstrtab) }
    StringTableData := TMemoryStream.Create;
    try
      WriteByte(StringTableData, 0);  { index 0 = empty string }
      SectNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, SectionName);
      StrTabNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, '.shstrtab');
      SymTabNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, '.symtab');
      SymStrNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, '.strtab');

      { Build symbol string table }
      SymStringTableData := TMemoryStream.Create;
      try
        WriteByte(SymStringTableData, 0);  { index 0 = empty }
        SymNameIdx := SymStringTableData.Position;
        WriteNullTermString(SymStringTableData, SymbolName);

        { Build symbol table (1 null entry + 1 real entry) }
        SymbolTable := TMemoryStream.Create;
        try
          { Null symbol (entry 0) }
          WritePadding(SymbolTable, 24);  { sizeof TElf64Sym = 24 }
          { Real symbol }
          WriteCardinal(SymbolTable, SymNameIdx);  { st_name }
          WriteByte(SymbolTable, $12);              { st_info: STB_GLOBAL | STT_FUNC }
          WriteByte(SymbolTable, 0);                { st_other }
          WriteWord(SymbolTable, 1);                { st_shndx: section 1 }
          WriteQWord(SymbolTable, SymbolValue);     { st_value }
          WriteQWord(SymbolTable, 0);               { st_size }

          { Calculate layout:
            [ELF header 64 bytes]
            [section data]
            [symbol string table]
            [symbol table]
            [string table]
            [section headers (5 entries: null, section, symtab, strtab, shstrtab)]
          }
          SectDataOffset := 64;
          SymStrOffset := SectDataOffset + QWord(Length(SectionData));
          SymTabOffset := SymStrOffset + QWord(SymStringTableData.Size);
          StrTabOffset := SymTabOffset + QWord(SymbolTable.Size);
          SHOffset := StrTabOffset + QWord(StringTableData.Size);
          NumSections := 5;

          { Write ELF64 header }
          WriteBytes(F, [$7F, $45, $4C, $46]);  { magic }
          WriteByte(F, 2);     { ELFCLASS64 }
          WriteByte(F, 1);     { ELFDATA2LSB }
          WriteByte(F, 1);     { EV_CURRENT }
          WriteByte(F, 0);     { ELFOSABI_NONE }
          WritePadding(F, 8);  { padding to 16 }
          WriteWord(F, 2);     { e_type: ET_EXEC }
          WriteWord(F, Machine); { e_machine }
          WriteCardinal(F, 1); { e_version }
          WriteQWord(F, 0);    { e_entry }
          WriteQWord(F, 0);    { e_phoff }
          WriteQWord(F, SHOffset); { e_shoff }
          WriteCardinal(F, 0); { e_flags }
          WriteWord(F, 64);    { e_ehsize }
          WriteWord(F, 0);     { e_phentsize }
          WriteWord(F, 0);     { e_phnum }
          WriteWord(F, 64);    { e_shentsize }
          WriteWord(F, NumSections); { e_shnum }
          WriteWord(F, 4);     { e_shstrndx (index 4 = .shstrtab) }

          { Section data }
          if Length(SectionData) > 0 then
            F.WriteBuffer(SectionData[0], Length(SectionData));

          { Symbol string table }
          SymStringTableData.Position := 0;
          F.CopyFrom(SymStringTableData, SymStringTableData.Size);

          { Symbol table }
          SymbolTable.Position := 0;
          F.CopyFrom(SymbolTable, SymbolTable.Size);

          { Section header string table }
          StringTableData.Position := 0;
          F.CopyFrom(StringTableData, StringTableData.Size);

          { Section headers }
          { [0] Null section }
          WritePadding(F, 64);

          { [1] Our section }
          WriteCardinal(F, SectNameIdx);    { sh_name }
          WriteCardinal(F, 1);              { sh_type: SHT_PROGBITS }
          WriteQWord(F, 0);                 { sh_flags }
          WriteQWord(F, 0);                 { sh_addr }
          WriteQWord(F, SectDataOffset);    { sh_offset }
          WriteQWord(F, Length(SectionData)); { sh_size }
          WriteCardinal(F, 0);              { sh_link }
          WriteCardinal(F, 0);              { sh_info }
          WriteQWord(F, 1);                 { sh_addralign }
          WriteQWord(F, 0);                 { sh_entsize }

          { [2] .symtab }
          WriteCardinal(F, SymTabNameIdx);  { sh_name }
          WriteCardinal(F, 2);              { sh_type: SHT_SYMTAB }
          WriteQWord(F, 0);                 { sh_flags }
          WriteQWord(F, 0);                 { sh_addr }
          WriteQWord(F, SymTabOffset);      { sh_offset }
          WriteQWord(F, SymbolTable.Size);  { sh_size }
          WriteCardinal(F, 3);              { sh_link -> .strtab (index 3) }
          WriteCardinal(F, 1);              { sh_info: index of first non-local }
          WriteQWord(F, 8);                 { sh_addralign }
          WriteQWord(F, 24);               { sh_entsize: sizeof(Elf64_Sym) }

          { [3] .strtab (symbol string table) }
          WriteCardinal(F, SymStrNameIdx);  { sh_name }
          WriteCardinal(F, 3);              { sh_type: SHT_STRTAB }
          WriteQWord(F, 0);
          WriteQWord(F, 0);
          WriteQWord(F, SymStrOffset);      { sh_offset }
          WriteQWord(F, SymStringTableData.Size); { sh_size }
          WriteCardinal(F, 0);
          WriteCardinal(F, 0);
          WriteQWord(F, 1);
          WriteQWord(F, 0);

          { [4] .shstrtab }
          WriteCardinal(F, StrTabNameIdx);  { sh_name }
          WriteCardinal(F, 3);              { sh_type: SHT_STRTAB }
          WriteQWord(F, 0);
          WriteQWord(F, 0);
          WriteQWord(F, StrTabOffset);      { sh_offset }
          WriteQWord(F, StringTableData.Size); { sh_size }
          WriteCardinal(F, 0);
          WriteCardinal(F, 0);
          WriteQWord(F, 1);
          WriteQWord(F, 0);

        finally
          SymbolTable.Free;
        end;
      finally
        SymStringTableData.Free;
      end;
    finally
      StringTableData.Free;
    end;
  finally
    F.Free;
  end;
  Result := FilePath;
end;


{ ====================================================================
  Synthetic ELF32 builder
  ==================================================================== }

function BuildELF32(const SectionName: String; const SectionData: array of Byte;
  const SymbolName: String; SymbolValue: Cardinal; Machine: Word): String;
var
  F: TFileStream;
  FilePath: String;
  StringTableData: TMemoryStream;
  SymStringTableData: TMemoryStream;
  SymbolTable: TMemoryStream;
  SectDataOffset, SymStrOffset, SymTabOffset, StrTabOffset, SHOffset: Cardinal;
  SectNameIdx, StrTabNameIdx, SymTabNameIdx, SymStrNameIdx: Cardinal;
  NumSections: Word;
  SymNameIdx: Cardinal;
begin
  FilePath := TempFile('test_elf32.bin');
  F := TFileStream.Create(FilePath, fmCreate);
  try
    { Section header string table }
    StringTableData := TMemoryStream.Create;
    try
      WriteByte(StringTableData, 0);
      SectNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, SectionName);
      StrTabNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, '.shstrtab');
      SymTabNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, '.symtab');
      SymStrNameIdx := StringTableData.Position;
      WriteNullTermString(StringTableData, '.strtab');

      { Symbol string table }
      SymStringTableData := TMemoryStream.Create;
      try
        WriteByte(SymStringTableData, 0);
        SymNameIdx := SymStringTableData.Position;
        WriteNullTermString(SymStringTableData, SymbolName);

        { Symbol table: null + 1 real (16 bytes each for ELF32) }
        SymbolTable := TMemoryStream.Create;
        try
          WritePadding(SymbolTable, 16);  { null entry }
          { Elf32_Sym: st_name(4), st_value(4), st_size(4), st_info(1), st_other(1), st_shndx(2) }
          WriteCardinal(SymbolTable, SymNameIdx);
          WriteCardinal(SymbolTable, SymbolValue);
          WriteCardinal(SymbolTable, 0);  { st_size }
          WriteByte(SymbolTable, $12);    { st_info }
          WriteByte(SymbolTable, 0);      { st_other }
          WriteWord(SymbolTable, 1);      { st_shndx }

          { Layout: [ELF32 header=52 bytes][section data][sym strtab][symtab][shstrtab][section hdrs] }
          SectDataOffset := 52;
          SymStrOffset := SectDataOffset + Cardinal(Length(SectionData));
          SymTabOffset := SymStrOffset + Cardinal(SymStringTableData.Size);
          StrTabOffset := SymTabOffset + Cardinal(SymbolTable.Size);
          SHOffset := StrTabOffset + Cardinal(StringTableData.Size);
          NumSections := 5;

          { ELF32 header }
          WriteBytes(F, [$7F, $45, $4C, $46]);
          WriteByte(F, 1);     { ELFCLASS32 }
          WriteByte(F, 1);     { ELFDATA2LSB }
          WriteByte(F, 1);     { EV_CURRENT }
          WriteByte(F, 0);
          WritePadding(F, 8);  { pad to 16 }
          WriteWord(F, 2);     { e_type }
          WriteWord(F, Machine);
          WriteCardinal(F, 1); { e_version }
          WriteCardinal(F, 0); { e_entry }
          WriteCardinal(F, 0); { e_phoff }
          WriteCardinal(F, SHOffset);
          WriteCardinal(F, 0); { e_flags }
          WriteWord(F, 52);    { e_ehsize }
          WriteWord(F, 0);     { e_phentsize }
          WriteWord(F, 0);     { e_phnum }
          WriteWord(F, 40);    { e_shentsize }
          WriteWord(F, NumSections);
          WriteWord(F, 4);     { e_shstrndx }

          { Section data }
          if Length(SectionData) > 0 then
            F.WriteBuffer(SectionData[0], Length(SectionData));

          { Symbol string table }
          SymStringTableData.Position := 0;
          F.CopyFrom(SymStringTableData, SymStringTableData.Size);

          { Symbol table }
          SymbolTable.Position := 0;
          F.CopyFrom(SymbolTable, SymbolTable.Size);

          { Section header string table }
          StringTableData.Position := 0;
          F.CopyFrom(StringTableData, StringTableData.Size);

          { Section headers (40 bytes each for ELF32) }
          { [0] Null }
          WritePadding(F, 40);

          { [1] Our section }
          WriteCardinal(F, SectNameIdx);
          WriteCardinal(F, 1);  { SHT_PROGBITS }
          WriteCardinal(F, 0);  { sh_flags }
          WriteCardinal(F, 0);  { sh_addr }
          WriteCardinal(F, SectDataOffset);
          WriteCardinal(F, Length(SectionData));
          WriteCardinal(F, 0);  { sh_link }
          WriteCardinal(F, 0);  { sh_info }
          WriteCardinal(F, 1);  { sh_addralign }
          WriteCardinal(F, 0);  { sh_entsize }

          { [2] .symtab }
          WriteCardinal(F, SymTabNameIdx);
          WriteCardinal(F, 2);  { SHT_SYMTAB }
          WriteCardinal(F, 0);
          WriteCardinal(F, 0);
          WriteCardinal(F, SymTabOffset);
          WriteCardinal(F, SymbolTable.Size);
          WriteCardinal(F, 3);  { sh_link -> .strtab }
          WriteCardinal(F, 1);
          WriteCardinal(F, 4);
          WriteCardinal(F, 16); { sizeof Elf32_Sym }

          { [3] .strtab }
          WriteCardinal(F, SymStrNameIdx);
          WriteCardinal(F, 3);  { SHT_STRTAB }
          WriteCardinal(F, 0);
          WriteCardinal(F, 0);
          WriteCardinal(F, SymStrOffset);
          WriteCardinal(F, SymStringTableData.Size);
          WriteCardinal(F, 0);
          WriteCardinal(F, 0);
          WriteCardinal(F, 1);
          WriteCardinal(F, 0);

          { [4] .shstrtab }
          WriteCardinal(F, StrTabNameIdx);
          WriteCardinal(F, 3);
          WriteCardinal(F, 0);
          WriteCardinal(F, 0);
          WriteCardinal(F, StrTabOffset);
          WriteCardinal(F, StringTableData.Size);
          WriteCardinal(F, 0);
          WriteCardinal(F, 0);
          WriteCardinal(F, 1);
          WriteCardinal(F, 0);

        finally
          SymbolTable.Free;
        end;
      finally
        SymStringTableData.Free;
      end;
    finally
      StringTableData.Free;
    end;
  finally
    F.Free;
  end;
  Result := FilePath;
end;


{ ====================================================================
  Synthetic PE builder (PE32 or PE32+)
  ==================================================================== }

function BuildPE(const SectionName: String; const SectionData: array of Byte;
  const SymbolName: String; SymbolValue: Cardinal;
  Is64: Boolean; Machine: Word): String;
var
  F: TFileStream;
  FilePath: String;
  DOSStubSize: Integer;
  PESignatureOffset: Cardinal;
  OptionalHeaderSize: Word;
  SectionHeaderOffset: Int64;
  SectionDataOffset: Cardinal;
  SymbolTableOffset: Cardinal;
  SymStrData: TMemoryStream;
  SectNameBytes: array[0..7] of Byte;
  SymNameBytes: array[0..7] of Byte;
  I: Integer;
  StrTableSize: Cardinal;
  NameOffset: Cardinal;
begin
  if Is64 then
    FilePath := TempFile('test_pe64.bin')
  else
    FilePath := TempFile('test_pe32.bin');

  F := TFileStream.Create(FilePath, fmCreate);
  try
    { DOS header (minimal 64 bytes) }
    DOSStubSize := 64;
    PESignatureOffset := DOSStubSize;

    { Write MZ header: e_magic(2) + padding(58) + e_lfanew(4) = 64 bytes }
    WriteWord(F, $5A4D);      { e_magic at offset 0 }
    WritePadding(F, 58);      { 29 words of padding (offsets 2..59) }
    WriteCardinal(F, PESignatureOffset); { e_lfanew at offset 60 }

    { PE signature }
    WriteCardinal(F, $00004550);

    { COFF header }
    if Is64 then
      OptionalHeaderSize := 112  { PE32+ minimal }
    else
      OptionalHeaderSize := 96;  { PE32 minimal }

    { Calculate layout:
      - Section data starts after headers
      - Symbol table follows section data
      - String table follows symbol table }
    SectionHeaderOffset := F.Position + 20 + OptionalHeaderSize;
    SectionDataOffset := SectionHeaderOffset + 40;  { 1 section header = 40 bytes }

    { Align to 512 for realism (not strictly needed for our parser) }
    SymbolTableOffset := SectionDataOffset + Cardinal(Length(SectionData));

    { Build symbol string table (for long names) }
    SymStrData := TMemoryStream.Create;
    try
      { COFF string table starts with its size (4 bytes) }
      WriteCardinal(SymStrData, 0);  { placeholder, fill later }
      NameOffset := SymStrData.Position;
      WriteNullTermString(SymStrData, SymbolName);
      StrTableSize := SymStrData.Size;
      SymStrData.Position := 0;
      WriteCardinal(SymStrData, StrTableSize);

      { Write COFF header fields }
      WriteWord(F, Machine);
      WriteWord(F, 1);              { NumberOfSections }
      WriteCardinal(F, 0);          { TimeDateStamp }
      WriteCardinal(F, SymbolTableOffset);  { PointerToSymbolTable }
      WriteCardinal(F, 2);          { NumberOfSymbols (null + real) }
      WriteWord(F, OptionalHeaderSize);
      WriteWord(F, 0);              { Characteristics }

      { Optional header (minimal) }
      if Is64 then
        WriteWord(F, $020B)   { PE32+ magic }
      else
        WriteWord(F, $010B);  { PE32 magic }
      WritePadding(F, OptionalHeaderSize - 2);

      { Section header }
      FillChar(SectNameBytes, 8, 0);
      for I := 0 to Length(SectionName) - 1 do
        if I < 8 then
          SectNameBytes[I] := Ord(SectionName[I + 1]);
      F.WriteBuffer(SectNameBytes, 8);
      WriteCardinal(F, Length(SectionData)); { VirtualSize }
      WriteCardinal(F, 0);                  { VirtualAddress }
      WriteCardinal(F, Length(SectionData)); { SizeOfRawData }
      WriteCardinal(F, SectionDataOffset);  { PointerToRawData }
      WriteCardinal(F, 0);                  { PointerToRelocations }
      WriteCardinal(F, 0);                  { PointerToLinenumbers }
      WriteWord(F, 0);                      { NumberOfRelocations }
      WriteWord(F, 0);                      { NumberOfLinenumbers }
      WriteCardinal(F, 0);                  { Characteristics }

      { Section data }
      if Length(SectionData) > 0 then
        F.WriteBuffer(SectionData[0], Length(SectionData));

      { Symbol table }
      { Entry 0: null symbol }
      WritePadding(F, 18);

      { Entry 1: real symbol }
      FillChar(SymNameBytes, 8, 0);
      if Length(SymbolName) <= 8 then
      begin
        for I := 0 to Length(SymbolName) - 1 do
          SymNameBytes[I] := Ord(SymbolName[I + 1]);
      end
      else
      begin
        { Long name: first 4 bytes = 0, next 4 = offset into string table }
        PCardinal(@SymNameBytes[4])^ := NameOffset;
      end;
      F.WriteBuffer(SymNameBytes, 8);
      WriteCardinal(F, SymbolValue);  { Value }
      WriteWord(F, 1);               { SectionNumber }
      WriteWord(F, $20);             { Type: function }
      WriteByte(F, 2);               { StorageClass: EXTERNAL }
      WriteByte(F, 0);               { NumberOfAuxSymbols }

      { String table }
      SymStrData.Position := 0;
      F.CopyFrom(SymStrData, SymStrData.Size);

    finally
      SymStrData.Free;
    end;
  finally
    F.Free;
  end;
  Result := FilePath;
end;


{ ====================================================================
  Synthetic Mach-O builder (32 or 64 bit)
  ==================================================================== }

function BuildMachO(const SectionData: array of Byte;
  const SymbolName: String; SymbolValue: QWord;
  Is64: Boolean; CPUType: Cardinal): String;
var
  F: TFileStream;
  FilePath: String;
  HeaderSize: Integer;
  SegCmdSize, SectSize: Integer;
  SymtabCmdSize: Integer;
  LCSize: Integer;
  DataOffset: Integer;
  SymtabOffset: Integer;
  StrTabOffset: Integer;
  SymEntrySize: Integer;
  StrTable: TMemoryStream;
  SymNameIdx: Cardinal;
begin
  if Is64 then
  begin
    FilePath := TempFile('test_macho64.bin');
    HeaderSize := 32;   { sizeof(mach_header_64) }
    SegCmdSize := 72;   { sizeof(segment_command_64) }
    SectSize := 80;     { sizeof(section_64) }
    SymEntrySize := 16; { sizeof(nlist_64) }
  end
  else
  begin
    FilePath := TempFile('test_macho32.bin');
    HeaderSize := 28;   { sizeof(mach_header) }
    SegCmdSize := 56;   { sizeof(segment_command) }
    SectSize := 68;     { sizeof(section) }
    SymEntrySize := 12; { sizeof(nlist) }
  end;

  SymtabCmdSize := 24;   { sizeof(symtab_command) }
  LCSize := (SegCmdSize + SectSize) + SymtabCmdSize;

  DataOffset := HeaderSize + LCSize;

  { Build string table }
  StrTable := TMemoryStream.Create;
  try
    WriteByte(StrTable, 0);  { empty string at index 0 }
    { Mach-O symbols have leading underscore }
    SymNameIdx := StrTable.Position;
    WriteNullTermString(StrTable, '_' + SymbolName);

    SymtabOffset := DataOffset + Length(SectionData);
    StrTabOffset := SymtabOffset + (2 * SymEntrySize);  { null + real }

    F := TFileStream.Create(FilePath, fmCreate);
    try
      { Mach-O header }
      if Is64 then
        WriteCardinal(F, TEST_MH_MAGIC_64)
      else
        WriteCardinal(F, TEST_MH_MAGIC_32);
      WriteCardinal(F, CPUType);     { cputype }
      WriteCardinal(F, 0);           { cpusubtype }
      WriteCardinal(F, 2);           { filetype: MH_EXECUTE }
      WriteCardinal(F, 2);           { ncmds }
      WriteCardinal(F, LCSize);      { sizeofcmds }
      WriteCardinal(F, 0);           { flags }
      if Is64 then
        WriteCardinal(F, 0);         { reserved (64-bit only) }

      { LC_SEGMENT / LC_SEGMENT_64 with 1 section (__DATA,__opdf) }
      if Is64 then
      begin
        WriteCardinal(F, TEST_LC_SEGMENT_64);
        WriteCardinal(F, SegCmdSize + SectSize);
        { segname: __DATA padded to 16 }
        WriteString(F, '__DATA');
        WritePadding(F, 10);
        WriteQWord(F, 0);             { vmaddr }
        WriteQWord(F, 0);             { vmsize }
        WriteQWord(F, DataOffset);    { fileoff }
        WriteQWord(F, Length(SectionData)); { filesize }
        WriteCardinal(F, 7);          { maxprot }
        WriteCardinal(F, 7);          { initprot }
        WriteCardinal(F, 1);          { nsects }
        WriteCardinal(F, 0);          { flags }

        { section_64: __opdf in __DATA }
        WriteString(F, '__opdf');
        WritePadding(F, 10);          { sectname padded to 16 }
        WriteString(F, '__DATA');
        WritePadding(F, 10);          { segname padded to 16 }
        WriteQWord(F, 0);             { addr }
        WriteQWord(F, Length(SectionData)); { size }
        WriteCardinal(F, DataOffset); { offset }
        WriteCardinal(F, 0);          { align }
        WriteCardinal(F, 0);          { reloff }
        WriteCardinal(F, 0);          { nreloc }
        WriteCardinal(F, 0);          { flags }
        WriteCardinal(F, 0);          { reserved1 }
        WriteCardinal(F, 0);          { reserved2 }
        WriteCardinal(F, 0);          { reserved3 (64-bit only) }
      end
      else
      begin
        WriteCardinal(F, TEST_LC_SEGMENT);
        WriteCardinal(F, SegCmdSize + SectSize);
        WriteString(F, '__DATA');
        WritePadding(F, 10);
        WriteCardinal(F, 0);
        WriteCardinal(F, 0);
        WriteCardinal(F, DataOffset);
        WriteCardinal(F, Length(SectionData));
        WriteCardinal(F, 7);
        WriteCardinal(F, 7);
        WriteCardinal(F, 1);
        WriteCardinal(F, 0);

        { section (32-bit) }
        WriteString(F, '__opdf');
        WritePadding(F, 10);
        WriteString(F, '__DATA');
        WritePadding(F, 10);
        WriteCardinal(F, 0);          { addr }
        WriteCardinal(F, Length(SectionData)); { size }
        WriteCardinal(F, DataOffset); { offset }
        WriteCardinal(F, 0);          { align }
        WriteCardinal(F, 0);          { reloff }
        WriteCardinal(F, 0);          { nreloc }
        WriteCardinal(F, 0);          { flags }
        WriteCardinal(F, 0);          { reserved1 }
        WriteCardinal(F, 0);          { reserved2 }
      end;

      { LC_SYMTAB }
      WriteCardinal(F, TEST_LC_SYMTAB);
      WriteCardinal(F, SymtabCmdSize);
      WriteCardinal(F, SymtabOffset);  { symoff }
      WriteCardinal(F, 2);             { nsyms }
      WriteCardinal(F, StrTabOffset);  { stroff }
      WriteCardinal(F, StrTable.Size); { strsize }

      { Section data }
      if Length(SectionData) > 0 then
        F.WriteBuffer(SectionData[0], Length(SectionData));

      { Symbol table }
      { Entry 0: null }
      WritePadding(F, SymEntrySize);
      { Entry 1: real symbol }
      if Is64 then
      begin
        WriteCardinal(F, SymNameIdx); { n_strx }
        WriteByte(F, $0F);           { n_type: N_SECT | N_EXT }
        WriteByte(F, 1);             { n_sect }
        WriteWord(F, 0);             { n_desc }
        WriteQWord(F, SymbolValue);  { n_value }
      end
      else
      begin
        WriteCardinal(F, SymNameIdx);
        WriteByte(F, $0F);
        WriteByte(F, 1);
        WriteWord(F, 0);
        WriteCardinal(F, Cardinal(SymbolValue));
      end;

      { String table }
      StrTable.Position := 0;
      F.CopyFrom(StrTable, StrTable.Size);

    finally
      F.Free;
    end;
  finally
    StrTable.Free;
  end;
  Result := FilePath;
end;


{ ====================================================================
  Test: Format Detection
  ==================================================================== }

procedure TestFormatDetection;
var
  Path: String;
  F: TFileStream;
begin
  Section('Format Detection');

  { ELF64 }
  Path := BuildELF64('.opdf', [$DE, $AD], 'test', $1000, 62);
  Check(DetectBinaryFormat(Path) = bfELF, 'ELF64 detected as bfELF');

  { ELF32 }
  Path := BuildELF32('.opdf', [$BE, $EF], 'test', $2000, 3);
  Check(DetectBinaryFormat(Path) = bfELF, 'ELF32 detected as bfELF');

  { PE32 }
  Path := BuildPE('.opdf', [$CA, $FE], 'test', $3000, False, $014C);
  Check(DetectBinaryFormat(Path) = bfPE, 'PE32 detected as bfPE');

  { PE32+ }
  Path := BuildPE('.opdf', [$CA, $FE], 'test', $4000, True, $8664);
  Check(DetectBinaryFormat(Path) = bfPE, 'PE32+ detected as bfPE');

  { Mach-O 64 }
  Path := BuildMachO([$FA, $CE], 'test', $5000, True, Cardinal(TEST_CPU_TYPE_X86_64));
  Check(DetectBinaryFormat(Path) = bfMachO, 'Mach-O 64 detected as bfMachO');

  { Mach-O 32 }
  Path := BuildMachO([$FA, $CE], 'test', $6000, False, Cardinal(TEST_CPU_TYPE_I386));
  Check(DetectBinaryFormat(Path) = bfMachO, 'Mach-O 32 detected as bfMachO');

  { Empty file }
  Path := TempFile('empty.bin');
  F := TFileStream.Create(Path, fmCreate);
  F.Free;
  Check(DetectBinaryFormat(Path) = bfUnknown, 'Empty file detected as bfUnknown');

  { Garbage file }
  Path := TempFile('garbage.bin');
  F := TFileStream.Create(Path, fmCreate);
  try
    WriteBytes(F, [$00, $11, $22, $33, $44, $55]);
  finally
    F.Free;
  end;
  Check(DetectBinaryFormat(Path) = bfUnknown, 'Garbage file detected as bfUnknown');

  { Non-existent file }
  Check(DetectBinaryFormat('/tmp/nonexistent_binary_12345.bin') = bfUnknown,
    'Non-existent file detected as bfUnknown');
end;


{ ====================================================================
  Test: ELF64 Reader
  ==================================================================== }

procedure TestELF64Reader;
var
  Path: String;
  Reader: IBinaryReader;
  Stream: TMemoryStream;
  Buf: array[0..3] of Byte;
begin
  Section('ELF64 Reader');

  Path := BuildELF64('.opdf', [$DE, $AD, $BE, $EF], 'MY_SYMBOL', $401000, 62);
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Factory creates reader for ELF64');

  Check(Reader.GetPointerSize = 8, 'ELF64 pointer size = 8');
  Check(Reader.GetArchitecture = archX86_64, 'ELF64 x86_64 architecture');

  { Extract section }
  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'ELF64 .opdf section found');
  if Stream <> nil then
  begin
    Check(Stream.Size = 4, 'ELF64 .opdf section size = 4');
    Stream.ReadBuffer(Buf, 4);
    Check((Buf[0] = $DE) and (Buf[1] = $AD) and (Buf[2] = $BE) and (Buf[3] = $EF),
      'ELF64 .opdf section data correct');
    Stream.Free;
  end;

  { Missing section }
  Stream := Reader.ExtractSection('.nosuch');
  Check(Stream = nil, 'ELF64 missing section returns nil');

  { Symbol lookup }
  Check(Reader.FindSymbolAddress('MY_SYMBOL') = $401000, 'ELF64 symbol lookup exact case');
  Check(Reader.FindSymbolAddress('my_symbol') = $401000, 'ELF64 symbol lookup case-insensitive');
  Check(Reader.FindSymbolAddress('NONEXISTENT') = 0, 'ELF64 missing symbol returns 0');
end;


{ ====================================================================
  Test: ELF32 Reader
  ==================================================================== }

procedure TestELF32Reader;
var
  Path: String;
  Reader: IBinaryReader;
  Stream: TMemoryStream;
  Buf: array[0..3] of Byte;
begin
  Section('ELF32 Reader');

  Path := BuildELF32('.opdf', [$01, $02, $03, $04], 'i386_func', $08048000, 3);
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Factory creates reader for ELF32');

  Check(Reader.GetPointerSize = 4, 'ELF32 pointer size = 4');
  Check(Reader.GetArchitecture = archI386, 'ELF32 i386 architecture');

  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'ELF32 .opdf section found');
  if Stream <> nil then
  begin
    Check(Stream.Size = 4, 'ELF32 .opdf section size = 4');
    Stream.ReadBuffer(Buf, 4);
    Check((Buf[0] = $01) and (Buf[1] = $02) and (Buf[2] = $03) and (Buf[3] = $04),
      'ELF32 .opdf section data correct');
    Stream.Free;
  end;

  Check(Reader.FindSymbolAddress('i386_func') = $08048000, 'ELF32 symbol lookup');
end;


{ ====================================================================
  Test: ELF architecture detection
  ==================================================================== }

procedure TestELFArchitectures;
var
  Path: String;
  Reader: IBinaryReader;
begin
  Section('ELF Architecture Detection');

  Path := BuildELF64('.opdf', [$00], 'x', 0, 62);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archX86_64, 'ELF64 EM_X86_64 -> archX86_64');

  Path := BuildELF32('.opdf', [$00], 'x', 0, 3);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archI386, 'ELF32 EM_386 -> archI386');

  Path := BuildELF64('.opdf', [$00], 'x', 0, 183);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archAArch64, 'ELF64 EM_AARCH64 -> archAArch64');

  Path := BuildELF32('.opdf', [$00], 'x', 0, 40);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archARM, 'ELF32 EM_ARM -> archARM');
end;


{ ====================================================================
  Test: PE32 Reader
  ==================================================================== }

procedure TestPE32Reader;
var
  Path: String;
  Reader: IBinaryReader;
  Stream: TMemoryStream;
  Buf: array[0..3] of Byte;
begin
  Section('PE32 Reader');

  Path := BuildPE('.opdf', [$AA, $BB, $CC, $DD], 'PE_FUNC', $00401234, False, $014C);
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Factory creates reader for PE32');

  Check(Reader.GetPointerSize = 4, 'PE32 pointer size = 4');
  Check(Reader.GetArchitecture = archI386, 'PE32 i386 architecture');

  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'PE32 .opdf section found');
  if Stream <> nil then
  begin
    Check(Stream.Size = 4, 'PE32 .opdf section size = 4');
    Stream.ReadBuffer(Buf, 4);
    Check((Buf[0] = $AA) and (Buf[1] = $BB) and (Buf[2] = $CC) and (Buf[3] = $DD),
      'PE32 .opdf section data correct');
    Stream.Free;
  end;

  Stream := Reader.ExtractSection('.nosuch');
  Check(Stream = nil, 'PE32 missing section returns nil');

  Check(Reader.FindSymbolAddress('PE_FUNC') = $00401234, 'PE32 symbol lookup');
  Check(Reader.FindSymbolAddress('pe_func') = $00401234, 'PE32 symbol lookup case-insensitive');
  Check(Reader.FindSymbolAddress('NOPE') = 0, 'PE32 missing symbol returns 0');
end;


{ ====================================================================
  Test: PE32+ Reader
  ==================================================================== }

procedure TestPE64Reader;
var
  Path: String;
  Reader: IBinaryReader;
  Stream: TMemoryStream;
  Buf: array[0..1] of Byte;
begin
  Section('PE32+ (64-bit) Reader');

  Path := BuildPE('.opdf', [$EE, $FF], 'WIN64_FUNC', $12345678, True, $8664);
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Factory creates reader for PE32+');

  Check(Reader.GetPointerSize = 8, 'PE32+ pointer size = 8');
  Check(Reader.GetArchitecture = archX86_64, 'PE32+ x86_64 architecture');

  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'PE32+ .opdf section found');
  if Stream <> nil then
  begin
    Check(Stream.Size = 2, 'PE32+ .opdf section size = 2');
    Stream.ReadBuffer(Buf, 2);
    Check((Buf[0] = $EE) and (Buf[1] = $FF), 'PE32+ .opdf section data correct');
    Stream.Free;
  end;
end;


{ ====================================================================
  Test: Mach-O 64 Reader
  ==================================================================== }

procedure TestMachO64Reader;
var
  Path: String;
  Reader: IBinaryReader;
  Stream: TMemoryStream;
  Buf: array[0..3] of Byte;
begin
  Section('Mach-O 64-bit Reader');

  Path := BuildMachO([$11, $22, $33, $44], 'macho_func', $100001000,
    True, Cardinal(TEST_CPU_TYPE_X86_64));
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Factory creates reader for Mach-O 64');

  Check(Reader.GetPointerSize = 8, 'Mach-O 64 pointer size = 8');
  Check(Reader.GetArchitecture = archX86_64, 'Mach-O 64 x86_64 architecture');

  { Mach-O uses __DATA,__opdf but the reader maps .opdf -> __DATA,__opdf }
  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'Mach-O 64 .opdf section found (mapped from __DATA,__opdf)');
  if Stream <> nil then
  begin
    Check(Stream.Size = 4, 'Mach-O 64 .opdf section size = 4');
    Stream.ReadBuffer(Buf, 4);
    Check((Buf[0] = $11) and (Buf[1] = $22) and (Buf[2] = $33) and (Buf[3] = $44),
      'Mach-O 64 .opdf section data correct');
    Stream.Free;
  end;

  { Direct segment,section naming }
  Stream := Reader.ExtractSection('__DATA,__opdf');
  Check(Stream <> nil, 'Mach-O 64 __DATA,__opdf direct naming works');
  if Stream <> nil then
    Stream.Free;

  { Missing section }
  Stream := Reader.ExtractSection('.nosuch');
  Check(Stream = nil, 'Mach-O 64 missing section returns nil');

  { Symbol lookup (Mach-O strips leading underscore) }
  Check(Reader.FindSymbolAddress('macho_func') = $100001000, 'Mach-O 64 symbol lookup');
  Check(Reader.FindSymbolAddress('MACHO_FUNC') = $100001000, 'Mach-O 64 symbol lookup case-insensitive');
  Check(Reader.FindSymbolAddress('NOPE') = 0, 'Mach-O 64 missing symbol returns 0');
end;


{ ====================================================================
  Test: Mach-O 32 Reader
  ==================================================================== }

procedure TestMachO32Reader;
var
  Path: String;
  Reader: IBinaryReader;
  Stream: TMemoryStream;
begin
  Section('Mach-O 32-bit Reader');

  Path := BuildMachO([$55, $66], 'macho32_func', $00002000,
    False, Cardinal(TEST_CPU_TYPE_I386));
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Factory creates reader for Mach-O 32');

  Check(Reader.GetPointerSize = 4, 'Mach-O 32 pointer size = 4');
  Check(Reader.GetArchitecture = archI386, 'Mach-O 32 i386 architecture');

  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'Mach-O 32 .opdf section found');
  if Stream <> nil then
  begin
    Check(Stream.Size = 2, 'Mach-O 32 .opdf section size = 2');
    Stream.Free;
  end;

  Check(Reader.FindSymbolAddress('macho32_func') = $00002000, 'Mach-O 32 symbol lookup');
end;


{ ====================================================================
  Test: Mach-O architecture detection
  ==================================================================== }

procedure TestMachOArchitectures;
var
  Path: String;
  Reader: IBinaryReader;
begin
  Section('Mach-O Architecture Detection');

  Path := BuildMachO([$00], 'x', 0, True, Cardinal(TEST_CPU_TYPE_X86_64));
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archX86_64, 'Mach-O CPU_TYPE_X86_64 -> archX86_64');

  Path := BuildMachO([$00], 'x', 0, False, Cardinal(TEST_CPU_TYPE_I386));
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archI386, 'Mach-O CPU_TYPE_I386 -> archI386');

  Path := BuildMachO([$00], 'x', 0, True, Cardinal(TEST_CPU_TYPE_ARM64));
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archAArch64, 'Mach-O CPU_TYPE_ARM64 -> archAArch64');

  Path := BuildMachO([$00], 'x', 0, False, Cardinal(TEST_CPU_TYPE_ARM));
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archARM, 'Mach-O CPU_TYPE_ARM -> archARM');
end;


{ ====================================================================
  Test: Factory function
  ==================================================================== }

procedure TestFactory;
var
  Path: String;
  Reader: IBinaryReader;
  F: TFileStream;
begin
  Section('Factory Function');

  { Non-existent file returns nil }
  Reader := CreateBinaryReader('/tmp/nonexistent_binary_99999.bin');
  Check(Reader = nil, 'Factory returns nil for non-existent file');

  { Empty file returns nil }
  Path := TempFile('factory_empty.bin');
  F := TFileStream.Create(Path, fmCreate);
  F.Free;
  Reader := CreateBinaryReader(Path);
  Check(Reader = nil, 'Factory returns nil for empty file');

  { Garbage file returns nil }
  Path := TempFile('factory_garbage.bin');
  F := TFileStream.Create(Path, fmCreate);
  try
    WriteBytes(F, [$00, $11, $22, $33, $44, $55, $66, $77]);
  finally
    F.Free;
  end;
  Reader := CreateBinaryReader(Path);
  Check(Reader = nil, 'Factory returns nil for garbage file');

  { Valid ELF returns non-nil }
  Path := BuildELF64('.test', [$01], 'sym', 0, 62);
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Factory returns reader for valid ELF');
end;


{ ====================================================================
  Test: Large section data
  ==================================================================== }

procedure TestLargeSection;
var
  Path: String;
  Reader: IBinaryReader;
  Stream: TMemoryStream;
  Data: array of Byte;
  ReadBack: array of Byte;
  I: Integer;
  Match: Boolean;
begin
  Section('Large Section Data');

  SetLength(Data, 65536);
  for I := 0 to High(Data) do
    Data[I] := Byte(I mod 256);

  Path := BuildELF64('.opdf', Data, 'big_sym', $DEADBEEF, 62);
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Reader created for large section ELF64');

  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'Large section extracted');
  if Stream <> nil then
  begin
    Check(Stream.Size = 65536, 'Large section size = 65536');
    SetLength(ReadBack, Stream.Size);
    Stream.ReadBuffer(ReadBack[0], Stream.Size);
    Match := True;
    for I := 0 to High(Data) do
      if ReadBack[I] <> Data[I] then
      begin
        Match := False;
        Break;
      end;
    Check(Match, 'Large section data integrity verified');
    Stream.Free;
  end;
end;


{ ====================================================================
  Test: PE architecture detection
  ==================================================================== }

procedure TestPEArchitectures;
var
  Path: String;
  Reader: IBinaryReader;
begin
  Section('PE Architecture Detection');

  Path := BuildPE('.opdf', [$00], 'x', 0, False, $014C);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archI386, 'PE IMAGE_FILE_MACHINE_I386 -> archI386');

  Path := BuildPE('.opdf', [$00], 'x', 0, True, $8664);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archX86_64, 'PE IMAGE_FILE_MACHINE_AMD64 -> archX86_64');

  Path := BuildPE('.opdf', [$00], 'x', 0, False, $01C0);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archARM, 'PE IMAGE_FILE_MACHINE_ARM -> archARM');

  Path := BuildPE('.opdf', [$00], 'x', 0, True, $AA64);
  Reader := CreateBinaryReader(Path);
  Check(Reader.GetArchitecture = archAArch64, 'PE IMAGE_FILE_MACHINE_ARM64 -> archAArch64');
end;


{ ====================================================================
  Test: Interface reference counting (readers stay alive via interface)
  ==================================================================== }

procedure TestInterfaceLifetime;
var
  Reader: IBinaryReader;
  Stream: TMemoryStream;
  Path: String;
begin
  Section('Interface Lifetime');

  Path := BuildELF64('.opdf', [$01, $02], 'sym', $1000, 62);
  Reader := CreateBinaryReader(Path);
  Check(Reader <> nil, 'Reader created');

  Stream := Reader.ExtractSection('.opdf');
  Check(Stream <> nil, 'Section extracted while reader alive');
  if Stream <> nil then
    Stream.Free;

  { Reader should be collected when variable goes out of scope (set to nil) }
  Reader := nil;
  Check(True, 'Reader released without crash');
end;


{ ====================================================================
  Cleanup
  ==================================================================== }

procedure CleanupTempFiles;
var
  SR: TSearchRec;
  Path: String;
begin
  if FindFirst(GTempDir + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        Path := GTempDir + SR.Name;
        DeleteFile(Path);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(GTempDir);
end;


{ ====================================================================
  Main
  ==================================================================== }

begin
  GTempDir := GetTempDir + 'pdr_binary_test_' + IntToStr(GetProcessID) + DirectorySeparator;
  ForceDirectories(GTempDir);

  WriteLn('Binary Reader Unit Tests');
  WriteLn('========================');
  WriteLn('Temp dir: ', GTempDir);

  try
    TestFormatDetection;
    TestELF64Reader;
    TestELF32Reader;
    TestELFArchitectures;
    TestPE32Reader;
    TestPE64Reader;
    TestPEArchitectures;
    TestMachO64Reader;
    TestMachO32Reader;
    TestMachOArchitectures;
    TestFactory;
    TestLargeSection;
    TestInterfaceLifetime;
  except
    on E: Exception do
    begin
      WriteLn;
      WriteLn('UNEXPECTED EXCEPTION: ', E.ClassName, ': ', E.Message);
      Inc(GFailedTests);
    end;
  end;

  WriteLn;
  WriteLn('========================');
  WriteLn('Total:  ', GTotalTests);
  WriteLn('Passed: ', GPassedTests);
  WriteLn('Failed: ', GFailedTests);

  CleanupTempFiles;

  if GFailedTests > 0 then
    Halt(1);
end.
