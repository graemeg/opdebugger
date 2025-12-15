program opdf_generator;

{
  OPDF Generator - Standalone tool for generating OPDF debug files

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This tool extracts symbol information from compiled binaries using 'nm'
  and generates external .opdf debug information files.

  Usage: opdf_generator <binary_path>
}

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Process, ogopdf, opdf_io;

type
  TSymbolInfo = record
    Name: String;
    Address: QWord;
    SymType: Char; // 'B' = BSS, 'D' = Data, 'T' = Text
  end;

  TSymbolArray = array of TSymbolInfo;

var
  BinaryPath: String;
  OPDFPath: String;
  Symbols: TSymbolArray;

{ Extract symbols from binary using nm }
function ExtractSymbols(const BinaryPath: String; out Symbols: TSymbolArray): Boolean;
var
  OutputStr: String;
  Output: TStringList;
  Line: String;
  Parts: TStringArray;
  Symbol: TSymbolInfo;
begin
  Result := False;
  SetLength(Symbols, 0);

  WriteLn('[INFO] Extracting symbols from binary using nm...');

  // Use RunCommand for simplicity
  if not RunCommand('nm', [BinaryPath], OutputStr) then
  begin
    WriteLn('[ERROR] Failed to execute nm command');
    Exit(False);
  end;

  Output := TStringList.Create;
  try
    Output.Text := OutputStr;

    for Line in Output do
    begin
      // nm output format: address type name
      // e.g., "00000000004a1234 B MyGlobalInt"
      Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);

      if Length(Parts) >= 3 then
      begin
        // Filter for data/BSS symbols (global variables)
        if (Parts[1] = 'B') or (Parts[1] = 'D') or (Parts[1] = 'd') or (Parts[1] = 'b') then
        begin
          Symbol.Name := Parts[2];
          Symbol.Address := StrToQWord('$' + Parts[0]);
          Symbol.SymType := Parts[1][1];

          SetLength(Symbols, Length(Symbols) + 1);
          Symbols[High(Symbols)] := Symbol;

          WriteLn('[DEBUG] Found symbol: ', Symbol.Name, ' at $', IntToHex(Symbol.Address, 16));
        end;
      end;
    end;

    WriteLn('[INFO] Found ', Length(Symbols), ' global variable(s)');
    Result := True; // Success even if no symbols found
  finally
    Output.Free;
  end;
end;

{ Determine architecture from binary }
function DetectArchitecture(const BinaryPath: String): TTargetArch;
var
  OutputStr: String;
  Output: TStringList;
  Line: String;
begin
  Result := archUnknown;

  if not RunCommand('file', [BinaryPath], OutputStr) then
    Exit;

  Output := TStringList.Create;
  try
    Output.Text := OutputStr;

    for Line in Output do
    begin
      if Pos('x86-64', Line) > 0 then
        Exit(archX86_64);
      if Pos('80386', Line) > 0 then
        Exit(archI386);
      if Pos('Intel 80386', Line) > 0 then
        Exit(archI386);
      if Pos('ARM', Line) > 0 then
      begin
        if Pos('aarch64', Line) > 0 then
          Exit(archAArch64)
        else
          Exit(archARM);
      end;
    end;
  finally
    Output.Free;
  end;
end;

{ Generate OPDF file }
function GenerateOPDF(const BinaryPath, OPDFPath: String; const Symbols: TSymbolArray): Boolean;
var
  FileStream: TFileStream;
  Writer: TOPDFWriter;
  Arch: TTargetArch;
  PointerSize: Byte;
  I: Integer;
  TypeIDCounter: TTypeID;
  LongIntTypeID: TTypeID;
  BoolTypeID: TTypeID;
begin
  Result := False;

  // Detect architecture
  Arch := DetectArchitecture(BinaryPath);
  if Arch = archUnknown then
  begin
    WriteLn('[ERROR] Could not detect binary architecture');
    Exit;
  end;

  WriteLn('[INFO] Detected architecture: ', ArchToString(Arch));

  // Determine pointer size
  case Arch of
    archI386, archARM, archPowerPC:
      PointerSize := 4;
    archX86_64, archAArch64, archPowerPC64:
      PointerSize := 8;
  else
    PointerSize := 8; // Default to 64-bit
  end;

  // Create OPDF file
  FileStream := TFileStream.Create(OPDFPath, fmCreate);
  Writer := TOPDFWriter.Create(FileStream, Arch, PointerSize);
  try
    WriteLn('[INFO] Generating OPDF file: ', OPDFPath);

    // Write header (done automatically on first write)

    // Define common types
    TypeIDCounter := 100;

    // LongInt type
    LongIntTypeID := TypeIDCounter;
    Inc(TypeIDCounter);
    Writer.WritePrimitive(LongIntTypeID, 'LongInt', 4, True);
    WriteLn('[DEBUG] Defined type: LongInt (TypeID=', LongIntTypeID, ')');

    // Boolean type
    BoolTypeID := TypeIDCounter;
    Inc(TypeIDCounter);
    Writer.WritePrimitive(BoolTypeID, 'Boolean', 1, False);
    WriteLn('[DEBUG] Defined type: Boolean (TypeID=', BoolTypeID, ')');

    // Write global variables
    for I := 0 to High(Symbols) do
    begin
      // Simple heuristic: assume Integer for now
      // TODO: Parse debug symbols or use naming conventions
      if Pos('Bool', Symbols[I].Name) > 0 then
      begin
        Writer.WriteGlobalVar(Symbols[I].Name, BoolTypeID, Symbols[I].Address);
        WriteLn('[DEBUG] Wrote variable: ', Symbols[I].Name, ' (Boolean)');
      end
      else
      begin
        Writer.WriteGlobalVar(Symbols[I].Name, LongIntTypeID, Symbols[I].Address);
        WriteLn('[DEBUG] Wrote variable: ', Symbols[I].Name, ' (LongInt)');
      end;
    end;

    // Finalize (updates header with record count)
    Writer.Finalize;

    WriteLn('[INFO] OPDF generation complete');
    WriteLn('[INFO] BuildID: ', GUIDToString(Writer.BuildID));
    WriteLn('[INFO] Total records: ', Writer.RecordCount);

    Result := True;
  finally
    Writer.Free;
    FileStream.Free;
  end;
end;

{ Main program }
begin
  WriteLn('OPDF Generator v0.1.0');
  WriteLn('Copyright (c) 2025 Graeme Geldenhuys');
  WriteLn;

  // Parse command line
  if ParamCount < 1 then
  begin
    WriteLn('Usage: opdf_generator <binary_path>');
    WriteLn;
    WriteLn('Generates an external .opdf debug information file for the given binary.');
    WriteLn('The OPDF file will be created with the same basename as the binary.');
    Halt(1);
  end;

  BinaryPath := ParamStr(1);

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Halt(1);
  end;

  OPDFPath := ChangeFileExt(BinaryPath, '.opdf');

  // Extract symbols
  if not ExtractSymbols(BinaryPath, Symbols) then
  begin
    WriteLn('[ERROR] Failed to extract symbols from binary');
    Halt(1);
  end;

  // Generate OPDF
  if not GenerateOPDF(BinaryPath, OPDFPath, Symbols) then
  begin
    WriteLn('[ERROR] Failed to generate OPDF file');
    Halt(1);
  end;

  WriteLn;
  WriteLn('[SUCCESS] OPDF file generated: ', OPDFPath);
  Halt(0);
end.
