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
  Classes, SysUtils, ogopdf;

type
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

    { Write class definition }
    procedure WriteClass(TypeID: TTypeID; ParentTypeID: TTypeID;
                        const Name: String; VMTAddr: QWord;
                        InstSize: Cardinal; const Fields: array of TFieldDescriptor);

    { Write property definition }
    procedure WriteProperty(ClassTypeID: TTypeID; PropTypeID: TTypeID;
                           const Name: String; ReadType, WriteType: TPropertyAccessType;
                           ReadAddr, WriteAddr: QWord);

    { Write source line information }
    procedure WriteLineInfo(Address: QWord; const FileName: String;
                           LineNumber: Cardinal; ColumnNumber: Word = 0);

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
    function ReadShortString(out Def: TDefShortString; out Name: String): Boolean;
    function ReadAnsiString(out Def: TDefAnsiString; out Name: String): Boolean;
    function ReadUnicodeString(out Def: TDefUnicodeString; out Name: String): Boolean;
    function ReadPointer(out Def: TDefPointer; out Name: String): Boolean;
    function ReadLineInfo(out Def: TDefLineInfo; out FileName: String): Boolean;

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

procedure TOPDFWriter.WriteClass(TypeID: TTypeID; ParentTypeID: TTypeID;
                                const Name: String; VMTAddr: QWord;
                                InstSize: Cardinal; const Fields: array of TFieldDescriptor);
var
  RecHeader: TOPDFRecordHeader;
  Payload: TDefClass;
  I: Integer;
  FieldName: String;
begin
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
    RecHeader.RecSize := RecHeader.RecSize + SizeOf(TFieldDescriptor) + Fields[I].NameLen;

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
  WriteString(Name);

  // Write field descriptors
  for I := 0 to High(Fields) do
  begin
    FStream.Write(Fields[I], SizeOf(TFieldDescriptor));
    // Note: Field names are embedded in TFieldDescriptor.NameLen
    // This is simplified for now - proper implementation would store names separately
  end;

  Inc(FRecordCount);
end;

procedure TOPDFWriter.WriteProperty(ClassTypeID: TTypeID; PropTypeID: TTypeID;
                                   const Name: String; ReadType, WriteType: TPropertyAccessType;
                                   ReadAddr, WriteAddr: QWord);
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
  Payload.NameLen := Length(Name);

  RecHeader.RecType := Ord(recProperty);
  RecHeader.RecSize := SizeOf(TDefProperty) + Length(Name);

  FStream.Write(RecHeader, SizeOf(RecHeader));
  FStream.Write(Payload, SizeOf(Payload));
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

procedure TOPDFReader.SkipRecord(const RecHeader: TOPDFRecordHeader);
begin
  FStream.Position := FStream.Position + RecHeader.RecSize;
end;

function TOPDFReader.AtEnd: Boolean;
begin
  Result := FStream.Position >= FStream.Size;
end;

end.
