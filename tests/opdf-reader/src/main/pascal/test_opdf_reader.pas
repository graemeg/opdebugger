{
  OPDF Reader Unit Tests

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Builds OPDF headers in memory and checks that TOPDFReader accepts the
  format version it reads, and that it reports a header of another
  version by name (both the first header and a later unit's header)
  instead of misreading the records that follow.
}
program test_opdf_reader;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, opdf_types, opdf_io;

var
  Passed: Integer = 0;
  Failed: Integer = 0;

procedure Check(const AName: String; ACondition: Boolean; const ADetail: String = '');
begin
  if ACondition then
  begin
    Inc(Passed);
    WriteLn('  PASS  ', AName);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FAIL  ', AName);
    if ADetail <> '' then
      WriteLn('        ', ADetail);
  end;
end;

procedure WriteHeader(AStream: TStream; AVersion: Word; const AMagic: String = OPDF_MAGIC);
var
  H: TOPDFHeader;
begin
  FillChar(H, SizeOf(H), 0);
  Move(AMagic[1], H.Magic[0], 4);
  H.Version := AVersion;
  H.TargetArch := Ord(archX86_64);
  H.PointerSize := 8;
  AStream.WriteBuffer(H, SizeOf(H));
end;

procedure WritePadding(AStream: TStream; ACount: Integer);
var
  Zero: Byte;
  I: Integer;
begin
  Zero := 0;
  for I := 1 to ACount do
    AStream.WriteBuffer(Zero, 1);
end;

function NewReader(AStream: TMemoryStream): TOPDFReader;
begin
  AStream.Position := 0;
  Result := TOPDFReader.Create(AStream);
end;

procedure TestCurrentVersionIsAccepted;
var
  S: TMemoryStream;
  R: TOPDFReader;
begin
  S := TMemoryStream.Create;
  try
    WriteHeader(S, OPDF_VERSION);
    R := NewReader(S);
    try
      Check('current version: header accepted', R.ReadHeader);
      Check('current version: no error', R.Error = '', R.Error);
    finally
      R.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TestOlderVersionIsReported;
var
  S: TMemoryStream;
  R: TOPDFReader;
begin
  S := TMemoryStream.Create;
  try
    WriteHeader(S, OPDF_VERSION - 1);
    R := NewReader(S);
    try
      Check('older version: header refused', not R.ReadHeader);
      Check('older version: names both versions',
        (Pos('version ' + IntToStr(OPDF_VERSION - 1), R.Error) > 0) and
        (Pos('version ' + IntToStr(OPDF_VERSION), R.Error) > 0), R.Error);
      Check('older version: says to rebuild the program',
        Pos('rebuild the program', R.Error) > 0, R.Error);
    finally
      R.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TestNewerVersionIsReported;
var
  S: TMemoryStream;
  R: TOPDFReader;
begin
  S := TMemoryStream.Create;
  try
    WriteHeader(S, OPDF_VERSION + 1);
    R := NewReader(S);
    try
      Check('newer version: header refused', not R.ReadHeader);
      Check('newer version: names both versions',
        (Pos('version ' + IntToStr(OPDF_VERSION + 1), R.Error) > 0) and
        (Pos('version ' + IntToStr(OPDF_VERSION), R.Error) > 0), R.Error);
      Check('newer version: says to update pdr',
        Pos('update pdr', R.Error) > 0, R.Error);
    finally
      R.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TestNotOPDF;
var
  S: TMemoryStream;
  R: TOPDFReader;
begin
  S := TMemoryStream.Create;
  try
    WriteHeader(S, OPDF_VERSION, 'XXXX');
    R := NewReader(S);
    try
      Check('bad magic: header refused', not R.ReadHeader);
      Check('bad magic: reported as not OPDF',
        Pos('not OPDF', R.Error) > 0, R.Error);
    finally
      R.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TestNextUnitHeader;
var
  S: TMemoryStream;
  R: TOPDFReader;
begin
  { Two units, the second after linker padding, both current. }
  S := TMemoryStream.Create;
  try
    WriteHeader(S, OPDF_VERSION);
    WritePadding(S, 8);
    WriteHeader(S, OPDF_VERSION);
    R := NewReader(S);
    try
      R.ReadHeader;
      Check('next unit, current version: found', R.TryReadNextHeader);
      Check('next unit, current version: no error', R.Error = '', R.Error);
    finally
      R.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TestNextUnitHeaderOfAnotherVersion;
var
  S: TMemoryStream;
  R: TOPDFReader;
begin
  { A unit compiled by another compiler, linked into the same program. }
  S := TMemoryStream.Create;
  try
    WriteHeader(S, OPDF_VERSION);
    WritePadding(S, 8);
    WriteHeader(S, OPDF_VERSION - 1);
    R := NewReader(S);
    try
      R.ReadHeader;
      Check('next unit, older version: not taken as a header', not R.TryReadNextHeader);
      Check('next unit, older version: reported',
        Pos('version ' + IntToStr(OPDF_VERSION - 1), R.Error) > 0, R.Error);
    finally
      R.Free;
    end;
  finally
    S.Free;
  end;
end;

begin
  WriteLn('OPDF reader tests (format version ', OPDF_VERSION, ')');
  TestCurrentVersionIsAccepted;
  TestOlderVersionIsReported;
  TestNewerVersionIsReported;
  TestNotOPDF;
  TestNextUnitHeader;
  TestNextUnitHeaderOfAnotherVersion;
  WriteLn;
  WriteLn('Passed: ', Passed, '  Failed: ', Failed);
  if Failed > 0 then
    Halt(1);
end.
