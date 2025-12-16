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

  TLineEntry = record
    Address: QWord;
    FileName: String;
    LineNumber: Cardinal;
    ColumnNumber: Word;
  end;

  TLineEntryArray = array of TLineEntry;

var
  BinaryPath: String;
  OPDFPath: String;
  Symbols: TSymbolArray;
  LineEntries: TLineEntryArray;

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

{ Extract DWARF line number information from binary }
function ExtractLineInfo(const BinaryPath: String; out LineEntries: TLineEntryArray): Boolean;
var
  OutputStr: String;
  Output: TStringList;
  Line: String;
  Parts: TStringArray;
  Entry: TLineEntry;
  I: Integer;
  AddrStr, FileLineStr: String;
  ColonPos: Integer;
  TempLineNum: LongInt;
begin
  Result := False;
  SetLength(LineEntries, 0);

  WriteLn('[INFO] Extracting DWARF line information using objdump...');

  // Use objdump --dwarf=decodedline to get line number table
  if not RunCommand('objdump', ['--dwarf=decodedline', BinaryPath], OutputStr) then
  begin
    WriteLn('[WARN] Failed to execute objdump for line info (may not have debug symbols)');
    Exit(True); // Not an error - binary may not have debug info
  end;

  Output := TStringList.Create;
  try
    Output.Text := OutputStr;

    for Line in Output do
    begin
      // objdump --dwarf=decodedline format varies, try to parse:
      // Format examples:
      //   "test.pas                22   0x401234"
      //   "test.pas:22 0x401234"
      //
      // Strategy: Look for lines with hex addresses (0x...)

      if Pos('0x', Line) = 0 then
        Continue;

      // Extract the hex address
      Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
      AddrStr := '';
      FileLineStr := '';

      for I := 0 to High(Parts) do
      begin
        if (Pos('0x', Parts[I]) = 1) then
        begin
          AddrStr := Parts[I];
          // File:line should be before the address
          if I > 0 then
            FileLineStr := Parts[I - 1];
          Break;
        end;
      end;

      if (AddrStr = '') or (FileLineStr = '') then
        Continue;

      // Try to parse FileLineStr (could be just a number if filename is earlier)
      // First check if it's a standalone number
      if TryStrToInt(FileLineStr, TempLineNum) then
      begin
        Entry.LineNumber := TempLineNum;
        // Line number without filename in same column, search backwards for filename
        for I := 0 to High(Parts) - 1 do
        begin
          // Look for .pas, .pp, .p files
          if (Pos('.pas', LowerCase(Parts[I])) > 0) or
             (Pos('.pp', LowerCase(Parts[I])) > 0) or
             (Pos('.p', LowerCase(Parts[I])) > 0) then
          begin
            Entry.FileName := Parts[I];
            Break;
          end;
        end;
      end
      else
      begin
        // Try parsing as filename:linenum format
        ColonPos := Pos(':', FileLineStr);
        if ColonPos > 0 then
        begin
          Entry.FileName := Copy(FileLineStr, 1, ColonPos - 1);
          if not TryStrToInt(Copy(FileLineStr, ColonPos + 1, Length(FileLineStr)), TempLineNum) then
            Continue;
          Entry.LineNumber := TempLineNum;
        end
        else
          Continue; // Can't parse this line
      end;

      // Parse address
      try
        Entry.Address := StrToQWord(AddrStr);
      except
        Continue; // Invalid address
      end;

      // Default column to 0 (unknown)
      Entry.ColumnNumber := 0;

      // Only add entries with valid filename
      if Entry.FileName <> '' then
      begin
        SetLength(LineEntries, Length(LineEntries) + 1);
        LineEntries[High(LineEntries)] := Entry;
        WriteLn('[DEBUG] Line info: ', Entry.FileName, ':', Entry.LineNumber, ' -> 0x', IntToHex(Entry.Address, 8));
      end;
    end;

    WriteLn('[INFO] Found ', Length(LineEntries), ' line mapping(s)');
    Result := True;
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
function GenerateOPDF(const BinaryPath, OPDFPath: String; const Symbols: TSymbolArray;
                     const LineEntries: TLineEntryArray): Boolean;
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

    // Write line number information
    for I := 0 to High(LineEntries) do
    begin
      Writer.WriteLineInfo(
        LineEntries[I].Address,
        LineEntries[I].FileName,
        LineEntries[I].LineNumber,
        LineEntries[I].ColumnNumber
      );
      WriteLn('[DEBUG] Wrote line info: ', LineEntries[I].FileName, ':',
              LineEntries[I].LineNumber, ' -> 0x', IntToHex(LineEntries[I].Address, 8));
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

  // Extract line number information
  if not ExtractLineInfo(BinaryPath, LineEntries) then
  begin
    WriteLn('[ERROR] Failed to extract line information');
    Halt(1);
  end;

  // Generate OPDF
  if not GenerateOPDF(BinaryPath, OPDFPath, Symbols, LineEntries) then
  begin
    WriteLn('[ERROR] Failed to generate OPDF file');
    Halt(1);
  end;

  WriteLn;
  WriteLn('[SUCCESS] OPDF file generated: ', OPDFPath);
  Halt(0);
end.
