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
  Classes, SysUtils, Process, Math, ogopdf, opdf_io;

type
  TDwarfTypeKind = (dtkUnknown, dtkPrimitive, dtkShortString, dtkAnsiString);

  TDwarfTypeInfo = record
    Name: String;
    Kind: TDwarfTypeKind;
    Size: Cardinal;        // For primitives and ShortStrings
    IsSigned: Boolean;     // For primitives
    MaxLength: Byte;       // For ShortStrings (derived from Size - 1)
  end;

  TSymbolInfo = record
    Name: String;
    Address: QWord;
    SymType: Char; // 'B' = BSS, 'D' = Data, 'T' = Text
    TypeInfo: TDwarfTypeInfo;
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

{ Forward declarations }
function ExtractTypeInfo(const BinaryPath, VarName: String): TDwarfTypeInfo; forward;

{ Extract symbols from binary using nm }
function ExtractSymbols(const BinaryPath: String; out Symbols: TSymbolArray): Boolean;
var
  OutputStr: String;
  Output: TStringList;
  Line: String;
  Parts: TStringArray;
  Symbol: TSymbolInfo;
  CleanName: String;
  I: Integer;
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

          // Skip FPC internal symbols to speed up processing
          if (Pos('FPC_', Symbol.Name) = 1) or
             (Pos('_FPC_', Symbol.Name) = 1) or
             (Pos('IID_$', Symbol.Name) = 1) or
             (Pos('VMT_$', Symbol.Name) = 1) or
             (Symbol.Name = '__bss_start') or
             (Symbol.Name = '_edata') or
             (Symbol.Name = '_end') or
             (Symbol.Name = '__heapsize') or
             (Symbol.Name = '__fpc_ident') or
             (Symbol.Name = '__fpc_valgrind') then
            Continue;

          // Extract type information from DWARF
          // FPC mangles names like U_$P$TEST_03_STRINGS_$$_MYSHORTSTRING
          // Extract the actual variable name
          CleanName := Symbol.Name;
          if Pos('U_$P$', CleanName) = 1 then
          begin
            // Find the last _$$_ pattern (double $)
            I := Pos('_$$_', CleanName);
            if I > 0 then
              CleanName := Copy(CleanName, I + 4, Length(CleanName));
          end;

          WriteLn('[DEBUG] Extracting type info for: ', CleanName);
          Symbol.TypeInfo := ExtractTypeInfo(BinaryPath, CleanName);

          SetLength(Symbols, Length(Symbols) + 1);
          Symbols[High(Symbols)] := Symbol;

          WriteLn('[DEBUG] Found symbol: ', Symbol.Name, ' at $', IntToHex(Symbol.Address, 16),
                  ' Type=', Symbol.TypeInfo.Name);
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

{ Extract type information for a variable from DWARF }
function ExtractTypeInfo(const BinaryPath, VarName: String): TDwarfTypeInfo;
var
  OutputStr: String;
  Output: TStringList;
  Line: String;
  I, J, K: Integer;
  InVariable: Boolean;
  TypeOffset: String;
  HexPart: String;
  InTypeStruct: Boolean;
  ByteSize: Integer;
  TempSize: LongInt;
begin
  // Initialize with unknown type
  Result.Name := '';
  Result.Kind := dtkUnknown;
  Result.Size := 0;
  Result.IsSigned := False;
  Result.MaxLength := 0;

  // Run objdump to get DWARF info
  if not RunCommand('objdump', ['--dwarf=info', BinaryPath], OutputStr) then
    Exit;

  Output := TStringList.Create;
  try
    Output.Text := OutputStr;
    InVariable := False;
    InTypeStruct := False;
    TypeOffset := '';

    // First pass: Find the variable and its type offset
    WriteLn('[DEBUG] Searching for variable ', VarName, ' in ', Output.Count, ' lines of DWARF info');
    for I := 0 to Output.Count - 1 do
    begin
      Line := Output[I];

      // Look for DW_TAG_variable with matching name
      if Pos('DW_TAG_variable', Line) > 0 then
      begin
        InVariable := True;
        TypeOffset := '';
        Continue;
      end;

      if InVariable then
      begin
        // Extract type offset first (comes after name)
        if Pos('DW_AT_type', Line) > 0 then
        begin
          // Format: "   <9e>   DW_AT_type        : <0x1d6>"
          if Pos('<0x', Line) > 0 then
          begin
            TypeOffset := Copy(Line, Pos('<0x', Line) + 1, Pos('>', Line, Pos('<0x', Line)) - Pos('<0x', Line) - 1);
            WriteLn('[DEBUG] Found type offset: ', TypeOffset);
            Break; // Found type offset, stop searching
          end;
        end;

        // Check if this is our variable
        if Pos('DW_AT_name', Line) > 0 then
        begin
          WriteLn('[DEBUG] Checking name line: ', Line);
          WriteLn('[DEBUG] Looking for: ', UpperCase(VarName));
          if Pos(UpperCase(VarName), UpperCase(Line)) > 0 then
          begin
            // Found our variable, now look for its type
            WriteLn('[DEBUG] Found variable ', VarName, ' in DWARF');
            Continue;
          end
          else
          begin
            // Different variable
            WriteLn('[DEBUG] Not a match, resetting InVariable');
            InVariable := False;
            Continue;
          end;
        end;
      end;
    end;

    if TypeOffset = '' then
      Exit; // Variable not found or no type info

    // Second pass: Find the type definition
    // TypeOffset is like "0x1d6", extract just the hex digits (skip "0x")
    HexPart := Copy(TypeOffset, 3, Length(TypeOffset) - 2); // Remove "0x"
    WriteLn('[DEBUG] TypeOffset=', TypeOffset, ' HexPart=', HexPart);
    WriteLn('[DEBUG] Second pass: looking for type at offset ', HexPart);
    for I := 0 to Output.Count - 1 do
    begin
      Line := Output[I];

      // Look for the type offset (format: " <1><1d6>:")
      if Pos('<' + HexPart + '>:', Line) > 0 then
      begin
        WriteLn('[DEBUG] Found type definition line: ', Line);
        // Check if it's a structure type (ShortString)
        if Pos('DW_TAG_structure_type', Line) > 0 then
        begin
          InTypeStruct := True;
          Continue;
        end;

        // Check if it's a typedef (might be AnsiString)
        if Pos('DW_TAG_typedef', Line) > 0 then
        begin
          // Look ahead for name
          if I + 1 < Output.Count then
          begin
            Line := Output[I + 1];
            if Pos('DW_AT_name', Line) > 0 then
            begin
              if Pos('ANSISTRING', UpperCase(Line)) > 0 then
              begin
                Result.Name := 'AnsiString';
                Result.Kind := dtkAnsiString;
                Result.Size := 8; // Pointer size
                Exit;
              end;
            end;
          end;
          Exit; // Not AnsiString, unknown typedef
        end;

        // Check for base types (primitives)
        if Pos('DW_TAG_base_type', Line) > 0 then
        begin
          // Look ahead for name and size
          for ByteSize := I + 1 to Min(I + 5, Output.Count - 1) do
          begin
            if Pos('DW_AT_byte_size', Output[ByteSize]) > 0 then
            begin
              // Extract size
              if TryStrToInt(Trim(Copy(Output[ByteSize],
                 Pos(':', Output[ByteSize]) + 1,
                 Length(Output[ByteSize]))), TempSize) then
              begin
                Result.Size := TempSize;
                Result.Kind := dtkPrimitive;
                // Check encoding for signed/unsigned
                for J := I + 1 to Min(I + 5, Output.Count - 1) do
                begin
                  if Pos('DW_AT_encoding', Output[J]) > 0 then
                  begin
                    Result.IsSigned := Pos('signed', Output[J]) > 0;
                    Break;
                  end;
                end;
                Exit;
              end;
            end;
          end;
        end;
      end;

      // If we found a structure, look for its name and size
      if InTypeStruct then
      begin
        if Pos('DW_AT_name', Line) > 0 then
        begin
          if Pos('ShortString', Line) > 0 then
          begin
            Result.Name := 'ShortString';
            Result.Kind := dtkShortString;
            // Look for byte_size
            for K := I to Min(I + 3, Output.Count - 1) do
            begin
              if Pos('DW_AT_byte_size', Output[K]) > 0 then
              begin
                // Extract size
                if TryStrToInt(Trim(Copy(Output[K],
                   Pos(':', Output[K]) + 1,
                   Length(Output[K]))), TempSize) then
                begin
                  Result.Size := TempSize;
                  Result.MaxLength := Result.Size - 1; // ShortString is length byte + data
                  Exit;
                end;
              end;
            end;
          end;
        end;
        InTypeStruct := False;
      end;
    end;
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

    // Define common types and write variables
    TypeIDCounter := 100;

    // LongInt type (fallback for unknown types)
    LongIntTypeID := TypeIDCounter;
    Inc(TypeIDCounter);
    Writer.WritePrimitive(LongIntTypeID, 'LongInt', 4, True);
    WriteLn('[DEBUG] Defined type: LongInt (TypeID=', LongIntTypeID, ')');

    // Boolean type (fallback)
    BoolTypeID := TypeIDCounter;
    Inc(TypeIDCounter);
    Writer.WritePrimitive(BoolTypeID, 'Boolean', 1, False);
    WriteLn('[DEBUG] Defined type: Boolean (TypeID=', BoolTypeID, ')');

    // Write global variables with their types
    for I := 0 to High(Symbols) do
    begin
      case Symbols[I].TypeInfo.Kind of
        dtkShortString:
        begin
          // Define ShortString type with specific max length
          Writer.WriteShortString(TypeIDCounter, Symbols[I].Name + '_Type', Symbols[I].TypeInfo.MaxLength);
          WriteLn('[DEBUG] Defined type: ShortString[', Symbols[I].TypeInfo.MaxLength, '] (TypeID=', TypeIDCounter, ')');

          // Write variable
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          WriteLn('[DEBUG] Wrote variable: ', Symbols[I].Name, ' (ShortString[', Symbols[I].TypeInfo.MaxLength, '])');
          Inc(TypeIDCounter);
        end;

        dtkAnsiString:
        begin
          // Define AnsiString type
          Writer.WriteAnsiString(TypeIDCounter, Symbols[I].Name + '_Type');
          WriteLn('[DEBUG] Defined type: AnsiString (TypeID=', TypeIDCounter, ')');

          // Write variable
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          WriteLn('[DEBUG] Wrote variable: ', Symbols[I].Name, ' (AnsiString)');
          Inc(TypeIDCounter);
        end;

        dtkPrimitive:
        begin
          // Define primitive type
          Writer.WritePrimitive(TypeIDCounter, Symbols[I].TypeInfo.Name,
                               Symbols[I].TypeInfo.Size, Symbols[I].TypeInfo.IsSigned);
          WriteLn('[DEBUG] Defined type: ', Symbols[I].TypeInfo.Name, ' (TypeID=', TypeIDCounter, ')');

          // Write variable
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          WriteLn('[DEBUG] Wrote variable: ', Symbols[I].Name, ' (', Symbols[I].TypeInfo.Name, ')');
          Inc(TypeIDCounter);
        end;

        dtkUnknown:
        begin
          // Fallback to heuristic
          if Pos('Bool', Symbols[I].Name) > 0 then
          begin
            Writer.WriteGlobalVar(Symbols[I].Name, BoolTypeID, Symbols[I].Address);
            WriteLn('[DEBUG] Wrote variable: ', Symbols[I].Name, ' (Boolean - fallback)');
          end
          else
          begin
            Writer.WriteGlobalVar(Symbols[I].Name, LongIntTypeID, Symbols[I].Address);
            WriteLn('[DEBUG] Wrote variable: ', Symbols[I].Name, ' (LongInt - fallback)');
          end;
        end;
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
