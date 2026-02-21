program opdf_dump;

{
  OPDF Dump - Diagnostic tool for OPDF debug sections

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Reads the .opdf section from an ELF binary and dumps its contents.
  Handles multi-header sections (one per compilation unit) and reports
  duplicate types, record counts, and section statistics.

  Usage:
    opdf_dump <binary>              Summary mode
    opdf_dump -v <binary>           Verbose (decode every record)
    opdf_dump -f <file> <binary>    Filter LineInfo by source filename
    opdf_dump -t <type> <binary>    Filter by record type name
}

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Math, opdf_types, elf_reader;

const
  MAX_REC_TYPE = 19;

type
  TRecordCounts = array[0..MAX_REC_TYPE] of Cardinal;

var
  { CLI options }
  OptVerbose: Boolean = False;
  OptFilterFile: String = '';
  OptFilterType: String = '';
  BinaryPath: String = '';

  { Global statistics }
  GlobalCounts: TRecordCounts;
  UnitCount: Integer = 0;
  TotalRecords: Cardinal = 0;
  UniqueTypeIDs: Cardinal = 0;
  TotalTypeRecords: Cardinal = 0;


{ ---- Helpers ---- }

function ReadString(Stream: TStream; Len: Word): String;
begin
  if Len = 0 then
    Exit('');
  SetLength(Result, Len);
  Stream.Read(Result[1], Len);
end;

function FormatSize(Bytes: Int64): String;
begin
  if Bytes >= 1048576 then
    Result := Format('%.1f MB', [Bytes / 1048576.0])
  else if Bytes >= 1024 then
    Result := Format('%.1f KB', [Bytes / 1024.0])
  else
    Result := Format('%d bytes', [Bytes]);
end;

function RecTypeNameToOrd(const Name: String): Integer;
var
  LName: String;
begin
  LName := LowerCase(Name);
  if LName = 'primitive' then Exit(1);
  if LName = 'globalvar' then Exit(2);
  if LName = 'shortstring' then Exit(3);
  if LName = 'ansistring' then Exit(4);
  if LName = 'unicodestring' then Exit(5);
  if LName = 'pointer' then Exit(6);
  if LName = 'array' then Exit(7);
  if LName = 'record' then Exit(8);
  if LName = 'class' then Exit(9);
  if LName = 'property' then Exit(10);
  if LName = 'method' then Exit(11);
  if LName = 'localvar' then Exit(12);
  if LName = 'parameter' then Exit(13);
  if LName = 'lineinfo' then Exit(14);
  if LName = 'functionscope' then Exit(15);
  if LName = 'interface' then Exit(16);
  if LName = 'enum' then Exit(17);
  if LName = 'set' then Exit(18);
  if LName = 'unitdirectory' then Exit(19);
  Result := -1;
end;

function IsTypeRecord(RecType: Byte): Boolean;
begin
  Result := RecType in [Ord(recPrimitive), Ord(recShortStr), Ord(recAnsiStr),
                        Ord(recUnicodeStr), Ord(recPointer), Ord(recArray),
                        Ord(recRecord), Ord(recClass), Ord(recInterface),
                        Ord(recEnum), Ord(recSet)];
end;

{ ---- Record dumpers (verbose mode) ---- }

procedure DumpPrimitive(Stream: TStream);
var
  Def: TDefPrimitive;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d Size=%d Signed=%d Name="%s"',
    [Def.TypeID, Def.SizeInBytes, Def.IsSigned, Name]));
end;

procedure DumpGlobalVar(Stream: TStream);
var
  Def: TDefGlobalVar;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d Address=0x%x Name="%s"',
    [Def.TypeID, Def.Address, Name]));
end;

procedure DumpShortString(Stream: TStream);
var
  Def: TDefShortString;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d MaxLen=%d Name="%s"',
    [Def.TypeID, Def.MaxLength, Name]));
end;

procedure DumpAnsiString(Stream: TStream);
var
  Def: TDefAnsiString;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d Name="%s"', [Def.TypeID, Name]));
end;

procedure DumpUnicodeString(Stream: TStream);
var
  Def: TDefUnicodeString;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d Name="%s"', [Def.TypeID, Name]));
end;

procedure DumpPointer(Stream: TStream);
var
  Def: TDefPointer;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d TargetTypeID=%d Name="%s"',
    [Def.TypeID, Def.TargetTypeID, Name]));
end;

procedure DumpArray(Stream: TStream);
var
  Def: TDefArray;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d ElemTypeID=%d Dims=%d Dynamic=%d Name="%s"',
    [Def.TypeID, Def.ElementTypeID, Def.Dimensions, Def.IsDynamic, Name]));
end;

procedure DumpRecord(Stream: TStream);
var
  Def: TDefRecord;
  Name: String;
  Field: TFieldDescriptor;
  FieldName: String;
  I: Integer;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d Fields=%d Size=%d Name="%s"',
    [Def.TypeID, Def.FieldCount, Def.TotalSize, Name]));
  for I := 0 to Def.FieldCount - 1 do
  begin
    Stream.Read(Field, SizeOf(Field));
    FieldName := ReadString(Stream, Field.NameLen);
    WriteLn(Format('      [%d] TypeID=%d Offset=%d Name="%s"',
      [I, Field.FieldTypeID, Field.Offset, FieldName]));
  end;
end;

procedure DumpClass(Stream: TStream);
var
  Def: TDefClass;
  Name: String;
  Field: TFieldDescriptor;
  FieldName: String;
  I: Integer;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d ParentTypeID=%d VMT=0x%x InstSize=%d Fields=%d Name="%s"',
    [Def.TypeID, Def.ParentTypeID, Def.VMTAddress, Def.InstanceSize, Def.FieldCount, Name]));
  for I := 0 to Def.FieldCount - 1 do
  begin
    Stream.Read(Field, SizeOf(Field));
    FieldName := ReadString(Stream, Field.NameLen);
    WriteLn(Format('      [%d] TypeID=%d Offset=%d Name="%s"',
      [I, Field.FieldTypeID, Field.Offset, FieldName]));
  end;
end;

procedure DumpProperty(Stream: TStream);
var
  Def: TDefProperty;
  Name, ReadMeth, WriteMeth: String;
begin
  Stream.Read(Def, SizeOf(Def));
  ReadMeth := ReadString(Stream, Def.ReadMethodNameLen);
  WriteMeth := ReadString(Stream, Def.WriteMethodNameLen);
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    ClassTypeID=%d PropTypeID=%d Read=%d Write=%d Name="%s"',
    [Def.ClassTypeID, Def.PropertyTypeID, Def.ReadType, Def.WriteType, Name]));
  if ReadMeth <> '' then
    WriteLn(Format('      ReadMethod="%s"', [ReadMeth]));
  if WriteMeth <> '' then
    WriteLn(Format('      WriteMethod="%s"', [WriteMeth]));
end;

procedure DumpLocalVar(Stream: TStream);
var
  Def: TDefLocalVar;
  LocData: ShortInt;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Stream.Read(LocData, 1);
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d ScopeID=0x%x LocExpr=%d LocData=%d Name="%s"',
    [Def.TypeID, Def.ScopeID, Def.LocationExpr, LocData, Name]));
end;

procedure DumpParameter(Stream: TStream);
var
  Def: TDefParameter;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d Var=%d Const=%d Out=%d Name="%s"',
    [Def.TypeID, Def.IsVar, Def.IsConst, Def.IsOut, Name]));
end;

procedure DumpLineInfo(Stream: TStream; const FilterFile: String);
var
  Def: TDefLineInfo;
  FileName: String;
begin
  Stream.Read(Def, SizeOf(Def));
  FileName := ReadString(Stream, Def.FileNameLen);
  if (FilterFile = '') or (Pos(LowerCase(FilterFile), LowerCase(FileName)) > 0) then
    WriteLn(Format('    Addr=0x%x Line=%d Col=%d File="%s"',
      [Def.Address, Def.LineNumber, Def.ColumnNumber, FileName]));
end;

procedure DumpFunctionScope(Stream: TStream);
var
  Def: TDefFunctionScope;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    ScopeID=0x%x LowPC=0x%x HighPC=0x%x Name="%s"',
    [Def.ScopeID, Def.LowPC, Def.HighPC, Name]));
end;

procedure DumpInterface(Stream: TStream);
var
  Def: TDefInterface;
  Name: String;
  Meth: TInterfaceMethodDescriptor;
  MethName: String;
  I: Integer;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d ParentTypeID=%d IntfType=%d Methods=%d Name="%s"',
    [Def.TypeID, Def.ParentTypeID, Def.IntfType, Def.MethodCount, Name]));
  for I := 0 to Def.MethodCount - 1 do
  begin
    Stream.Read(Meth, SizeOf(Meth));
    MethName := ReadString(Stream, Meth.NameLen);
    WriteLn(Format('      [%d] RetTypeID=%d Params=%d Name="%s"',
      [I, Meth.ReturnTypeID, Meth.ParamCount, MethName]));
  end;
end;

procedure DumpEnum(Stream: TStream);
var
  Def: TDefEnum;
  Name: String;
  Member: TEnumMember;
  MemberName: String;
  I: Integer;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d Size=%d Members=%d Name="%s"',
    [Def.TypeID, Def.SizeInBytes, Def.MemberCount, Name]));
  for I := 0 to Def.MemberCount - 1 do
  begin
    Stream.Read(Member, SizeOf(Member));
    MemberName := ReadString(Stream, Member.NameLen);
    WriteLn(Format('      [%d] Value=%d Name="%s"', [I, Member.Value, MemberName]));
  end;
end;

procedure DumpSet(Stream: TStream);
var
  Def: TDefSet;
  Name: String;
begin
  Stream.Read(Def, SizeOf(Def));
  Name := ReadString(Stream, Def.NameLen);
  WriteLn(Format('    TypeID=%d BaseTypeID=%d Size=%d LowerBound=%d Name="%s"',
    [Def.TypeID, Def.BaseTypeID, Def.SizeInBytes, Def.LowerBound, Name]));
end;

procedure DumpUnitDirectory(Stream: TStream);
var
  UnitCnt: Word;
  DataSize: Cardinal;
  NameLen: Word;
  Name: String;
  I: Integer;
begin
  Stream.Read(UnitCnt, 2);
  WriteLn(Format('    UnitCount=%d', [UnitCnt]));
  for I := 0 to UnitCnt - 1 do
  begin
    Stream.Read(DataSize, 4);
    Stream.Read(NameLen, 2);
    Name := ReadString(Stream, NameLen);
    WriteLn(Format('      [%d] DataSize=%d Name="%s"', [I, DataSize, Name]));
  end;
end;


{ ---- Main processing ---- }

procedure ProcessSection(Stream: TMemoryStream);
var
  Header: TOPDFHeader;
  RecHeader: TOPDFRecordHeader;
  RecStart: Int64;
  UnitCounts: TRecordCounts;
  TypeIDSet: array of Cardinal;
  TypeIDCount: Integer;
  TypeIDCapacity: Integer;
  FilterTypeOrd: Integer;
  PeekHeader: TOPDFHeader;
  RecType: Byte;
  TypeID: Cardinal;
  I: Integer;
  Found: Boolean;
  ShowRecord: Boolean;

  procedure AddTypeID(ID: Cardinal);
  var
    J: Integer;
  begin
    { Check if already in set }
    for J := 0 to TypeIDCount - 1 do
      if TypeIDSet[J] = ID then
        Exit;
    { Add new }
    if TypeIDCount >= TypeIDCapacity then
    begin
      TypeIDCapacity := TypeIDCapacity * 2;
      SetLength(TypeIDSet, TypeIDCapacity);
    end;
    TypeIDSet[TypeIDCount] := ID;
    Inc(TypeIDCount);
  end;

  function ReadTypeIDFromPayload: Cardinal;
  begin
    { All type records have TypeID as first 4 bytes }
    Result := 0;
    if Stream.Position + 4 <= Stream.Size then
      Stream.Read(Result, 4);
    { Seek back so the record dumper can re-read from start }
    Stream.Seek(-4, soFromCurrent);
  end;

begin
  FilterTypeOrd := -1;
  if OptFilterType <> '' then
  begin
    FilterTypeOrd := RecTypeNameToOrd(OptFilterType);
    if FilterTypeOrd < 0 then
    begin
      WriteLn('[ERROR] Unknown record type: ', OptFilterType);
      Halt(1);
    end;
  end;

  { Initialize type ID tracking }
  TypeIDCapacity := 4096;
  TypeIDCount := 0;
  SetLength(TypeIDSet, TypeIDCapacity);

  FillChar(GlobalCounts, SizeOf(GlobalCounts), 0);
  UnitCount := 0;
  TotalRecords := 0;
  TotalTypeRecords := 0;

  { Find first OPDF header }
  Stream.Position := 0;

  while Stream.Position + SizeOf(TOPDFHeader) <= Stream.Size do
  begin
    { Read and validate OPDF header }
    Stream.Read(Header, SizeOf(Header));
    if Header.Magic <> OPDF_MAGIC then
    begin
      { Not a header — scan forward for next OPDF magic }
      Stream.Seek(-SizeOf(TOPDFHeader) + 1, soFromCurrent);
      Continue;
    end;

    Inc(UnitCount);
    FillChar(UnitCounts, SizeOf(UnitCounts), 0);

    if OptVerbose or (OptFilterFile = '') and (OptFilterType = '') then
      WriteLn(Format('Unit %d/%s at offset 0x%x (version=%d, arch=%s, ptr=%d)',
        [UnitCount, '?', Stream.Position - SizeOf(TOPDFHeader),
         Header.Version, ArchToString(TTargetArch(Header.TargetArch)),
         Header.PointerSize]));

    { Parse records until next header or end of stream }
    while Stream.Position + SizeOf(TOPDFRecordHeader) <= Stream.Size do
    begin
      { Peek ahead — is the next thing another OPDF header? }
      if Stream.Position + SizeOf(TOPDFHeader) <= Stream.Size then
      begin
        Stream.Read(PeekHeader, SizeOf(PeekHeader));
        Stream.Seek(-SizeOf(TOPDFHeader), soFromCurrent);
        if PeekHeader.Magic = OPDF_MAGIC then
          Break; { Next unit header found }
      end;

      { Read record header }
      Stream.Read(RecHeader, SizeOf(RecHeader));
      RecType := RecHeader.RecType;

      if (RecType > MAX_REC_TYPE) or (RecHeader.RecSize = 0) or
         (RecHeader.RecSize > 10000000) then
      begin
        { Invalid record — stop parsing this unit }
        Break;
      end;

      RecStart := Stream.Position;

      { Track type IDs }
      if IsTypeRecord(RecType) then
      begin
        Inc(TotalTypeRecords);
        TypeID := ReadTypeIDFromPayload;
        AddTypeID(TypeID);
      end;

      { Update counts }
      Inc(UnitCounts[RecType]);
      Inc(GlobalCounts[RecType]);
      Inc(TotalRecords);

      { Determine if we should show this record }
      ShowRecord := False;
      if OptVerbose then
        ShowRecord := True;
      if (OptFilterType <> '') and (RecType = FilterTypeOrd) then
        ShowRecord := True;
      if (OptFilterFile <> '') and (RecType = Ord(recLineInfo)) then
        ShowRecord := True;

      if ShowRecord then
      begin
        if not ((OptFilterFile <> '') and (RecType = Ord(recLineInfo))) then
          { For file filter, DumpLineInfo handles its own filtering }
          if (OptFilterType = '') or (RecType = FilterTypeOrd) then
            Write(Format('  [%d] %s (size=%d): ',
              [TotalRecords, RecordTypeToString(TOPDFRecordType(RecType)), RecHeader.RecSize]));

        case TOPDFRecordType(RecType) of
          recPrimitive:     DumpPrimitive(Stream);
          recGlobalVar:     DumpGlobalVar(Stream);
          recShortStr:      DumpShortString(Stream);
          recAnsiStr:       DumpAnsiString(Stream);
          recUnicodeStr:    DumpUnicodeString(Stream);
          recPointer:       DumpPointer(Stream);
          recArray:         DumpArray(Stream);
          recRecord:        DumpRecord(Stream);
          recClass:         DumpClass(Stream);
          recProperty:      DumpProperty(Stream);
          recLocalVar:      DumpLocalVar(Stream);
          recParameter:     DumpParameter(Stream);
          recLineInfo:      begin
                              if (OptFilterType <> '') or OptVerbose then
                                Write(Format('  [%d] LineInfo (size=%d): ', [TotalRecords, RecHeader.RecSize]));
                              DumpLineInfo(Stream, OptFilterFile);
                            end;
          recFunctionScope: DumpFunctionScope(Stream);
          recInterface:     DumpInterface(Stream);
          recEnum:          DumpEnum(Stream);
          recSet:           DumpSet(Stream);
          recUnitDirectory: DumpUnitDirectory(Stream);
        else
          { Unknown record type — skip }
        end;
      end;

      { Ensure stream position is correct regardless of whether we dumped }
      Stream.Position := RecStart + RecHeader.RecSize;
    end;

    { Print per-unit summary in default mode }
    if (not OptVerbose) and (OptFilterFile = '') and (OptFilterType = '') then
    begin
      Write('  ');
      for I := 0 to MAX_REC_TYPE do
        if UnitCounts[I] > 0 then
          Write(Format('%s: %d  ', [RecordTypeToString(TOPDFRecordType(I)), UnitCounts[I]]));
      WriteLn;
    end;
  end;

  UniqueTypeIDs := TypeIDCount;
end;

procedure PrintSummary(SectionSize: Int64);
var
  I: Integer;
  EstMemory: Int64;
  LineInfoCount, FuncScopeCount, TypeCount, LocalVarCount: Cardinal;
begin
  WriteLn;
  WriteLn('=== Summary ===');
  WriteLn(Format('Units:              %d', [UnitCount]));
  WriteLn(Format('Total records:      %d', [TotalRecords]));
  WriteLn;

  for I := 0 to MAX_REC_TYPE do
    if GlobalCounts[I] > 0 then
      WriteLn(Format('  %-18s %6d', [RecordTypeToString(TOPDFRecordType(I)) + ':', GlobalCounts[I]]));

  WriteLn;
  WriteLn(Format('Unique TypeIDs:     %d  (%d type records — %.1fx duplication)',
    [UniqueTypeIDs, TotalTypeRecords,
     TotalTypeRecords / Max(UniqueTypeIDs, 1)]));

  WriteLn(Format('Section size:       %s', [FormatSize(SectionSize)]));
  WriteLn(Format('Header overhead:    %s (%d headers x %d bytes)',
    [FormatSize(Int64(UnitCount) * SizeOf(TOPDFHeader)),
     UnitCount, SizeOf(TOPDFHeader)]));

  { Estimate reader memory }
  TypeCount := 0;
  for I := 0 to MAX_REC_TYPE do
    if IsTypeRecord(I) then
      Inc(TypeCount, GlobalCounts[I]);
  LineInfoCount := GlobalCounts[Ord(recLineInfo)];
  FuncScopeCount := GlobalCounts[Ord(recFunctionScope)];
  LocalVarCount := GlobalCounts[Ord(recLocalVar)];

  EstMemory := Int64(TypeCount) * 200 +     { TTypeInfo ~200 bytes avg }
               Int64(LineInfoCount) * 70 +   { PLineInfo ~40 + dup filename ~30 }
               Int64(FuncScopeCount) * 50 +  { PFunctionScope ~50 }
               Int64(LocalVarCount) * 40;    { PLocalVariableInfo ~40 }

  WriteLn(Format('Est. reader memory: %s (if all loaded into cache)',
    [FormatSize(EstMemory)]));
end;

procedure PrintUsage;
begin
  WriteLn('OPDF Dump - Diagnostic tool for OPDF debug sections');
  WriteLn;
  WriteLn('Usage: opdf_dump [options] <binary>');
  WriteLn;
  WriteLn('Options:');
  WriteLn('  -v               Verbose mode (decode every record)');
  WriteLn('  -f <filename>    Filter LineInfo by source filename');
  WriteLn('  -t <type>        Filter by record type name');
  WriteLn('  -h, --help       Show this help');
  WriteLn;
  WriteLn('Record types: Primitive, GlobalVar, ShortString, AnsiString,');
  WriteLn('  UnicodeString, Pointer, Array, Record, Class, Property,');
  WriteLn('  Method, LocalVar, Parameter, LineInfo, FunctionScope,');
  WriteLn('  Interface, Enum, Set, UnitDirectory');
end;

procedure ParseArgs;
var
  I: Integer;
begin
  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '-v' then
      OptVerbose := True
    else if ParamStr(I) = '-f' then
    begin
      Inc(I);
      if I > ParamCount then
      begin
        WriteLn('[ERROR] -f requires a filename argument');
        Halt(1);
      end;
      OptFilterFile := ParamStr(I);
    end
    else if ParamStr(I) = '-t' then
    begin
      Inc(I);
      if I > ParamCount then
      begin
        WriteLn('[ERROR] -t requires a type name argument');
        Halt(1);
      end;
      OptFilterType := ParamStr(I);
    end
    else if (ParamStr(I) = '-h') or (ParamStr(I) = '--help') then
    begin
      PrintUsage;
      Halt(0);
    end
    else if ParamStr(I)[1] = '-' then
    begin
      WriteLn('[ERROR] Unknown option: ', ParamStr(I));
      PrintUsage;
      Halt(1);
    end
    else
      BinaryPath := ParamStr(I);
    Inc(I);
  end;
end;

{ ---- Main ---- }

var
  Section: TMemoryStream;

begin
  ParseArgs;

  if BinaryPath = '' then
  begin
    PrintUsage;
    Halt(1);
  end;

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] File not found: ', BinaryPath);
    Halt(1);
  end;

  if not TELFSectionReader.IsELFBinary(BinaryPath) then
  begin
    WriteLn('[ERROR] Not an ELF binary: ', BinaryPath);
    Halt(1);
  end;

  Section := TELFSectionReader.ExtractSection(BinaryPath, '.opdf');
  if not Assigned(Section) then
  begin
    WriteLn('[ERROR] No .opdf section found in: ', BinaryPath);
    Halt(1);
  end;

  try
    WriteLn(Format('OPDF Section Analysis: %s', [ExtractFileName(BinaryPath)]));
    WriteLn(Format('Section size: %s', [FormatSize(Section.Size)]));
    WriteLn;

    Section.Position := 0;
    ProcessSection(Section);
    PrintSummary(Section.Size);
  finally
    Section.Free;
  end;
end.
