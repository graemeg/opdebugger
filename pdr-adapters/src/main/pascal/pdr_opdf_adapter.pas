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
  Classes, SysUtils, Contnrs, ogopdf, opdf_io, opdf_demangle, elf_reader, pdr_ports;

type
  { Pointer types for caching }
  PTypeInfo = ^TTypeInfo;
  PVariableInfo = ^TVariableInfo;
  PLineInfo = ^TLineInfo;

  { Function scope information }
  TFunctionScope = record
    ScopeID: Cardinal;      // low_pc address of function (unique identifier)
    LowPC: QWord;           // Start address of function
    HighPC: QWord;          // End address of function
    Name: String;           // Function name
  end;
  PFunctionScope = ^TFunctionScope;

  { Local variable information }
  TLocalVariableInfo = record
    Name: String;           // Variable name
    TypeID: TTypeID;        // Type identifier
    ScopeID: Cardinal;      // Function scope ID
    LocationExpr: Byte;     // Location expression type (1=RBP-relative)
    LocationData: ShortInt; // RBP offset (signed)
  end;
  PLocalVariableInfo = ^TLocalVariableInfo;
  TLocalVariableArray = array of TLocalVariableInfo;

  { OPDF Reader Adapter - implements IDebugInfoReader }
  TOPDFReaderAdapter = class(TInterfacedObject, IDebugInfoReader)
  private
    FBinaryPath: String;
    FOPDFPath: String;
    FReader: TOPDFReader;
    FStream: TStream;
    FHeader: TOPDFHeader;

    { Internal dictionaries for fast lookup }
    FTypes: TFPHashList;            // TypeID -> TTypeInfo
    FVariables: TFPHashList;        // Variable name -> TVariableInfo
    FLineInfo: TFPList;             // List of TLineInfo records
    FFunctionScopes: TFPList;       // List of TFunctionScope records
    FLocalVariables: TFPHashList;   // ScopeID -> TList of TLocalVariableInfo
    FLoaded: Boolean;

    { Helper methods }
    procedure ClearCache;
    function FindOPDFFile(const BinaryPath: String): String;
    function GetCurrentFunctionScope(RIP: QWord): Cardinal;
    function FindLocalVariablesInScope(ScopeID: Cardinal): TLocalVariableArray;
  public
    constructor Create;
    destructor Destroy; override;

    { IDebugInfoReader implementation }
    function Load(const BinaryPath: String): Boolean;
    function FindVariable(const Name: String; out VarInfo: TVariableInfo): Boolean;
    function FindVariableWithScope(const Name: String; RIP: QWord;
                                   out VarInfo: TVariableInfo): Boolean;
    function FindType(TypeID: TTypeID; out TypeInfo: TTypeInfo): Boolean;
    function GetGlobalVariables: TStringArray;
    function GetTargetArch: TTargetArch;
    function GetPointerSize: Byte;
    function FindAddressByLine(const FileName: String; LineNum: Cardinal;
                              out Address: QWord): Boolean;
    function FindLineByAddress(Address: QWord; out LineInfo: TLineInfo): Boolean;
    function GetFileLineEntries(const FileName: String): TLineInfoArray;
    function FindFunctionByAddress(Address: QWord; out FuncInfo: TFunctionInfo): Boolean;
  end;

implementation

{ TOPDFReaderAdapter }

constructor TOPDFReaderAdapter.Create;
begin
  inherited Create;
  FTypes := TFPHashList.Create;
  FVariables := TFPHashList.Create;
  FLineInfo := TFPList.Create;
  FFunctionScopes := TFPList.Create;
  FLocalVariables := TFPHashList.Create;
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
  FFunctionScopes.Free;
  FLocalVariables.Free;
  inherited Destroy;
end;

procedure TOPDFReaderAdapter.ClearCache;
var
  I, J: Integer;
  TypeInfo: TTypeInfo;
  VarInfo: TVariableInfo;
  LocalList: TFPList;
begin
  // Free cached type info
  for I := 0 to FTypes.Count - 1 do
  begin
    TypeInfo := TTypeInfo(FTypes[I]^);
    // Free ClassInfo if it's a class type
    if (TypeInfo.Category = tcClass) and (TypeInfo.ClassInfo <> nil) then
      Dispose(TypeInfo.ClassInfo);
    // Free RecordInfo if it's a record type
    if (TypeInfo.Category = tcRecord) and (TypeInfo.RecordInfo <> nil) then
      Dispose(TypeInfo.RecordInfo);
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

  // Free function scopes
  for I := 0 to FFunctionScopes.Count - 1 do
  begin
    Dispose(PFunctionScope(FFunctionScopes[I]));
  end;
  FFunctionScopes.Clear;

  // Free local variables (stored in lists)
  for I := 0 to FLocalVariables.Count - 1 do
  begin
    LocalList := TFPList(FLocalVariables[I]);
    for J := 0 to LocalList.Count - 1 do
      Dispose(PLocalVariableInfo(LocalList[J]));
    LocalList.Free;
  end;
  FLocalVariables.Clear;

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
  DefArray: TDefArray;
  DefLineInfo: TDefLineInfo;
  DefFunctionScope: TDefFunctionScope;
  DefLocalVar: TDefLocalVar;
  DefClass: TDefClass;
  DefPointer: TDefPointer;
  DefRecord: TDefRecord;
  DefEnum: TDefEnum;
  DefParameter: TDefParameter;
  DefInterface: TDefInterface;
  DefProperty: TDefProperty;
  ClassFields: TFieldDescriptorArray;
  ClassFieldNames: array of String;
  RecordFields: TFieldDescriptorArray;
  RecordFieldNames: TStringArray;
  EnumMembers: TEnumMemberArray;
  EnumMemberNames: TStringArray;
  IntfMethods: TInterfaceMethodDescriptorArray;
  IntfMethodNames: TStringArray;
  TypeName: String;
  VarName: String;
  FileName: String;
  FunctionName: String;
  LocationData: ShortInt;
  PType: PTypeInfo;
  PVar: PVariableInfo;
  PLine: PLineInfo;
  PLocal: PLocalVariableInfo;
  PScope: PFunctionScope;
  LocalList: TFPList;
  I: Integer;
  ELFStream: TMemoryStream;
  RecStartPos: Int64;
begin
  Result := False;

  // Clear any previously loaded data
  ClearCache;

  FBinaryPath := BinaryPath;

  // Try to extract .opdf section from ELF binary first
  if TELFSectionReader.IsELFBinary(BinaryPath) then
  begin
    ELFStream := TELFSectionReader.ExtractSection(BinaryPath, '.opdf');
    if Assigned(ELFStream) then
    begin
      WriteLn('[INFO] Loading embedded OPDF section from: ', BinaryPath);
      FStream := ELFStream; { FStream owns the TMemoryStream }
      FOPDFPath := BinaryPath;
      FReader := TOPDFReader.Create(FStream);
    end;
  end;

  // Fall back to external .opdf file
  if not Assigned(FStream) then
  begin
    FOPDFPath := FindOPDFFile(BinaryPath);
    if FOPDFPath = '' then
    begin
      WriteLn('[ERROR] OPDF data not found for binary: ', BinaryPath);
      Exit;
    end;

    WriteLn('[INFO] Loading OPDF file: ', FOPDFPath);

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

    { Save position after header so we can ensure correct alignment }
    RecStartPos := FStream.Position;

    RecType := TOPDFRecordType(RecHeader.RecType);

    case RecType of
      recPrimitive:
        begin
          if FReader.ReadPrimitive(DefPrimitive, TypeName) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefPrimitive.TypeID;
            PType^.Name := TypeName;
            PType^.Size := DefPrimitive.SizeInBytes;
            PType^.IsSigned := DefPrimitive.IsSigned <> 0;
            PType^.MaxLength := 0;

            { Detect float types by name — FPC emits them as primitives }
            if (TypeName = 'Single') or (TypeName = 'Double') or
               (TypeName = 'Extended') or (TypeName = 'Currency') or
               (TypeName = 'Comp') or (TypeName = 'Real') then
              PType^.Category := tcFloat
            else
              PType^.Category := tcPrimitive;

            FTypes.Add(IntToStr(DefPrimitive.TypeID), PType);
          end;
        end;

      recShortStr:
        begin
          if FReader.ReadShortString(DefShortString, TypeName) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefShortString.TypeID;
            PType^.Name := TypeName;
            PType^.Size := DefShortString.MaxLength + 1; // Length byte + data
            PType^.IsSigned := False;
            PType^.Category := tcShortString;
            PType^.MaxLength := DefShortString.MaxLength;

            FTypes.Add(IntToStr(DefShortString.TypeID), PType);
          end;
        end;

      recAnsiStr:
        begin
          if FReader.ReadAnsiString(DefAnsiString, TypeName) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefAnsiString.TypeID;
            PType^.Name := TypeName;
            PType^.Size := 8; // Pointer size (64-bit)
            PType^.IsSigned := False;
            PType^.Category := tcAnsiString;
            PType^.MaxLength := 0;

            FTypes.Add(IntToStr(DefAnsiString.TypeID), PType);
          end;
        end;

      recUnicodeStr:
        begin
          if FReader.ReadUnicodeString(DefUnicodeString, TypeName) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
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
            PVar^.LocationExpr := 0;      // Global variables don't have location expressions
            PVar^.LocationData := 0;

            // Store with mangled name for lookup (since OPDF has mangled names)
            FVariables.Add(VarName, PVar);
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
          end;
        end;

      recClass:
        begin
          if FReader.ReadClass(DefClass, TypeName, ClassFields, ClassFieldNames) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
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
          end;
        end;

      recLocalVar:
        begin
          if FReader.ReadLocalVar(DefLocalVar, LocationData, VarName) then
          begin
            { Get or create local variables list for this scope }
            LocalList := TFPList(FLocalVariables.Find(IntToStr(DefLocalVar.ScopeID)));
            if not Assigned(LocalList) then
            begin
              LocalList := TFPList.Create;
              FLocalVariables.Add(IntToStr(DefLocalVar.ScopeID), LocalList);
            end;

            { Add local variable to scope's list }
            New(PLocal);
            PLocal^.Name := VarName;
            PLocal^.TypeID := DefLocalVar.TypeID;
            PLocal^.ScopeID := DefLocalVar.ScopeID;
            PLocal^.LocationExpr := DefLocalVar.LocationExpr;
            PLocal^.LocationData := LocationData;

            LocalList.Add(PLocal);
          end;
        end;

      recFunctionScope:
        begin
          if FReader.ReadFunctionScope(DefFunctionScope, FunctionName) then
          begin
            { Add function scope to cache }
            New(PScope);
            PScope^.ScopeID := DefFunctionScope.ScopeID;
            PScope^.LowPC := DefFunctionScope.LowPC;
            PScope^.HighPC := DefFunctionScope.HighPC;
            PScope^.Name := FunctionName;

            FFunctionScopes.Add(PScope);
            WriteLn('[DEBUG] Loaded function scope: ', FunctionName,
                    ' [$', IntToHex(DefFunctionScope.LowPC, 8), ' - $',
                    IntToHex(DefFunctionScope.HighPC, 8), ']');
          end;
        end;

      recArray:
        begin
          if FReader.ReadArray(DefArray, TypeName) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefArray.TypeID;
            PType^.Name := TypeName;
            PType^.Size := 0;  // Arrays have variable size
            PType^.IsSigned := False;
            PType^.Category := tcArray;
            PType^.MaxLength := 0;
            PType^.ElementTypeID := DefArray.ElementTypeID;
            PType^.IsDynamic := DefArray.IsDynamic <> 0;
            PType^.Dimensions := DefArray.Dimensions;

            { Read bounds for static arrays }
            if (DefArray.IsDynamic = 0) and (DefArray.Dimensions > 0) then
            begin
              SetLength(PType^.Bounds, DefArray.Dimensions);
              for I := 0 to DefArray.Dimensions - 1 do
                FStream.Read(PType^.Bounds[I], SizeOf(TArrayBound));
            end
            else
              SetLength(PType^.Bounds, 0);

            FTypes.Add(IntToStr(DefArray.TypeID), PType);
          end;
        end;

      recPointer:
        begin
          if FReader.ReadPointer(DefPointer, TypeName) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefPointer.TypeID;
            PType^.Name := TypeName;
            PType^.Size := 8;  // Pointer size (64-bit)
            PType^.IsSigned := False;
            PType^.Category := tcPointer;
            PType^.MaxLength := 0;
            PType^.PointerTo := DefPointer.TargetTypeID;

            FTypes.Add(IntToStr(DefPointer.TypeID), PType);
          end;
        end;

      recRecord:
        begin
          if FReader.ReadRecord(DefRecord, TypeName, RecordFields, RecordFieldNames) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefRecord.TypeID;
            PType^.Name := TypeName;
            PType^.Size := DefRecord.TotalSize;
            PType^.IsSigned := False;
            PType^.Category := tcRecord;
            PType^.MaxLength := 0;

            { Allocate and populate RecordInfo }
            New(PType^.RecordInfo);
            PType^.RecordInfo^.TotalSize := DefRecord.TotalSize;
            SetLength(PType^.RecordInfo^.Fields, DefRecord.FieldCount);
            for I := 0 to DefRecord.FieldCount - 1 do
            begin
              PType^.RecordInfo^.Fields[I].Name := RecordFieldNames[I];
              PType^.RecordInfo^.Fields[I].TypeID := RecordFields[I].FieldTypeID;
              PType^.RecordInfo^.Fields[I].Offset := RecordFields[I].Offset;
            end;

            FTypes.Add(IntToStr(DefRecord.TypeID), PType);
          end;
        end;

      recEnum:
        begin
          if FReader.ReadEnum(DefEnum, TypeName, EnumMembers, EnumMemberNames) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefEnum.TypeID;
            PType^.Name := TypeName;
            PType^.Size := DefEnum.SizeInBytes;
            PType^.IsSigned := False;
            PType^.Category := tcEnum;
            PType^.MaxLength := 0;

            { Store enum members for display }
            SetLength(PType^.EnumMembers, DefEnum.MemberCount);
            for I := 0 to DefEnum.MemberCount - 1 do
            begin
              PType^.EnumMembers[I].Name := EnumMemberNames[I];
              PType^.EnumMembers[I].Value := EnumMembers[I].Value;
            end;

            FTypes.Add(IntToStr(DefEnum.TypeID), PType);
          end;
        end;

      recProperty:
        begin
          if FReader.ReadProperty(DefProperty, VarName) then
          begin
            { Find the owning class by ClassTypeID and add this property }
            for I := 0 to FTypes.Count - 1 do
            begin
              PType := PTypeInfo(FTypes[I]);
              if Assigned(PType) and (PType^.TypeID = DefProperty.ClassTypeID) and
                 (PType^.Category = tcClass) and Assigned(PType^.ClassInfo) then
              begin
                { Append to Properties array }
                SetLength(PType^.ClassInfo^.Properties,
                          Length(PType^.ClassInfo^.Properties) + 1);
                with PType^.ClassInfo^.Properties[High(PType^.ClassInfo^.Properties)] do
                begin
                  Name := VarName;
                  TypeID := DefProperty.PropertyTypeID;
                  ReadKind  := TPropertyAccessKind(DefProperty.ReadType);
                  WriteKind := TPropertyAccessKind(DefProperty.WriteType);
                  ReadOffset  := DefProperty.ReadAddr;
                  WriteOffset := DefProperty.WriteAddr;
                end;
                Break;
              end;
            end;
          end;
        end;

      recParameter:
        begin
          { Parameters are informational - skip for now }
          if not FReader.ReadParameter(DefParameter, VarName) then
            FReader.SkipRecord(RecHeader);
        end;

      recInterface:
        begin
          if FReader.ReadInterface(DefInterface, TypeName, IntfMethods, IntfMethodNames) then
          begin
            New(PType);
            FillChar(PType^, SizeOf(TTypeInfo), 0);
            PType^.TypeID := DefInterface.TypeID;
            PType^.Name := TypeName;
            PType^.Size := 8;  // Interface is a pointer
            PType^.IsSigned := False;
            PType^.Category := tcInterface;
            PType^.MaxLength := 0;

            FTypes.Add(IntToStr(DefInterface.TypeID), PType);
          end;
        end;

      else
        ; { Unknown record types handled by seek below }
    end;

    { Ensure stream is at correct position for next record.
      Some readers may not consume all payload bytes (e.g. ReadArray
      doesn't read static array bounds). This guarantees alignment. }
    FStream.Position := RecStartPos + RecHeader.RecSize;
  end;

  WriteLn('[INFO] Loaded ', FTypes.Count, ' type(s), ', FVariables.Count,
          ' variable(s), ', FFunctionScopes.Count, ' function scope(s), and ',
          FLineInfo.Count, ' line mapping(s)');

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
        Exit;
      end;
    end;
  end;

  WriteLn('[DEBUG] Variable not found: ', Name);
end;

{ Find variable with scope awareness - checks local variables first, then globals }
function TOPDFReaderAdapter.FindVariableWithScope(const Name: String; RIP: QWord;
                                                  out VarInfo: TVariableInfo): Boolean;
var
  ScopeID: Cardinal;
  Locals: TLocalVariableArray;
  I: Integer;
  LocalVar: TLocalVariableInfo;
  SearchName: String;
  DemangledName: String;
begin
  Result := False;

  if not FLoaded then
  begin
    WriteLn('[ERROR] OPDF file not loaded');
    Exit;
  end;

  SearchName := LowerCase(Name);

  { Try to find in local variables first }
  ScopeID := GetCurrentFunctionScope(RIP);
  if ScopeID <> 0 then
  begin
    Locals := FindLocalVariablesInScope(ScopeID);
    for I := 0 to High(Locals) do
    begin
      LocalVar := Locals[I];
      { Case-insensitive comparison }
      if LowerCase(LocalVar.Name) = SearchName then
      begin
        { Found local variable - convert to VarInfo }
        VarInfo.Name := LocalVar.Name;
        VarInfo.TypeID := LocalVar.TypeID;
        VarInfo.Address := 0; { Will be computed from RBP + LocationData }
        VarInfo.LocationExpr := LocalVar.LocationExpr;
        VarInfo.LocationData := LocalVar.LocationData;
        Result := True;
        WriteLn('[DEBUG] Found local var: ', LocalVar.Name, ' LocationExpr=', LocalVar.LocationExpr,
                ' LocationData=', LocalVar.LocationData);
        Exit;
      end;
    end;
  end;

  { Fall back to global variables }
  Result := FindVariable(Name, VarInfo);
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
      Exit(False);

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

{ Find function scope containing a given RIP (instruction pointer) }
function TOPDFReaderAdapter.GetCurrentFunctionScope(RIP: QWord): Cardinal;
var
  I: Integer;
  FuncScope: PFunctionScope;
begin
  Result := 0;

  if not FLoaded then
    Exit;

  { Search for function scope containing RIP }
  for I := 0 to FFunctionScopes.Count - 1 do
  begin
    FuncScope := PFunctionScope(FFunctionScopes[I]);
    if (RIP >= FuncScope^.LowPC) and (RIP < FuncScope^.HighPC) then
    begin
      Result := FuncScope^.ScopeID;
      Exit;
    end;
  end;
end;

{ Find all local variables in a given scope }
function TOPDFReaderAdapter.FindLocalVariablesInScope(ScopeID: Cardinal): TLocalVariableArray;
var
  LocalList: TFPList;
  I: Integer;
begin
  SetLength(Result, 0);

  if not FLoaded then
    Exit;

  { Get list of locals for this scope }
  LocalList := TFPList(FLocalVariables.Find(IntToStr(ScopeID)));
  if not Assigned(LocalList) then
    Exit;

  { Copy locals to result array }
  SetLength(Result, LocalList.Count);
  for I := 0 to LocalList.Count - 1 do
    Result[I] := PLocalVariableInfo(LocalList[I])^;
end;

{ Find function by address }
function TOPDFReaderAdapter.FindFunctionByAddress(Address: QWord; out FuncInfo: TFunctionInfo): Boolean;
var
  I: Integer;
  FuncScope: PFunctionScope;
begin
  Result := False;
  FuncInfo.Name := '';
  FuncInfo.LowPC := 0;
  FuncInfo.HighPC := 0;

  if not FLoaded then
    Exit;

  { Find function scope containing the address }
  for I := 0 to FFunctionScopes.Count - 1 do
  begin
    FuncScope := PFunctionScope(FFunctionScopes[I]);
    if (Address >= FuncScope^.LowPC) and (Address < FuncScope^.HighPC) then
    begin
      FuncInfo.Name := FuncScope^.Name;
      FuncInfo.LowPC := FuncScope^.LowPC;
      FuncInfo.HighPC := FuncScope^.HighPC;
      Result := True;
      Exit;
    end;
  end;
end;

end.
