{
  PDR Debugger - OPDF Reader Adapter

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit implements the IDebugInfoReader interface for OPDF format.
}
unit pdr_opdf_adapter;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Contnrs, ogopdf, opdf_io, opdf_demangle, pdr_ports;

type
  { Pointer types for caching }
  PTypeInfo = ^TTypeInfo;
  PVariableInfo = ^TVariableInfo;
  PLineInfo = ^TLineInfo;

  { OPDF Reader Adapter - implements IDebugInfoReader }
  TOPDFReaderAdapter = class(TInterfacedObject, IDebugInfoReader)
  private
    FBinaryPath: String;
    FOPDFPath: String;
    FReader: TOPDFReader;
    FStream: TFileStream;
    FHeader: TOPDFHeader;

    { Internal dictionaries for fast lookup }
    FTypes: TFPHashList;        // TypeID -> TTypeInfo
    FVariables: TFPHashList;    // Variable name -> TVariableInfo
    FLineInfo: TFPList;         // List of TLineInfo records
    FLoaded: Boolean;

    { Helper methods }
    procedure ClearCache;
    function FindOPDFFile(const BinaryPath: String): String;
  public
    constructor Create;
    destructor Destroy; override;

    { IDebugInfoReader implementation }
    function Load(const BinaryPath: String): Boolean;
    function FindVariable(const Name: String; out VarInfo: TVariableInfo): Boolean;
    function FindType(TypeID: TTypeID; out TypeInfo: TTypeInfo): Boolean;
    function GetGlobalVariables: TStringArray;
    function GetTargetArch: TTargetArch;
    function GetPointerSize: Byte;
    function FindAddressByLine(const FileName: String; LineNum: Cardinal;
                              out Address: QWord): Boolean;
    function FindLineByAddress(Address: QWord; out LineInfo: TLineInfo): Boolean;
    function GetFileLineEntries(const FileName: String): TLineInfoArray;
  end;

implementation

{ TOPDFReaderAdapter }

constructor TOPDFReaderAdapter.Create;
begin
  inherited Create;
  FTypes := TFPHashList.Create;
  FVariables := TFPHashList.Create;
  FLineInfo := TFPList.Create;
  FReader := nil;
  FStream := nil;
  FLoaded := False;
end;

destructor TOPDFReaderAdapter.Destroy;
begin
  ClearCache;
  FTypes.Free;
  FVariables.Free;
  FLineInfo.Free;
  inherited Destroy;
end;

procedure TOPDFReaderAdapter.ClearCache;
var
  I: Integer;
  TypeInfo: TTypeInfo;
  VarInfo: TVariableInfo;
begin
  // Free cached type info
  for I := 0 to FTypes.Count - 1 do
  begin
    TypeInfo := TTypeInfo(FTypes[I]^);
    // Free ClassInfo if it's a class type
    if (TypeInfo.Category = tcClass) and (TypeInfo.ClassInfo <> nil) then
      Dispose(TypeInfo.ClassInfo);
    Dispose(PTypeInfo(FTypes[I]));
  end;
  FTypes.Clear;

  // Free cached variable info
  for I := 0 to FVariables.Count - 1 do
  begin
    VarInfo := TVariableInfo(FVariables[I]^);
    Dispose(PVariableInfo(FVariables[I]));
  end;
  FVariables.Clear;

  // Free cached line info
  for I := 0 to FLineInfo.Count - 1 do
  begin
    Dispose(PLineInfo(FLineInfo[I]));
  end;
  FLineInfo.Clear;

  // Free reader and stream
  FreeAndNil(FReader);
  FreeAndNil(FStream);

  FLoaded := False;
end;

function TOPDFReaderAdapter.FindOPDFFile(const BinaryPath: String): String;
var
  BaseDir: String;
  BaseName: String;
begin
  Result := '';

  // Try .opdf file with same basename
  Result := ChangeFileExt(BinaryPath, '.opdf');
  if FileExists(Result) then
    Exit;

  // Try in same directory with .debug extension
  BaseDir := ExtractFilePath(BinaryPath);
  BaseName := ExtractFileName(BinaryPath);
  Result := BaseDir + BaseName + '.debug.opdf';
  if FileExists(Result) then
    Exit;

  // Try in .debug subdirectory
  Result := BaseDir + '.debug/' + BaseName + '.opdf';
  if FileExists(Result) then
    Exit;

  // Not found
  Result := '';
end;

function TOPDFReaderAdapter.Load(const BinaryPath: String): Boolean;
var
  RecType: TOPDFRecordType;
  RecHeader: TOPDFRecordHeader;
  DefPrimitive: TDefPrimitive;
  DefShortString: TDefShortString;
  DefAnsiString: TDefAnsiString;
  DefUnicodeString: TDefUnicodeString;
  DefGlobalVar: TDefGlobalVar;
  DefLineInfo: TDefLineInfo;
  DefClass: TDefClass;
  ClassFields: TFieldDescriptorArray;
  ClassFieldNames: array of String;
  TypeName: String;
  VarName: String;
  FileName: String;
  PType: PTypeInfo;
  PVar: PVariableInfo;
  PLine: PLineInfo;
  I: Integer;
begin
  Result := False;

  // Clear any previously loaded data
  ClearCache;

  FBinaryPath := BinaryPath;

  // Find OPDF file
  FOPDFPath := FindOPDFFile(BinaryPath);
  if FOPDFPath = '' then
  begin
    WriteLn('[ERROR] OPDF file not found for binary: ', BinaryPath);
    Exit;
  end;

  WriteLn('[INFO] Loading OPDF file: ', FOPDFPath);

  // Open OPDF file
  try
    FStream := TFileStream.Create(FOPDFPath, fmOpenRead or fmShareDenyWrite);
    FReader := TOPDFReader.Create(FStream);
  except
    on E: Exception do
    begin
      WriteLn('[ERROR] Failed to open OPDF file: ', E.Message);
      Exit;
    end;
  end;

  // Read and validate header
  if not FReader.ReadHeader then
  begin
    WriteLn('[ERROR] Failed to read OPDF header');
    Exit;
  end;

  FHeader := FReader.Header;

  if not IsValidOPDFHeader(FHeader) then
  begin
    WriteLn('[ERROR] Invalid OPDF header');
    Exit;
  end;

  WriteLn('[INFO] OPDF version: ', FHeader.Version);
  WriteLn('[INFO] Target architecture: ', ArchToString(TTargetArch(FHeader.TargetArch)));
  WriteLn('[INFO] Pointer size: ', FHeader.PointerSize, ' bytes');
  WriteLn('[INFO] Total records: ', FHeader.TotalRecords);

  // Read all records and cache them
  while not FReader.AtEnd do
  begin
    if not FReader.ReadRecordHeader(RecHeader) then
      Break;

    RecType := TOPDFRecordType(RecHeader.RecType);

    case RecType of
      recPrimitive:
        begin
          if FReader.ReadPrimitive(DefPrimitive, TypeName) then
          begin
            New(PType);
            PType^.TypeID := DefPrimitive.TypeID;
            PType^.Name := TypeName;
            PType^.Size := DefPrimitive.SizeInBytes;
            PType^.IsSigned := DefPrimitive.IsSigned <> 0;
            PType^.Category := tcPrimitive;
            PType^.MaxLength := 0;

            FTypes.Add(IntToStr(DefPrimitive.TypeID), PType);

            WriteLn('[DEBUG] Loaded type: ', TypeName, ' (TypeID=', DefPrimitive.TypeID, ')');
          end;
        end;

      recShortStr:
        begin
          if FReader.ReadShortString(DefShortString, TypeName) then
          begin
            New(PType);
            PType^.TypeID := DefShortString.TypeID;
            PType^.Name := TypeName;
            PType^.Size := DefShortString.MaxLength + 1; // Length byte + data
            PType^.IsSigned := False;
            PType^.Category := tcShortString;
            PType^.MaxLength := DefShortString.MaxLength;

            FTypes.Add(IntToStr(DefShortString.TypeID), PType);

            WriteLn('[DEBUG] Loaded type: ShortString[', DefShortString.MaxLength, '] (TypeID=', DefShortString.TypeID, ')');
          end;
        end;

      recAnsiStr:
        begin
          if FReader.ReadAnsiString(DefAnsiString, TypeName) then
          begin
            New(PType);
            PType^.TypeID := DefAnsiString.TypeID;
            PType^.Name := TypeName;
            PType^.Size := 8; // Pointer size (64-bit)
            PType^.IsSigned := False;
            PType^.Category := tcAnsiString;
            PType^.MaxLength := 0;

            FTypes.Add(IntToStr(DefAnsiString.TypeID), PType);

            WriteLn('[DEBUG] Loaded type: AnsiString (TypeID=', DefAnsiString.TypeID, ')');
          end;
        end;

      recUnicodeStr:
        begin
          if FReader.ReadUnicodeString(DefUnicodeString, TypeName) then
          begin
            New(PType);
            PType^.TypeID := DefUnicodeString.TypeID;
            PType^.Name := TypeName;
            PType^.Size := 8; // Pointer size (64-bit)
            PType^.IsSigned := False;
            // Distinguish UnicodeString vs WideString by name
            if Pos('Wide', TypeName) > 0 then
              PType^.Category := tcWideString
            else
              PType^.Category := tcUnicodeString;
            PType^.MaxLength := 0;

            FTypes.Add(IntToStr(DefUnicodeString.TypeID), PType);

            WriteLn('[DEBUG] Loaded type: ', TypeName, ' (TypeID=', DefUnicodeString.TypeID, ')');
          end;
        end;

      recGlobalVar:
        begin
          if FReader.ReadGlobalVar(DefGlobalVar, VarName) then
          begin
            New(PVar);
            PVar^.Name := VarName;
            PVar^.TypeID := DefGlobalVar.TypeID;
            PVar^.Address := DefGlobalVar.Address;

            // Store with mangled name for lookup (since OPDF has mangled names)
            FVariables.Add(VarName, PVar);

            WriteLn('[DEBUG] Loaded variable: ', VarName, ' at $', IntToHex(DefGlobalVar.Address, 16));
          end;
        end;

      recLineInfo:
        begin
          if FReader.ReadLineInfo(DefLineInfo, FileName) then
          begin
            New(PLine);
            PLine^.Address := DefLineInfo.Address;
            PLine^.FileName := FileName;
            PLine^.LineNumber := DefLineInfo.LineNumber;
            PLine^.ColumnNumber := DefLineInfo.ColumnNumber;

            FLineInfo.Add(PLine);

            WriteLn('[DEBUG] Loaded line info: ', FileName, ':', DefLineInfo.LineNumber,
                    ' -> 0x', IntToHex(DefLineInfo.Address, 8));
          end;
        end;

      recClass:
        begin
          if FReader.ReadClass(DefClass, TypeName, ClassFields, ClassFieldNames) then
          begin
            New(PType);
            PType^.TypeID := DefClass.TypeID;
            PType^.Name := TypeName;
            PType^.Size := 8;  // Classes are pointers
            PType^.IsSigned := False;
            PType^.Category := tcClass;
            PType^.MaxLength := 0;

            // Allocate and populate ClassInfo
            New(PType^.ClassInfo);
            PType^.ClassInfo^.ParentTypeID := DefClass.ParentTypeID;
            PType^.ClassInfo^.VMTAddress := DefClass.VMTAddress;
            PType^.ClassInfo^.InstanceSize := DefClass.InstanceSize;

            // Copy field information
            SetLength(PType^.ClassInfo^.Fields, DefClass.FieldCount);
            for I := 0 to DefClass.FieldCount - 1 do
            begin
              PType^.ClassInfo^.Fields[I].Name := ClassFieldNames[I];
              PType^.ClassInfo^.Fields[I].TypeID := ClassFields[I].FieldTypeID;
              PType^.ClassInfo^.Fields[I].Offset := ClassFields[I].Offset;
            end;

            FTypes.Add(IntToStr(DefClass.TypeID), PType);

            WriteLn('[DEBUG] Loaded class: ', TypeName, ' (TypeID=', DefClass.TypeID,
                    ', Fields=', DefClass.FieldCount, ')');
          end;
        end;

      else
        // Skip unknown record types
        FReader.SkipRecord(RecHeader);
    end;
  end;

  WriteLn('[INFO] Loaded ', FTypes.Count, ' type(s), ', FVariables.Count,
          ' variable(s), and ', FLineInfo.Count, ' line mapping(s)');

  FLoaded := True;
  Result := True;
end;

function TOPDFReaderAdapter.FindVariable(const Name: String; out VarInfo: TVariableInfo): Boolean;
var
  PVar: PVariableInfo;
  I: Integer;
  DemangledName: String;
  SearchName: String;
begin
  Result := False;

  if not FLoaded then
  begin
    WriteLn('[ERROR] OPDF file not loaded');
    Exit;
  end;

  // First try exact match (for mangled names)
  PVar := PVariableInfo(FVariables.Find(Name));
  if Assigned(PVar) then
  begin
    VarInfo := PVar^;
    Result := True;
    Exit;
  end;

  // If not found, try searching by demangled name (case-insensitive)
  SearchName := LowerCase(Name);
  for I := 0 to FVariables.Count - 1 do
  begin
    PVar := PVariableInfo(FVariables[I]);
    if Assigned(PVar) then
    begin
      // Demangle the variable name and compare
      DemangledName := TFPCDemangler.Demangle(PVar^.Name);
      if LowerCase(DemangledName) = SearchName then
      begin
        VarInfo := PVar^;
        Result := True;
        WriteLn('[DEBUG] Found variable by demangled name: ', Name, ' -> ', PVar^.Name);
        Exit;
      end;
    end;
  end;

  WriteLn('[DEBUG] Variable not found: ', Name);
end;

function TOPDFReaderAdapter.FindType(TypeID: TTypeID; out TypeInfo: TTypeInfo): Boolean;
var
  PType: PTypeInfo;
  I: Integer;
begin
  Result := False;

  if not FLoaded then
  begin
    WriteLn('[ERROR] OPDF file not loaded');
    Exit;
  end;

  // Search by TypeID (hash list uses TypeID as hash)
  for I := 0 to FTypes.Count - 1 do
  begin
    PType := PTypeInfo(FTypes[I]);
    if Assigned(PType) and (PType^.TypeID = TypeID) then
    begin
      TypeInfo := PType^;
      Result := True;
      Exit;
    end;
  end;

  WriteLn('[DEBUG] Type not found: TypeID=', TypeID);
end;

function TOPDFReaderAdapter.GetGlobalVariables: TStringArray;
var
  I: Integer;
  PVar: PVariableInfo;
begin
  SetLength(Result, FVariables.Count);

  for I := 0 to FVariables.Count - 1 do
  begin
    PVar := PVariableInfo(FVariables[I]);
    if Assigned(PVar) then
      Result[I] := PVar^.Name;
  end;
end;

function TOPDFReaderAdapter.GetTargetArch: TTargetArch;
begin
  if FLoaded then
    Result := TTargetArch(FHeader.TargetArch)
  else
    Result := archUnknown;
end;

function TOPDFReaderAdapter.GetPointerSize: Byte;
begin
  if FLoaded then
    Result := FHeader.PointerSize
  else
    Result := 0;
end;

function TOPDFReaderAdapter.FindAddressByLine(const FileName: String;
  LineNum: Cardinal; out Address: QWord): Boolean;
var
  I: Integer;
  Entry: PLineInfo;
  NormalizedFile, NormalizedEntry: String;
begin
  Result := False;

  if not FLoaded then
    Exit;

  // Normalize file name (compare just the base name, not full path)
  NormalizedFile := ExtractFileName(FileName);

  for I := 0 to FLineInfo.Count - 1 do
  begin
    Entry := PLineInfo(FLineInfo[I]);
    NormalizedEntry := ExtractFileName(Entry^.FileName);

    if (CompareText(NormalizedFile, NormalizedEntry) = 0) and
       (Entry^.LineNumber = LineNum) then
    begin
      Address := Entry^.Address;
      Result := True;
      Exit;
    end;
  end;
end;

function TOPDFReaderAdapter.FindLineByAddress(Address: QWord;
  out LineInfo: TLineInfo): Boolean;
var
  I: Integer;
  Entry: PLineInfo;
  BestEntry: PLineInfo;
  BestDistance: QWord;
  Distance: QWord;
begin
  Result := False;
  BestEntry := nil;
  BestDistance := High(QWord);

  if not FLoaded then
    Exit;

  // Find the closest line info entry with address <= given address
  for I := 0 to FLineInfo.Count - 1 do
  begin
    Entry := PLineInfo(FLineInfo[I]);

    if Entry^.Address <= Address then
    begin
      Distance := Address - Entry^.Address;
      if Distance < BestDistance then
      begin
        BestDistance := Distance;
        BestEntry := Entry;
      end;
    end;
  end;

  if BestEntry <> nil then
  begin
    // Sanity check: if the distance is too large (>1MB), this is probably wrong
    // The address is likely in a different function or library code
    if BestDistance > 1024 * 1024 then
    begin
      WriteLn('[DEBUG] FindLineByAddress: Address 0x', IntToHex(Address, 16),
              ' is ', BestDistance, ' bytes past closest line (line ',
              BestEntry^.LineNumber, ' at 0x', IntToHex(BestEntry^.Address, 16), ')');
      WriteLn('[DEBUG] This is likely library code, not user code');
      Exit(False);
    end;

    LineInfo := BestEntry^;
    Result := True;
  end;
end;

function TOPDFReaderAdapter.GetFileLineEntries(const FileName: String): TLineInfoArray;
var
  I, Count: Integer;
  Entry: PLineInfo;
  NormalizedFile, NormalizedEntry: String;
begin
  SetLength(Result, 0);

  if not FLoaded then
    Exit;

  // Normalize file name
  NormalizedFile := ExtractFileName(FileName);

  // Count matching entries
  Count := 0;
  for I := 0 to FLineInfo.Count - 1 do
  begin
    Entry := PLineInfo(FLineInfo[I]);
    NormalizedEntry := ExtractFileName(Entry^.FileName);

    if CompareText(NormalizedFile, NormalizedEntry) = 0 then
      Inc(Count);
  end;

  // Allocate result array
  SetLength(Result, Count);

  // Fill result array
  Count := 0;
  for I := 0 to FLineInfo.Count - 1 do
  begin
    Entry := PLineInfo(FLineInfo[I]);
    NormalizedEntry := ExtractFileName(Entry^.FileName);

    if CompareText(NormalizedFile, NormalizedEntry) = 0 then
    begin
      Result[Count] := Entry^;
      Inc(Count);
    end;
  end;
end;

end.
