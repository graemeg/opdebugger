{
  Object Pascal Debug Format - I/O Operations

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit provides reading and writing capabilities for OPDF format.
}
unit opdf_io;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, opdf_types;

type
  { Array dimension bounds - Int64 for future-proofing }
  TArrayBound = record
    LowerBound: Int64;
    UpperBound: Int64;
  end;

  TArrayBounds = array of TArrayBound;
  { OPDF Writer - Generates OPDF binary output }
  TOPDFWriter = class
  private
    FStream: TStream;
    FBuildID: TGUID;
    FTargetArch: TTargetArch;
    FPointerSize: Byte;
    FRecordCount: Cardinal;
    FHeaderWritten: Boolean;

    procedure WriteString(const S: String);
  public
    constructor Create(AStream: TStream; AArch: TTargetArch; APointerSize: Byte);
    destructor Destroy; override;

    { Write header to stream }
    procedure WriteHeader;

    { Write type definitions }
    procedure WritePrimitive(TypeID: TTypeID; const Name: String;
                            Size: Byte; IsSigned: Boolean);
    procedure WriteShortString(TypeID: TTypeID; const Name: String;
                              MaxLen: Byte);
    procedure WriteAnsiString(TypeID: TTypeID; const Name: String);
    procedure WriteUnicodeString(TypeID: TTypeID; const Name: String);
    procedure WritePointer(TypeID: TTypeID; TargetTypeID: TTypeID;
                          const Name: String);

    { Write symbol definitions }
    procedure WriteGlobalVar(const VarName: String; TypeID: TTypeID;
                           Address: QWord);
    procedure WriteLocalVar(const VarName: String; TypeID: TTypeID;
                          ScopeID: Cardinal; LocationExpr: Byte;
                          LocationData: ShortInt);

    { Write class definition }
    procedure WriteClass(TypeID: TTypeID; ParentTypeID: TTypeID;
                        const Name: String; VMTAddr: QWord;
                        InstSize: Cardinal; const Fields: array of TFieldDescriptor;
                        const FieldNames: array of String);

    { Write property definition }
    procedure WriteProperty(ClassTypeID: TTypeID; PropTypeID: TTypeID;
                           const Name: String; ReadType, WriteType: TPropertyAccessType;
                           ReadAddr, WriteAddr: QWord;
                           const ReadMethodName: String = '';
                           const WriteMethodName: String = '');

    { Write source line information }
    procedure WriteLineInfo(Address: QWord; const FileName: String;
                           LineNumber: Cardinal; ColumnNumber: Word = 0);

    { Write array type definition }
    procedure WriteArray(TypeID: TTypeID; ElementTypeID: TTypeID;
                        const Name: String; Dimensions: Byte;
                        IsDynamic: Boolean; const Bounds: TArrayBounds);

    { Write function scope information }
    procedure WriteFunctionScope(ScopeID: Cardinal; LowPC, HighPC: QWord;
                                const FunctionName: String);

    { Write record type definition }
    procedure WriteRecord(TypeID: TTypeID; const Name: String;
                         TotalSize: Cardinal;
                         const Fields: array of TFieldDescriptor;
                         const FieldNames: array of String);

    { Write enum type definition }
    procedure WriteEnum(TypeID: TTypeID; const Name: String;
                       SizeInBytes: Byte;
                       const Members: array of TEnumMember;
                       const MemberNames: array of String);

    { Write set type definition }
    procedure WriteSet(TypeID: TTypeID; BaseTypeID: TTypeID;
                      const Name: String; SizeInBytes: Byte; LowerBound: LongInt);

    { Write interface type definition }
    procedure WriteInterface(TypeID: TTypeID; ParentTypeID: TTypeID;
                            const Name: String; IntfType: TInterfaceType;
                            const GUID: TGUID; const Methods: array of TInterfaceMethodDescriptor;
                            const MethodNames: array of String);

    { Write parameter definition }
    procedure WriteParameter(const ParamName: String; TypeID: TTypeID;
                            IsVar, IsConst, IsOut: Boolean);

    { Finalize - update header with final record count }
    procedure Finalize;

    property BuildID: TGUID read FBuildID;
    property TargetArch: TTargetArch read FTargetArch;
    property RecordCount: Cardinal read FRecordCount;
  end;

  { OPDF Reader - Parses OPDF binary input }
  TOPDFReader = class
  private
    FStream: TStream;
    FHeader: TOPDFHeader;
    FHeaderRead: Boolean;
  public
    constructor Create(AStream: TStream);
    destructor Destroy; override;

    { Read and validate header }
    function ReadHeader: Boolean;

    { Read next record header }
    function ReadRecordHeader(out RecHeader: TOPDFRecordHeader): Boolean;

    { Read specific record types }
    function ReadPrimitive(out Def: TDefPrimitive; out Name: String): Boolean;
    function ReadGlobalVar(out Def: TDefGlobalVar; out Name: String): Boolean;
    function ReadLocalVar(out Def: TDefLocalVar; out LocationData: ShortInt; out Name: String): Boolean;
    function ReadShortString(out Def: TDefShortString; out Name: String): Boolean;
    function ReadAnsiString(out Def: TDefAnsiString; out Name: String): Boolean;
    function ReadUnicodeString(out Def: TDefUnicodeString; out Name: String): Boolean;
    function ReadPointer(out Def: TDefPointer; out Name: String): Boolean;
    function ReadArray(out Def: TDefArray; out Name: String): Boolean;
    function ReadLineInfo(out Def: TDefLineInfo; out FileName: String): Boolean;
    function ReadFunctionScope(out Def: TDefFunctionScope; out FunctionName: String): Boolean;
    function ReadClass(out Def: TDefClass; out Name: String; out Fields: TFieldDescriptorArray; out FieldNames: TStringArray): Boolean;
    function ReadProperty(out Def: TDefProperty; out Name: String;
                          out ReadMethodName, WriteMethodName: String): Boolean;
    function ReadRecord(out Def: TDefRecord; out Name: String;
                       out Fields: TFieldDescriptorArray; out FieldNames: TStringArray): Boolean;
    function ReadSet(out Def: TDefSet; out Name: String): Boolean;
    function ReadEnum(out Def: TDefEnum; out Name: String;
                     out Members: TEnumMemberArray; out MemberNames: TStringArray): Boolean;
    function ReadInterface(out Def: TDefInterface; out Name: String;
                          out Methods: TInterfaceMethodDescriptorArray;
                          out MethodNames: TStringArray): Boolean;
    function ReadParameter(out Def: TDefParameter; out Name: String): Boolean;

    { Skip current record (for unsupported types) }
    procedure SkipRecord(const RecHeader: TOPDFRecordHeader);

    { Check if at end of stream }
    function AtEnd: Boolean;

    property Header: TOPDFHeader read FHeader;
  end;

implementation

{ TOPDFWriter }

constructor TOPDFWriter.Create(AStream: TStream; AArch: TTargetArch; APointerSize: Byte);
begin
  inherited Create;
  FStream := AStream;
  FTargetArch := AArch;
  FPointerSize := APointerSize;
  FRecordCount := 0;
  FHeaderWritten := False;
  CreateGUID(FBuildID);
end;

destructor TOPDFWriter.Destroy;
begin
  inherited Destroy;
end;

procedure TOPDFWriter.WriteString(const S: String);
begin
  if Length(S) > 0 then
    FStream.Write(S[1], Length(S));
end;

procedure TOPDFWriter.WriteHeader;
var
  Header: TOPDFHeader;
begin
  if FHeaderWritten then
    raise Exception.Create('Header already written');

  Header.Magic := OPDF_MAGIC;
  Header.Version := OPDF_VERSION;
  Header.BuildID := FBuildID;
  Header.TargetArch := Ord(FTargetArch);
  Header.PointerSize := FPointerSize;
  Header.TotalRecords := 0;  // Will be updated in Finalize
  Header.Flags := 0;

  FStream.Write(Header, SizeOf(Header));
  FHeaderWritten := True;
end;

procedure TOPDFWriter.WritePrimitive(TypeID: TTypeID; const Name: String;
                                    Size: Byte; IsSigned: Boolean);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefPrimitive;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.SizeInBytes := Size;
  if IsSigned then
    Payload.IsSigned := 1
  else
    Payload.IsSigned := 0;
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recPrimitive);
  RecHeader.RecSize := SizeOf(TDefPrimitive) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteShortString(TypeID: TTypeID; const Name: String;
                                      MaxLen: Byte);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefShortString;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.MaxLength := MaxLen;
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recShortStr);
  RecHeader.RecSize := SizeOf(TDefShortString) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteAnsiString(TypeID: TTypeID; const Name: String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefAnsiString;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recAnsiStr);
  RecHeader.RecSize := SizeOf(TDefAnsiString) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteUnicodeString(TypeID: TTypeID; const Name: String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefUnicodeString;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recUnicodeStr);
  RecHeader.RecSize := SizeOf(TDefUnicodeString) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WritePointer(TypeID: TTypeID; TargetTypeID: TTypeID;
                                  const Name: String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefPointer;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.TargetTypeID := TargetTypeID;
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recPointer);
  RecHeader.RecSize := SizeOf(TDefPointer) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteArray(TypeID: TTypeID; ElementTypeID: TTypeID;
                                const Name: String; Dimensions: Byte;
                                IsDynamic: Boolean; const Bounds: TArrayBounds);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefArray;
  I: Integer;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.ElementTypeID := ElementTypeID;
  Payload.Dimensions := Dimensions;
  Payload.NameLen := Length(Name);

  if IsDynamic then
    Payload.IsDynamic := 1
  else
    Payload.IsDynamic := 0;

  RecHeader.RecType := Ord(recArray);
  RecHeader.RecSize := SizeOf(TDefArray) + Length(Name);

  { Add bounds information for static arrays }
  if not IsDynamic and (Length(Bounds) > 0) then
    RecHeader.RecSize := RecHeader.RecSize + (Length(Bounds) * SizeOf(TArrayBound));

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  { Write bounds for static arrays }
  if not IsDynamic and (Length(Bounds) > 0) then
  begin
    for I := 0 to High(Bounds) do
      FStream.Write(Bounds[I], SizeOf(TArrayBound));
  end;

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteGlobalVar(const VarName: String; TypeID: TTypeID;
                                   Address: QWord);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefGlobalVar;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.Address := Address;
  Payload.NameLen := Length(VarName);

  RecHeader.RecType := Ord(recGlobalVar);
  RecHeader.RecSize := SizeOf(TDefGlobalVar) + Length(VarName);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(VarName);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteLocalVar(const VarName: String; TypeID: TTypeID;
                                  ScopeID: Cardinal; LocationExpr: Byte;
                                  LocationData: ShortInt);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefLocalVar;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.ScopeID := ScopeID;
  Payload.LocationExpr := LocationExpr;
  Payload.NameLen := Length(VarName);

  RecHeader.RecType := Ord(recLocalVar);
  RecHeader.RecSize := SizeOf(TDefLocalVar) + SizeOf(ShortInt) + Length(VarName);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  FStream.Write(LocationData, SizeOf(ShortInt));
  WriteString(VarName);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteClass(TypeID: TTypeID; ParentTypeID: TTypeID;
                                const Name: String; VMTAddr: QWord;
                                InstSize: Cardinal; const Fields: array of TFieldDescriptor;
                                const FieldNames: array of String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefClass;
  I: Integer;
begin
  if Length(Fields) <> Length(FieldNames) then
    raise Exception.Create('WriteClass: Fields and FieldNames array lengths must match');

  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.ParentTypeID := ParentTypeID;
  Payload.VMTAddress := VMTAddr;
  Payload.InstanceSize := InstSize;
  Payload.FieldCount := Length(Fields);
  Payload.NameLen := Length(Name);

  // Calculate total record size
  RecHeader.RecType := Ord(recClass);
  RecHeader.RecSize := SizeOf(TDefClass) + Length(Name);
  for I := 0 to High(Fields) do
    RecHeader.RecSize := RecHeader.RecSize + SizeOf(TFieldDescriptor) + Length(FieldNames[I]);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  // Write field descriptors and their names
  for I := 0 to High(Fields) do
  begin
    // Make sure NameLen in descriptor matches the actual name length
    if Fields[I].NameLen <> Length(FieldNames[I]) then
      raise Exception.Create('WriteClass: Field name length mismatch');
      
    FStream.Write(Fields[I], SizeOf(TFieldDescriptor));
    WriteString(FieldNames[I]);
  end;

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteProperty(ClassTypeID: TTypeID; PropTypeID: TTypeID;
                                   const Name: String; ReadType, WriteType: TPropertyAccessType;
                                   ReadAddr, WriteAddr: QWord;
                                   const ReadMethodName: String = '';
                                   const WriteMethodName: String = '');
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefProperty;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.ClassTypeID := ClassTypeID;
  Payload.PropertyTypeID := PropTypeID;
  Payload.ReadType := Ord(ReadType);
  Payload.WriteType := Ord(WriteType);
  Payload.ReadAddr := ReadAddr;
  Payload.WriteAddr := WriteAddr;
  Payload.ReadMethodNameLen := Length(ReadMethodName);
  Payload.WriteMethodNameLen := Length(WriteMethodName);
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recProperty);
  RecHeader.RecSize := SizeOf(TDefProperty) + Length(ReadMethodName) +
                       Length(WriteMethodName) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(ReadMethodName);
  WriteString(WriteMethodName);
  WriteString(Name);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteLineInfo(Address: QWord; const FileName: String;
                                    LineNumber: Cardinal; ColumnNumber: Word = 0);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefLineInfo;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.Address := Address;
  Payload.LineNumber := LineNumber;
  Payload.ColumnNumber := ColumnNumber;
  Payload.FileNameLen := Length(FileName);

  RecHeader.RecType := Ord(recLineInfo);
  RecHeader.RecSize := SizeOf(TDefLineInfo) + Length(FileName);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(FileName);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteFunctionScope(ScopeID: Cardinal; LowPC, HighPC: QWord;
                                        const FunctionName: String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefFunctionScope;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.ScopeID := ScopeID;
  Payload.LowPC := LowPC;
  Payload.HighPC := HighPC;
  Payload.NameLen := Length(FunctionName);

  RecHeader.RecType := Ord(recFunctionScope);
  RecHeader.RecSize := SizeOf(TDefFunctionScope) + Length(FunctionName);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(FunctionName);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteRecord(TypeID: TTypeID; const Name: String;
                                  TotalSize: Cardinal;
                                  const Fields: array of TFieldDescriptor;
                                  const FieldNames: array of String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefRecord;
  I: Integer;
begin
  if Length(Fields) <> Length(FieldNames) then
    raise Exception.Create('WriteRecord: Fields and FieldNames array lengths must match');

  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.FieldCount := Length(Fields);
  Payload.TotalSize := TotalSize;
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recRecord);
  RecHeader.RecSize := SizeOf(TDefRecord) + Length(Name);
  for I := 0 to High(Fields) do
    RecHeader.RecSize := RecHeader.RecSize + SizeOf(TFieldDescriptor) + Length(FieldNames[I]);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  for I := 0 to High(Fields) do
  begin
    FStream.Write(Fields[I], SizeOf(TFieldDescriptor));
    WriteString(FieldNames[I]);
  end;

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteEnum(TypeID: TTypeID; const Name: String;
                                SizeInBytes: Byte;
                                const Members: array of TEnumMember;
                                const MemberNames: array of String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefEnum;
  I: Integer;
begin
  if Length(Members) <> Length(MemberNames) then
    raise Exception.Create('WriteEnum: Members and MemberNames array lengths must match');

  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.SizeInBytes := SizeInBytes;
  Payload.MemberCount := Length(Members);
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recEnum);
  RecHeader.RecSize := SizeOf(TDefEnum) + Length(Name);
  for I := 0 to High(Members) do
    RecHeader.RecSize := RecHeader.RecSize + SizeOf(TEnumMember) + Length(MemberNames[I]);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  for I := 0 to High(Members) do
  begin
    FStream.Write(Members[I], SizeOf(TEnumMember));
    WriteString(MemberNames[I]);
  end;

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteSet(TypeID: TTypeID; BaseTypeID: TTypeID;
                              const Name: String; SizeInBytes: Byte; LowerBound: LongInt);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefSet;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.BaseTypeID := BaseTypeID;
  Payload.SizeInBytes := SizeInBytes;
  Payload.LowerBound := LowerBound;
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recSet);
  RecHeader.RecSize := SizeOf(TDefSet) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteInterface(TypeID: TTypeID; ParentTypeID: TTypeID;
                                    const Name: String; IntfType: TInterfaceType;
                                    const GUID: TGUID;
                                    const Methods: array of TInterfaceMethodDescriptor;
                                    const MethodNames: array of String);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefInterface;
  I: Integer;
begin
  if Length(Methods) <> Length(MethodNames) then
    raise Exception.Create('WriteInterface: Methods and MethodNames array lengths must match');

  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  Payload.ParentTypeID := ParentTypeID;
  Payload.IntfType := Ord(IntfType);
  Payload.GUID := GUID;
  Payload.MethodCount := Length(Methods);
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recInterface);
  RecHeader.RecSize := SizeOf(TDefInterface) + Length(Name);
  for I := 0 to High(Methods) do
    RecHeader.RecSize := RecHeader.RecSize + SizeOf(TInterfaceMethodDescriptor) + Length(MethodNames[I]);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  for I := 0 to High(Methods) do
  begin
    FStream.Write(Methods[I], SizeOf(TInterfaceMethodDescriptor));
    WriteString(MethodNames[I]);
  end;

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteParameter(const ParamName: String; TypeID: TTypeID;
                                    IsVar, IsConst, IsOut: Boolean);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefParameter;
begin
  if not FHeaderWritten then
    WriteHeader;

  Payload.TypeID := TypeID;
  if IsVar then Payload.IsVar := 1 else Payload.IsVar := 0;
  if IsConst then Payload.IsConst := 1 else Payload.IsConst := 0;
  if IsOut then Payload.IsOut := 1 else Payload.IsOut := 0;
  Payload.NameLen := Length(ParamName);

  RecHeader.RecType := Ord(recParameter);
  RecHeader.RecSize := SizeOf(TDefParameter) + Length(ParamName);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(ParamName);

  Inc(FRecordCount);
end;

procedure TOPDFWriter.Finalize;
var
  Header: TOPDFHeader;
begin
  if not FHeaderWritten then
    raise Exception.Create('Cannot finalize: header not written');

  // Update header with final record count
  FStream.Position := 0;
  FStream.Read(Header, SizeOf(Header));
  Header.TotalRecords := FRecordCount;
  FStream.Position := 0;
  FStream.Write(Header, SizeOf(Header));
  FStream.Position := FStream.Size;
end;

{ TOPDFReader }

constructor TOPDFReader.Create(AStream: TStream);
begin
  inherited Create;
  FStream := AStream;
  FHeaderRead := False;
end;

destructor TOPDFReader.Destroy;
begin
  inherited Destroy;
end;

function TOPDFReader.ReadHeader: Boolean;
begin
  Result := False;
  if FHeaderRead then
    Exit(True);

  if FStream.Size < SizeOf(TOPDFHeader) then
    Exit;

  FStream.Position := 0;
  FStream.Read(FHeader, SizeOf(FHeader));

  Result := IsValidOPDFHeader(FHeader);
  FHeaderRead := Result;
end;

function TOPDFReader.ReadRecordHeader(out RecHeader: TOPDFRecordHeader): Boolean;
begin
  Result := False;
  if not FHeaderRead then
    if not ReadHeader then
      Exit;

  if FStream.Position + SizeOf(TOPDFRecordHeader) > FStream.Size then
    Exit;

  FStream.Read(RecHeader, SizeOf(RecHeader));
  Result := True;
end;

function TOPDFReader.ReadPrimitive(out Def: TDefPrimitive; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefPrimitive) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadGlobalVar(out Def: TDefGlobalVar; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefGlobalVar) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadLocalVar(out Def: TDefLocalVar; out LocationData: ShortInt; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefLocalVar) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + SizeOf(ShortInt) > FStream.Size then
    Exit;

  FStream.Read(LocationData, SizeOf(ShortInt));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadShortString(out Def: TDefShortString; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefShortString) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadAnsiString(out Def: TDefAnsiString; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefAnsiString) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadUnicodeString(out Def: TDefUnicodeString; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefUnicodeString) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadPointer(out Def: TDefPointer; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefPointer) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadArray(out Def: TDefArray; out Name: String): Boolean;
begin
  Result := False;
  SetLength(Name, 0);

  if FStream.Position + SizeOf(TDefArray) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadLineInfo(out Def: TDefLineInfo; out FileName: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefLineInfo) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.FileNameLen > FStream.Size then
    Exit;

  SetLength(FileName, Def.FileNameLen);
  if Def.FileNameLen > 0 then
    FStream.Read(FileName[1], Def.FileNameLen);

  Result := True;
end;

function TOPDFReader.ReadFunctionScope(out Def: TDefFunctionScope; out FunctionName: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefFunctionScope) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(FunctionName, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(FunctionName[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadClass(out Def: TDefClass; out Name: String; out Fields: TFieldDescriptorArray; out FieldNames: TStringArray): Boolean;
var
  I: Longint;
  FieldDef: TFieldDescriptor;
  FieldName: String;
begin
  Result := False;
  SetLength(Fields, 0); // Initialize Fields to empty array
  SetLength(FieldNames, 0); // Initialize FieldNames to empty array

  if FStream.Position + SizeOf(TDefClass) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  // Read field descriptors and names
  if Def.FieldCount > 10000 then
    Exit;
  SetLength(Fields, Def.FieldCount);
  SetLength(FieldNames, Def.FieldCount);
  for I := 0 to Def.FieldCount - 1 do
  begin
    if FStream.Position + SizeOf(TFieldDescriptor) > FStream.Size then
      Exit; // Incomplete record

    FStream.Read(FieldDef, SizeOf(TFieldDescriptor));

    if FStream.Position + FieldDef.NameLen > FStream.Size then
      Exit; // Incomplete field descriptor

    SetLength(FieldName, FieldDef.NameLen);
    if FieldDef.NameLen > 0 then
      FStream.Read(FieldName[1], FieldDef.NameLen);

    Fields[I] := FieldDef;
    FieldNames[I] := FieldName;  // Store the field name
  end;

  Result := True;
end;

function TOPDFReader.ReadProperty(out Def: TDefProperty; out Name: String;
                                  out ReadMethodName, WriteMethodName: String): Boolean;
begin
  Result := False;
  ReadMethodName := '';
  WriteMethodName := '';

  if FStream.Position + SizeOf(TDefProperty) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.ReadMethodNameLen + Def.WriteMethodNameLen +
     Def.NameLen > FStream.Size then
    Exit;

  SetLength(ReadMethodName, Def.ReadMethodNameLen);
  if Def.ReadMethodNameLen > 0 then
    FStream.Read(ReadMethodName[1], Def.ReadMethodNameLen);

  SetLength(WriteMethodName, Def.WriteMethodNameLen);
  if Def.WriteMethodNameLen > 0 then
    FStream.Read(WriteMethodName[1], Def.WriteMethodNameLen);

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadRecord(out Def: TDefRecord; out Name: String;
                               out Fields: TFieldDescriptorArray; out FieldNames: TStringArray): Boolean;
var
  I: Longint;
  FieldDef: TFieldDescriptor;
  FieldName: String;
begin
  Result := False;
  SetLength(Fields, 0);
  SetLength(FieldNames, 0);

  if FStream.Position + SizeOf(TDefRecord) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  { Sanity check field count }
  if Def.FieldCount > 10000 then
    Exit;

  SetLength(Fields, Def.FieldCount);
  SetLength(FieldNames, Def.FieldCount);
  for I := 0 to Def.FieldCount - 1 do
  begin
    if FStream.Position + SizeOf(TFieldDescriptor) > FStream.Size then
      Exit;

    FStream.Read(FieldDef, SizeOf(TFieldDescriptor));

    if FStream.Position + FieldDef.NameLen > FStream.Size then
      Exit;

    SetLength(FieldName, FieldDef.NameLen);
    if FieldDef.NameLen > 0 then
      FStream.Read(FieldName[1], FieldDef.NameLen);

    Fields[I] := FieldDef;
    FieldNames[I] := FieldName;
  end;

  Result := True;
end;

function TOPDFReader.ReadSet(out Def: TDefSet; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefSet) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

function TOPDFReader.ReadEnum(out Def: TDefEnum; out Name: String;
                             out Members: TEnumMemberArray; out MemberNames: TStringArray): Boolean;
var
  I: Longint;
  Member: TEnumMember;
  MemberName: String;
begin
  Result := False;
  SetLength(Members, 0);
  SetLength(MemberNames, 0);

  if FStream.Position + SizeOf(TDefEnum) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  SetLength(Members, Def.MemberCount);
  SetLength(MemberNames, Def.MemberCount);
  for I := 0 to Def.MemberCount - 1 do
  begin
    if FStream.Position + SizeOf(TEnumMember) > FStream.Size then
      Exit;

    FStream.Read(Member, SizeOf(TEnumMember));

    if FStream.Position + Member.NameLen > FStream.Size then
      Exit;

    SetLength(MemberName, Member.NameLen);
    if Member.NameLen > 0 then
      FStream.Read(MemberName[1], Member.NameLen);

    Members[I] := Member;
    MemberNames[I] := MemberName;
  end;

  Result := True;
end;

function TOPDFReader.ReadInterface(out Def: TDefInterface; out Name: String;
                                  out Methods: TInterfaceMethodDescriptorArray;
                                  out MethodNames: TStringArray): Boolean;
var
  I: Longint;
  MtdDef: TInterfaceMethodDescriptor;
  MtdName: String;
begin
  Result := False;
  SetLength(Methods, 0);
  SetLength(MethodNames, 0);

  if FStream.Position + SizeOf(TDefInterface) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  SetLength(Methods, Def.MethodCount);
  SetLength(MethodNames, Def.MethodCount);
  for I := 0 to Def.MethodCount - 1 do
  begin
    if FStream.Position + SizeOf(TInterfaceMethodDescriptor) > FStream.Size then
      Exit;

    FStream.Read(MtdDef, SizeOf(TInterfaceMethodDescriptor));

    if FStream.Position + MtdDef.NameLen > FStream.Size then
      Exit;

    SetLength(MtdName, MtdDef.NameLen);
    if MtdDef.NameLen > 0 then
      FStream.Read(MtdName[1], MtdDef.NameLen);

    Methods[I] := MtdDef;
    MethodNames[I] := MtdName;
  end;

  Result := True;
end;

function TOPDFReader.ReadParameter(out Def: TDefParameter; out Name: String): Boolean;
begin
  Result := False;

  if FStream.Position + SizeOf(TDefParameter) > FStream.Size then
    Exit;

  FStream.Read(Def, SizeOf(Def));

  if FStream.Position + Def.NameLen > FStream.Size then
    Exit;

  SetLength(Name, Def.NameLen);
  if Def.NameLen > 0 then
    FStream.Read(Name[1], Def.NameLen);

  Result := True;
end;

procedure TOPDFReader.SkipRecord(const RecHeader: TOPDFRecordHeader);
begin
  FStream.Position := FStream.Position + RecHeader.RecSize;
end;

function TOPDFReader.AtEnd: Boolean;
begin
  Result := FStream.Position >= FStream.Size;
end;

end.
