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
  end;

implementation

{ TOPDFReaderAdapter }

constructor TOPDFReaderAdapter.Create;
begin
  inherited Create;
  FTypes := TFPHashList.Create;
  FVariables := TFPHashList.Create;
  FReader := nil;
  FStream := nil;
  FLoaded := False;
end;

destructor TOPDFReaderAdapter.Destroy;
begin
  ClearCache;
  FTypes.Free;
  FVariables.Free;
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
  DefGlobalVar: TDefGlobalVar;
  TypeName: String;
  VarName: String;
  PType: PTypeInfo;
  PVar: PVariableInfo;
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

            FTypes.Add(IntToStr(DefPrimitive.TypeID), PType);

            WriteLn('[DEBUG] Loaded type: ', TypeName, ' (TypeID=', DefPrimitive.TypeID, ')');
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

      else
        // Skip unknown record types
        FReader.SkipRecord(RecHeader);
    end;
  end;

  WriteLn('[INFO] Loaded ', FTypes.Count, ' type(s) and ', FVariables.Count, ' variable(s)');

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

end.
