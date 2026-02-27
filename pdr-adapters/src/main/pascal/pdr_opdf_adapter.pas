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
  Classes, SysUtils, Contnrs, opdf_types, opdf_io, opdf_demangle, elf_reader, pdr_ports;

type
  { Pointer types for caching }
  PTypeInfo = ^TTypeInfo;
  PVariableInfo = ^TVariableInfo;
  PConstantInfo = ^TConstantInfo;
  PLineInfo = ^TLineInfo;

  { Function scope information }
  TFunctionScope = record
    ScopeID: Cardinal;      // low_pc address of function (unique identifier)
    LowPC: QWord;           // Start address of function
    HighPC: QWord;          // End address of function
    Name: String;           // Function name
    DeclIndex: Word;        // Declaration order in parent scope
  end;
  PFunctionScope = ^TFunctionScope;

  { Local variable information }
  TLocalVariableInfo = record
    Name: String;           // Variable name
    TypeID: TTypeID;        // Type identifier
    ScopeID: Cardinal;      // Function scope ID
    LocationExpr: Byte;     // Location expression type (1=RBP-relative)
    LocationData: ShortInt; // RBP offset (signed)
    DeclIndex: Word;        // Declaration order in parent scope
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
    FConstants: TFPHashList;         // Constant name -> TConstantInfo
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
    function GetScopeLocals(RIP: QWord): TVariableInfoArray;
    function FindFunctionByName(const Name: String;
      out FuncInfo: TFunctionInfo): Boolean;
    function FindConstant(const Name: String; out ConstInfo: TConstantInfo): Boolean;
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
  FConstants := TFPHashList.Create;
  FReader := nil;
  FStream := nil;
  FLoaded := False;
end;

destructor TOPDFReaderAdapter.Destroy;
begin
  ClearCache;
  FTypes.Free;
  FVariables.Free;
  FConstants.Free;
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
    // Free InterfaceInfo if it's an interface type
    if (TypeInfo.Category = tcInterface) and (TypeInfo.InterfaceInfo <> nil) then
      Dispose(TypeInfo.InterfaceInfo);
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

  // Free cached constant info
  for I := 0 to FConstants.Count - 1 do
    Dispose(PConstantInfo(FConstants[I]));
  FConstants.Clear;

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

function FormatConstantValue(ConstKind: Byte; const ValueBytes: TBytes): String;
var
  IVal: Int64;
  DVal: Double;
  B: Byte;
  I: Integer;
  InStr: Boolean;
begin
  case ConstKind of
    Ord(ckOrd):
      begin
        if Length(ValueBytes) >= 8 then
          IVal := PInt64(@ValueBytes[0])^
        else
          IVal := 0;
        Result := IntToStr(IVal);
      end;

    Ord(ckString):
      begin
        Result := '';
        InStr := False;
        for I := 0 to Length(ValueBytes) - 1 do
        begin
          B := ValueBytes[I];
          if (B >= 32) and (B <= 126) and (B <> Ord('''')) then
          begin
            if not InStr then
            begin
              Result := Result + '''';
              InStr := True;
            end;
            Result := Result + Chr(B);
          end
          else if B = Ord('''') then
          begin
            if not InStr then
            begin
              Result := Result + '''';
              InStr := True;
            end;
            Result := Result + '''''';
          end
          else
          begin
            if InStr then
            begin
              Result := Result + '''';
              InStr := False;
            end;
            Result := Result + '#$' + IntToHex(B, 2);
          end;
        end;
        if InStr then
          Result := Result + '''';
        if Result = '' then
          Result := '''''';
      end;

    Ord(ckReal):
      begin
        if Length(ValueBytes) >= 8 then
          DVal := PDouble(@ValueBytes[0])^
        else
          DVal := 0;
        Result := FloatToStr(DVal);
      end;

    Ord(ckNil):
      Result := 'nil';

    Ord(ckWideStr):
      begin
        { Display as UTF-16LE hex pairs }
        Result := '';
        InStr := False;
        I := 0;
        while I + 1 < Length(ValueBytes) do
        begin
          B := ValueBytes[I] or (ValueBytes[I + 1] shl 8);
          if InStr then
          begin
            Result := Result + '''';
            InStr := False;
          end;
          Result := Result + '#$' + IntToHex(ValueBytes[I], 2);
          Result := Result + '#$' + IntToHex(ValueBytes[I + 1], 2);
          Inc(I, 2);
        end;
        if InStr then
          Result := Result + '''';
        if Result = '' then
          Result := '''''';
      end;
  else
    Result := '<unknown const kind>';
  end;
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
  DefSet: TDefSet;
  DefParameter: TDefParameter;
  DefInterface: TDefInterface;
  DefProperty: TDefProperty;
  DefConstant: TDefConstant;
  ConstBytes: TBytes;
  ConstName: String;
  PConst: PConstantInfo;
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
  ReadMethName: String;
  WriteMethName: String;
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
      if gVerbose then
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

//  if gVerbose then
  begin
    WriteLn('[INFO] OPDF version: ', FHeader.Version);
    WriteLn('[INFO] Target architecture: ', ArchToString(TTargetArch(FHeader.TargetArch)));
    WriteLn('[INFO] Pointer size: ', FHeader.PointerSize, ' bytes');
    WriteLn('[INFO] Total records: ', FHeader.TotalRecords);
  end;

  // Read all records and cache them.
  // The .opdf section contains one OPDF header per compilation unit (linker-concatenated).
  // When we encounter a header, skip it and continue reading records.
  while not FReader.AtEnd do
  begin
    { Check if we're at another OPDF header (next compilation unit) }
    if FReader.TryReadNextHeader then
    begin
      if gVerbose then
        WriteLn('[DEBUG] Skipped OPDF header at offset 0x', IntToHex(FStream.Position - SizeOf(TOPDFHeader), 1));
      Continue;
    end;

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
            { Deduplicate: skip if TypeID already loaded from an earlier unit }
            if FTypes.Find(IntToStr(DefPrimitive.TypeID)) = nil then
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
        end;

      recShortStr:
        begin
          if FReader.ReadShortString(DefShortString, TypeName) then
          begin
            if FTypes.Find(IntToStr(DefShortString.TypeID)) = nil then
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
        end;

      recAnsiStr:
        begin
          if FReader.ReadAnsiString(DefAnsiString, TypeName) then
          begin
            if FTypes.Find(IntToStr(DefAnsiString.TypeID)) = nil then
            begin
              New(PType);
              FillChar(PType^, SizeOf(TTypeInfo), 0);
              PType^.TypeID := DefAnsiString.TypeID;
              PType^.Name := TypeName;
              PType^.Size := FHeader.PointerSize;
              PType^.IsSigned := False;
              PType^.Category := tcAnsiString;
              PType^.MaxLength := 0;

              FTypes.Add(IntToStr(DefAnsiString.TypeID), PType);
            end;
          end;
        end;

      recUnicodeStr:
        begin
          if FReader.ReadUnicodeString(DefUnicodeString, TypeName) then
          begin
            if FTypes.Find(IntToStr(DefUnicodeString.TypeID)) = nil then
            begin
              New(PType);
              FillChar(PType^, SizeOf(TTypeInfo), 0);
              PType^.TypeID := DefUnicodeString.TypeID;
              PType^.Name := TypeName;
              PType^.Size := FHeader.PointerSize;
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
            if FTypes.Find(IntToStr(DefClass.TypeID)) = nil then
            begin
              New(PType);
              FillChar(PType^, SizeOf(TTypeInfo), 0);
              PType^.TypeID := DefClass.TypeID;
              PType^.Name := TypeName;
              PType^.Size := FHeader.PointerSize;  // Classes are pointers
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
            PLocal^.DeclIndex := DefLocalVar.DeclIndex;

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
            PScope^.DeclIndex := DefFunctionScope.DeclIndex;

            FFunctionScopes.Add(PScope);
          end;
        end;

      recArray:
        begin
          if FReader.ReadArray(DefArray, TypeName) then
          begin
            if FTypes.Find(IntToStr(DefArray.TypeID)) = nil then
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
        end;

      recPointer:
        begin
          if FReader.ReadPointer(DefPointer, TypeName) then
          begin
            if FTypes.Find(IntToStr(DefPointer.TypeID)) = nil then
            begin
              New(PType);
              FillChar(PType^, SizeOf(TTypeInfo), 0);
              PType^.TypeID := DefPointer.TypeID;
              PType^.Name := TypeName;
              PType^.Size := FHeader.PointerSize;
              PType^.IsSigned := False;
              PType^.Category := tcPointer;
              PType^.MaxLength := 0;
              PType^.PointerTo := DefPointer.TargetTypeID;

              FTypes.Add(IntToStr(DefPointer.TypeID), PType);
            end;
          end;
        end;

      recRecord:
        begin
          if FReader.ReadRecord(DefRecord, TypeName, RecordFields, RecordFieldNames) then
          begin
            if FTypes.Find(IntToStr(DefRecord.TypeID)) = nil then
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
        end;

      recEnum:
        begin
          if FReader.ReadEnum(DefEnum, TypeName, EnumMembers, EnumMemberNames) then
          begin
            if FTypes.Find(IntToStr(DefEnum.TypeID)) = nil then
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
        end;

      recSet:
        begin
          if FReader.ReadSet(DefSet, TypeName) then
          begin
            if FTypes.Find(IntToStr(DefSet.TypeID)) = nil then
            begin
              New(PType);
              FillChar(PType^, SizeOf(TTypeInfo), 0);
              PType^.TypeID := DefSet.TypeID;
              PType^.Name := TypeName;
              PType^.Size := DefSet.SizeInBytes;
              PType^.IsSigned := False;
              PType^.Category := tcSet;
              PType^.ElementTypeID := DefSet.BaseTypeID;
              PType^.SetLowerBound := DefSet.LowerBound;

              FTypes.Add(IntToStr(DefSet.TypeID), PType);
            end;
          end;
        end;

      recProperty:
        begin
          if FReader.ReadProperty(DefProperty, VarName, ReadMethName, WriteMethName) then
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
                  ReadMethodName := ReadMethName;
                  WriteMethodName := WriteMethName;
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
            if FTypes.Find(IntToStr(DefInterface.TypeID)) = nil then
            begin
              New(PType);
              FillChar(PType^, SizeOf(TTypeInfo), 0);
              PType^.TypeID := DefInterface.TypeID;
              PType^.Name := TypeName;
              PType^.Size := FHeader.PointerSize;  // Interface is a pointer
              PType^.IsSigned := False;
              PType^.Category := tcInterface;
              PType^.MaxLength := 0;

              New(PType^.InterfaceInfo);
              PType^.InterfaceInfo^.ParentTypeID := DefInterface.ParentTypeID;
              PType^.InterfaceInfo^.IntfType := DefInterface.IntfType;
              SetLength(PType^.InterfaceInfo^.Methods, Length(IntfMethodNames));
              for I := 0 to High(IntfMethodNames) do
                PType^.InterfaceInfo^.Methods[I] := IntfMethodNames[I];

              FTypes.Add(IntToStr(DefInterface.TypeID), PType);
            end;
          end;
        end;

      recUnitDirectory:
        begin
          { unit directory is informational - skip via seek below }
          if gVerbose then
            WriteLn('[DEBUG] Skipping UnitDirectory record');
        end;

      recConstant:
        begin
          if FReader.ReadConstant(DefConstant, ConstBytes, ConstName) then
          begin
            New(PConst);
            PConst^.Name := ConstName;
            PConst^.TypeID := DefConstant.TypeID;
            PConst^.FormattedValue := FormatConstantValue(DefConstant.ConstKind, ConstBytes);
            FConstants.Add(LowerCase(ConstName), PConst);
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
          ' variable(s), ', FConstants.Count, ' constant(s), ',
          FFunctionScopes.Count, ' function scope(s), and ',
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

  if gVerbose then
    WriteLn('[DEBUG] Variable not found: ', Name);
end;

{ Find variable with scope awareness - checks local variables first, then globals }
function TOPDFReaderAdapter.FindVariableWithScope(const Name: String; RIP: QWord;
                                                  out VarInfo: TVariableInfo): Boolean;
var
  ScopeID: Cardinal;
  Locals: TLocalVariableArray;
  I, J: Integer;
  LocalVar: TLocalVariableInfo;
  SearchName: String;
  DemangledName: String;
  FuncScope: PFunctionScope;
  CurDeclIndex: Word;
begin
  Result := False;

  if not FLoaded then
  begin
    WriteLn('[ERROR] OPDF file not loaded');
    Exit;
  end;

  SearchName := LowerCase(Name);

  { Try to find in local variables first (current scope) }
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
        if gVerbose then
          WriteLn('[DEBUG] Found local var: ', LocalVar.Name, ' LocationExpr=', LocalVar.LocationExpr,
                  ' LocationData=', LocalVar.LocationData);
        Exit;
      end;
    end;

    { Not found in current scope — search enclosing scopes (for nested procedures).
      When a nested procedure accesses a variable from an outer procedure, the variable
      is located in the outer frame. We use LocationExpr=2 to signal that the address
      must be computed via the saved RBP chain: parent_RBP = *(current_RBP).
      Only include variables declared before this nested procedure (DeclIndex filter). }
    CurDeclIndex := 0;
    for I := 0 to FFunctionScopes.Count - 1 do
    begin
      FuncScope := PFunctionScope(FFunctionScopes[I]);
      if FuncScope^.ScopeID = ScopeID then
      begin
        CurDeclIndex := FuncScope^.DeclIndex;
        Break;
      end;
    end;

    if CurDeclIndex > 0 then
      for I := 0 to FFunctionScopes.Count - 1 do
      begin
        FuncScope := PFunctionScope(FFunctionScopes[I]);
        if FuncScope^.ScopeID = ScopeID then
          Continue; { Skip current scope — already searched }

        Locals := FindLocalVariablesInScope(FuncScope^.ScopeID);
        for J := 0 to High(Locals) do
        begin
          LocalVar := Locals[J];
          if (LowerCase(LocalVar.Name) = SearchName) and
             (LocalVar.DeclIndex < CurDeclIndex) then
          begin
            VarInfo.Name := LocalVar.Name;
            VarInfo.TypeID := LocalVar.TypeID;
            VarInfo.Address := 0;
            VarInfo.LocationExpr := 2; { Parent frame RBP-relative }
            VarInfo.LocationData := LocalVar.LocationData;
            Result := True;
            if gVerbose then
              WriteLn('[DEBUG] Found enclosing scope var: ', LocalVar.Name,
                      ' in ', FuncScope^.Name, ' LocationData=', LocalVar.LocationData);
            Exit;
          end;
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

  if gVerbose then
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

{ Return all local variables in scope at the given RIP }
function TOPDFReaderAdapter.GetScopeLocals(RIP: QWord): TVariableInfoArray;
var
  ScopeID: Cardinal;
  Locals: TLocalVariableArray;
  FuncScope, CurScope: PFunctionScope;
  I, J, Count: Integer;
  CurDeclIndex: Word;
begin
  SetLength(Result, 0);

  if not FLoaded then
    Exit;

  ScopeID := GetCurrentFunctionScope(RIP);
  if ScopeID = 0 then
    Exit;

  { Find the current function scope's DeclIndex }
  CurScope := nil;
  for I := 0 to FFunctionScopes.Count - 1 do
  begin
    FuncScope := PFunctionScope(FFunctionScopes[I]);
    if FuncScope^.ScopeID = ScopeID then
    begin
      CurScope := FuncScope;
      Break;
    end;
  end;
  if CurScope = nil then
    Exit;
  CurDeclIndex := CurScope^.DeclIndex;

  { Add locals from current scope }
  Locals := FindLocalVariablesInScope(ScopeID);
  SetLength(Result, Length(Locals));
  for I := 0 to High(Locals) do
  begin
    Result[I].Name := Locals[I].Name;
    Result[I].TypeID := Locals[I].TypeID;
    Result[I].Address := 0;
    Result[I].LocationExpr := Locals[I].LocationExpr;
    Result[I].LocationData := Locals[I].LocationData;
  end;

  { Search enclosing scopes for variables declared before this nested procedure.
    Only include variables whose DeclIndex < the current function's DeclIndex,
    since Pascal scoping rules mean only variables declared before the nested
    procedure are visible to it. Variables declared after are not accessible.
    Skip if DeclIndex=0 (top-level procedure, no meaningful parent scope). }
  if CurDeclIndex > 0 then
    for I := 0 to FFunctionScopes.Count - 1 do
    begin
      FuncScope := PFunctionScope(FFunctionScopes[I]);
      if FuncScope^.ScopeID = ScopeID then
        Continue;

      { Heuristic: an ancestor's DeclIndex is larger than a child's.
        This filters out descendants and unrelated scopes. }
      if FuncScope^.DeclIndex > CurScope^.DeclIndex then
      begin
        Locals := FindLocalVariablesInScope(FuncScope^.ScopeID);
        if Length(Locals) > 0 then
        begin
          for J := 0 to High(Locals) do
          begin
            { Only include variables declared before this nested procedure }
            if Locals[J].DeclIndex < CurDeclIndex then
            begin
              Count := Length(Result);
              SetLength(Result, Count + 1);
              Result[Count].Name := Locals[J].Name;
              Result[Count].TypeID := Locals[J].TypeID;
              Result[Count].Address := 0;
              Result[Count].LocationExpr := 2; { Parent frame RBP-relative }
              Result[Count].LocationData := Locals[J].LocationData;
            end;
          end;
        end;
      end;
    end;
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
      { Strip FPC's leading '$' from internal names (e.g. '$main' -> 'main') }
      if (Length(FuncInfo.Name) > 1) and (FuncInfo.Name[1] = '$') then
        FuncInfo.Name := Copy(FuncInfo.Name, 2, Length(FuncInfo.Name) - 1);
      FuncInfo.LowPC := FuncScope^.LowPC;
      FuncInfo.HighPC := FuncScope^.HighPC;
      Result := True;
      Exit;
    end;
  end;
end;

{ Find function by name (case-insensitive) }
function TOPDFReaderAdapter.FindFunctionByName(const Name: String;
  out FuncInfo: TFunctionInfo): Boolean;
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

  for I := 0 to FFunctionScopes.Count - 1 do
  begin
    FuncScope := PFunctionScope(FFunctionScopes[I]);
    if CompareText(FuncScope^.Name, Name) = 0 then
    begin
      FuncInfo.Name := FuncScope^.Name;
      FuncInfo.LowPC := FuncScope^.LowPC;
      FuncInfo.HighPC := FuncScope^.HighPC;
      Result := True;
      if gVerbose then
        WriteLn('[DEBUG] FindFunctionByName: found ', Name, ' at $',
                IntToHex(FuncInfo.LowPC, 16));
      Exit;
    end;
  end;

  if gVerbose then
    WriteLn('[DEBUG] FindFunctionByName: not found: ', Name);
end;

function TOPDFReaderAdapter.FindConstant(const Name: String;
  out ConstInfo: TConstantInfo): Boolean;
var
  PConst: PConstantInfo;
  SearchName: String;
begin
  Result := False;

  if not FLoaded then
    Exit;

  SearchName := LowerCase(Name);
  PConst := PConstantInfo(FConstants.Find(SearchName));
  if Assigned(PConst) then
  begin
    ConstInfo := PConst^;
    Result := True;
    Exit;
  end;

  if gVerbose then
    WriteLn('[DEBUG] Constant not found: ', Name);
end;

end.
