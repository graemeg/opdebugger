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
  TDwarfTypeKind = (dtkUnknown, dtkPrimitive, dtkShortString, dtkAnsiString, dtkUnicodeString, dtkWideString, dtkClass);

  TDwarfFieldInfo = record
    Name: String;
    Offset: Cardinal;
    TypeOffset: String; // DWARF offset for the field's type
  end;
  TDwarfFieldArray = array of TDwarfFieldInfo;

  TDwarfTypeInfo = record
    Name: String;
    Kind: TDwarfTypeKind;
    Size: Cardinal;        // For primitives, ShortStrings, and Class InstanceSize
    IsSigned: Boolean;     // For primitives
    MaxLength: Byte;       // For ShortStrings
    // New fields for classes:
    ParentTypeOffset: String; // DWARF offset of parent class type, if any
    Fields: TDwarfFieldArray; // Fields for classes
    DwarfOffset: String;      // DWARF offset of THIS type definition (e.g., "<0xf9>")
  end;

  TSymbolInfo = record
    Name: String;
    Address: QWord;
    SymType: Char; // 'B' = BSS, 'D' = Data, 'T' = Text
    TypeInfo: TDwarfTypeInfo;
    TypeOffset: String; // DWARF offset for this symbol's type (e.g., "<0xf9>")
  end;

  { Mapping of DWARF type offsets to assigned TypeIDs }
  TOffsetToTypeID = record
    DwarfOffset: String;  // e.g., "<0xb9a>"
    TypeID: TTypeID;      // e.g., 105
  end;
  TOffsetToTypeIDArray = array of TOffsetToTypeID;

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

{ Helper to extract an attribute's value from a specific DWARF entry starting at StartLineIndex }
function FindDwarfAttributeInEntry(const Output: TStringList; StartLineIndex: Integer;
                                  const AttributeName: String): String;
var
  Line: String;
  CurrentIndex: Integer;
  EntryIndent: Integer;
  LineIndent: Integer;
begin
  Result := '';
  CurrentIndex := StartLineIndex;

  if (CurrentIndex >= Output.Count) then
    Exit;

  // Determine the indentation level of the DWARF entry itself
  EntryIndent := 0;
  if Length(Output[CurrentIndex]) > 0 then
  begin
    while (EntryIndent < Length(Output[CurrentIndex])) and (Output[CurrentIndex][EntryIndent+1] = ' ') do
      Inc(EntryIndent);
  end;

  // Scan subsequent lines for attributes belonging to this entry
  Inc(CurrentIndex); // Start from the line after the entry tag
  while CurrentIndex < Output.Count do
  begin
    Line := Output[CurrentIndex];

    // Determine current line's indentation
    LineIndent := 0;
    if Length(Line) > 0 then
    begin
      while (LineIndent < Length(Line)) and (Line[LineIndent+1] = ' ') do
        Inc(LineIndent);
    end;

    // If the line is less indented than the entry itself, or it's another top-level entry, stop
    if (LineIndent <= EntryIndent) and (Trim(Line) <> '') then
      Break;

    // Look for the attribute
    if Pos('DW_AT_' + AttributeName, Line) > 0 then
    begin
      if Pos(':', Line) > 0 then
      begin
        Result := Trim(Copy(Line, Pos(':', Line) + 1, Length(Line)));
        Exit;
      end;
    end;
    Inc(CurrentIndex);
  end;
end;

// Helper function to get the indentation level of a line
function GetLineIndent(const Line: String): Integer;
var
  I: Integer;
begin
  Result := 0;
  if Length(Line) = 0 then Exit; // Handle empty lines
  for I := 1 to Length(Line) do
  begin
    if Line[I] = ' ' then
      Inc(Result)
    else
      Break;
  end;
end;

// Parse DWARF data_member_location attribute
// Format: "2 byte block: 23 c 	(DW_OP_plus_uconst: 12)"
// Returns the offset value (12 in the example above)
function ParseMemberLocation(const LocationStr: String): Cardinal;
var
  ParenPos: Integer;
  ColonPos: Integer;
  OffsetStr: String;
  TempOffset: Cardinal;
begin
  Result := 0;

  // Look for opening parenthesis with description
  ParenPos := Pos('(', LocationStr);
  if ParenPos = 0 then
  begin
    // Try to parse as plain number
    if TryStrToUInt(Trim(LocationStr), TempOffset) then
      Result := TempOffset;
    Exit;
  end;

  // Extract the description: (DW_OP_plus_uconst: 12)
  // Find the colon AFTER "DW_OP_plus_uconst"
  ColonPos := Pos('DW_OP_plus_uconst:', LocationStr);
  if ColonPos > 0 then
  begin
    // Move to the colon and then past it
    ColonPos := ColonPos + Length('DW_OP_plus_uconst:');
    // Extract the number after the colon
    OffsetStr := Trim(Copy(LocationStr, ColonPos, Length(LocationStr)));
    // Remove any trailing characters like parenthesis or tab
    if Pos(')', OffsetStr) > 0 then
      OffsetStr := Trim(Copy(OffsetStr, 1, Pos(')', OffsetStr) - 1));

    if TryStrToUInt(OffsetStr, TempOffset) then
      Result := TempOffset;
  end;
end;

{ Helper functions for offset-to-TypeID mapping }

// Add a mapping entry
procedure AddOffsetMapping(var OffsetMap: TOffsetToTypeIDArray; const DwarfOffset: String; TypeID: TTypeID);
var
  Index: Integer;
begin
  if DwarfOffset = '' then Exit;

  // Check if already in map
  for Index := 0 to High(OffsetMap) do
  begin
    if OffsetMap[Index].DwarfOffset = DwarfOffset then
      Exit; // Already mapped
  end;

  // Add new entry
  Index := Length(OffsetMap);
  SetLength(OffsetMap, Index + 1);
  OffsetMap[Index].DwarfOffset := DwarfOffset;
  OffsetMap[Index].TypeID := TypeID;
end;

// Look up TypeID by DWARF offset
function ResolveOffsetToTypeID(const OffsetMap: TOffsetToTypeIDArray; const DwarfOffset: String): TTypeID;
var
  I: Integer;
begin
  Result := 0; // Not found

  if DwarfOffset = '' then Exit;

  for I := 0 to High(OffsetMap) do
  begin
    if OffsetMap[I].DwarfOffset = DwarfOffset then
    begin
      Result := OffsetMap[I].TypeID;
      Exit;
    end;
  end;
end;

{ Forward declarations }
function ExtractTypeInfo(const BinaryPath, VarName: String): TDwarfTypeInfo; forward;
function ExtractTypeByOffset(const BinaryPath, DwarfOffset: String): TDwarfTypeInfo; forward;

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
      Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);

      if Length(Parts) >= 3 then
      begin
        if (Parts[1] = 'B') or (Parts[1] = 'D') or (Parts[1] = 'd') or (Parts[1] = 'b') then
        begin
          Symbol.Name := Parts[2];
          Symbol.Address := StrToQWord('$' + Parts[0]);
          Symbol.SymType := Parts[1][1];

          if (Pos('FPC_', Symbol.Name) = 1) or
             (Pos('_FPC_', Symbol.Name) = 1) or
             (Pos('IID_$', Symbol.Name) = 1) or
             (Pos('VMT_$', Symbol.Name) = 1) or
             (Symbol.Name = '__bss_start') or (Symbol.Name = '_edata') or (Symbol.Name = '_end') then
            Continue;

          CleanName := Symbol.Name;
          { Extract user variable name from mangled prefix }
          if (Pos('U_$P$', CleanName) = 1) or (Pos('TC_$P$', CleanName) = 1) then
          begin
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
    Result := True;
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

  if not RunCommand('objdump', ['--dwarf=decodedline', BinaryPath], OutputStr) then
  begin
    WriteLn('[WARN] Failed to execute objdump for line info (may not have debug symbols)');
    Exit(True);
  end;

  Output := TStringList.Create;
  try
    Output.Text := OutputStr;

    for Line in Output do
    begin
      if Pos('0x', Line) = 0 then Continue;

      Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
      AddrStr := '';
      FileLineStr := '';

      for I := 0 to High(Parts) do
      begin
        if (Pos('0x', Parts[I]) = 1) then
        begin
          AddrStr := Parts[I];
          if I > 0 then FileLineStr := Parts[I - 1];
          Break;
        end;
      end;

      if (AddrStr = '') or (FileLineStr = '') then Continue;

      if TryStrToInt(FileLineStr, TempLineNum) then
      begin
        Entry.LineNumber := TempLineNum;
        for I := 0 to High(Parts) - 1 do
        begin
          if (Pos('.pas', LowerCase(Parts[I])) > 0) or (Pos('.pp', LowerCase(Parts[I])) > 0) then
          begin
            Entry.FileName := Parts[I];
            Break;
          end;
        end;
      end
      else
      begin
        ColonPos := Pos(':', FileLineStr);
        if ColonPos > 0 then
        begin
          Entry.FileName := Copy(FileLineStr, 1, ColonPos - 1);
          if not TryStrToInt(Copy(FileLineStr, ColonPos + 1, Length(FileLineStr)), TempLineNum) then Continue;
          Entry.LineNumber := TempLineNum;
        end
        else Continue;
      end;

      try
        Entry.Address := StrToQWord(AddrStr);
      except
        Continue;
      end;

      Entry.ColumnNumber := 0;

      if Entry.FileName <> '' then
      begin
        SetLength(LineEntries, Length(LineEntries) + 1);
        LineEntries[High(LineEntries)] := Entry;
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
  I: Integer;
  InVariable: Boolean;
  TypeOffset: String;
  HexPart: String;
  TempSize: LongInt;
  TempSizeStr: String;
  CurrentMemberLineIndex, ClassEntryIndent, MemberLineIndent: Integer;
  MemberLine, LocStr: String;
  TempOffset: LongInt;
  NewField: TDwarfFieldInfo;
  CurrentOffset: String;
  FoundEntry: Boolean;
begin
  // Initialize
  Result.Name := '';
  Result.Kind := dtkUnknown;
  Result.Size := 0;
  Result.IsSigned := False;
  Result.MaxLength := 0;
  Result.ParentTypeOffset := '';
  Result.DwarfOffset := '';
  SetLength(Result.Fields, 0);

  if not RunCommand('objdump', ['--dwarf=info', BinaryPath], OutputStr) then Exit;

  Output := TStringList.Create;
  try
    Output.Text := OutputStr;
    InVariable := False;
    TypeOffset := '';

    // First pass: Find the variable and its type offset
    for I := 0 to Output.Count - 1 do
    begin
      Line := Output[I];
      if Pos('DW_TAG_variable', Line) > 0 then
      begin
        InVariable := True;
        TypeOffset := '';
        Continue;
      end;

      if InVariable then
      begin
        if Pos('DW_AT_name', Line) > 0 then
        begin
          if Pos(UpperCase(VarName), UpperCase(Line)) = 0 then
            InVariable := False
          else
            WriteLn('[DEBUG] Found variable ', VarName, ' in DWARF');
        end;

        if InVariable and (Pos('DW_AT_type', Line) > 0) then
        begin
          if Pos('<0x', Line) > 0 then
          begin
            TypeOffset := Copy(Line, Pos('<0x', Line), Pos('>', Line, Pos('<0x', Line)) - Pos('<0x', Line) + 1);
            WriteLn('[DEBUG] Found type offset: ', TypeOffset);
            Break;
          end;
        end;
      end;
    end;

    if TypeOffset = '' then Exit;

    // Second pass: Find the type definition by following typedefs
    CurrentOffset := TypeOffset;
    while CurrentOffset <> '' do
    begin
      FoundEntry := False;
      if (Length(CurrentOffset) < 4) or (Pos('<0x', CurrentOffset) <> 1) then
      begin
        CurrentOffset := '';
        Continue;
      end;

      HexPart := Copy(CurrentOffset, 4, Length(CurrentOffset) - 4);
      WriteLn('[DEBUG] Second pass: looking for type at offset ', HexPart);

      for I := 0 to Output.Count - 1 do
      begin
        Line := Output[I];

        if Pos('<' + HexPart + '>:', Line) > 0 then
        begin
          WriteLn('[DEBUG] Found type definition line: ', Line);
          FoundEntry := True;
          CurrentOffset := '';

          { Capture the DWARF offset of this type definition }
          Result.DwarfOffset := '<0x' + HexPart + '>';

          if Pos('DW_TAG_class_type', Line) > 0 then
          begin
            Result.Kind := dtkClass;
            Result.Name := FindDwarfAttributeInEntry(Output, I, 'name');
            Result.ParentTypeOffset := FindDwarfAttributeInEntry(Output, I, 'specification');
            if Result.ParentTypeOffset = '' then
              Result.ParentTypeOffset := FindDwarfAttributeInEntry(Output, I, 'inherits_from');

            TempSizeStr := FindDwarfAttributeInEntry(Output, I, 'byte_size');
            if TryStrToInt(TempSizeStr, TempSize) then Result.Size := TempSize else Result.Size := 0;

            WriteLn('[DEBUG] Detected Class: ', Result.Name, ' (Size=', Result.Size, ', ParentOffset=', Result.ParentTypeOffset, ')');

            CurrentMemberLineIndex := I + 1;
            ClassEntryIndent := GetLineIndent(Output[I]);
            SetLength(Result.Fields, 0);

            while CurrentMemberLineIndex < Output.Count do
            begin
              MemberLine := Output[CurrentMemberLineIndex];
              MemberLineIndent := GetLineIndent(MemberLine);

              // Stop if we hit a line with same indentation as class entry but it's not a child entry (< 2 >)
              // Child entries have " <2>" or " <3>" prefixes, while same-level entries have " <1>"
              if (MemberLineIndent <= ClassEntryIndent) and (Trim(MemberLine) <> '') then
              begin
                // Check if this is a child entry (depth > 1)
                if Pos(' <1>', MemberLine) > 0 then
                  Break;
              end;

              if Pos('DW_TAG_member', MemberLine) > 0 then
              begin
                NewField.Name := FindDwarfAttributeInEntry(Output, CurrentMemberLineIndex, 'name');
                NewField.TypeOffset := FindDwarfAttributeInEntry(Output, CurrentMemberLineIndex, 'type');
                LocStr := FindDwarfAttributeInEntry(Output, CurrentMemberLineIndex, 'data_member_location');
                NewField.Offset := ParseMemberLocation(LocStr);

                if NewField.Name <> '' then
                begin
                  SetLength(Result.Fields, Length(Result.Fields) + 1);
                  Result.Fields[High(Result.Fields)] := NewField;
                  WriteLn('[DEBUG]   Found Field: ', NewField.Name, ' (Offset=', NewField.Offset, ', TypeOffset=', NewField.TypeOffset, ')');
                end;
              end;
              Inc(CurrentMemberLineIndex);
            end;
            Break;
          end;

          if Pos('DW_TAG_typedef', Line) > 0 then
          begin
            { Check the name of the typedef - if it's a string type, identify it }
            Result.Name := FindDwarfAttributeInEntry(Output, I, 'name');
            if Pos('ANSISTRING', UpperCase(Result.Name)) > 0 then
            begin
              Result.Kind := dtkAnsiString;
              Result.Size := 8; { Pointer size }
              WriteLn('[DEBUG] Detected AnsiString typedef: ', Result.Name);
              Break;
            end
            else if Pos('STRING', UpperCase(Result.Name)) > 0 then
            begin
              Result.Kind := dtkUnicodeString;
              Result.Size := 8; { Pointer size }
              WriteLn('[DEBUG] Detected String/Unicode typedef: ', Result.Name);
              Break;
            end
            else if Pos('WIDESTRING', UpperCase(Result.Name)) > 0 then
            begin
              Result.Kind := dtkWideString;
              Result.Size := 8; { Pointer size }
              WriteLn('[DEBUG] Detected WideString typedef: ', Result.Name);
              Break;
            end;

            CurrentOffset := FindDwarfAttributeInEntry(Output, I, 'type');
            WriteLn('[DEBUG] Typedef found, resolving to new offset: ', CurrentOffset);
            Break;
          end;

          if Pos('DW_TAG_pointer_type', Line) > 0 then
          begin
            CurrentOffset := FindDwarfAttributeInEntry(Output, I, 'type');
            WriteLn('[DEBUG] Pointer type found, resolving to new offset: ', CurrentOffset);
            Break;
          end;

          if Pos('DW_TAG_base_type', Line) > 0 then
          begin
            TempSizeStr := FindDwarfAttributeInEntry(Output, I, 'byte_size');
            if TryStrToInt(TempSizeStr, TempSize) then
            begin
              Result.Size := TempSize;
              Result.Kind := dtkPrimitive;
              Result.IsSigned := Pos('signed', FindDwarfAttributeInEntry(Output, I, 'encoding')) > 0;
              Result.Name := FindDwarfAttributeInEntry(Output, I, 'name');
            end;
            Break;
          end;
          
          if Pos('DW_TAG_structure_type', Line) > 0 then
          begin
            if Pos('ShortString', FindDwarfAttributeInEntry(Output, I, 'name')) > 0 then
            begin
              Result.Name := 'ShortString';
              Result.Kind := dtkShortString;
              TempSizeStr := FindDwarfAttributeInEntry(Output, I, 'byte_size');
              if TryStrToInt(TempSizeStr, TempSize) then
              begin
                Result.Size := TempSize;
                Result.MaxLength := Result.Size - 1;
              end;
            end;
            Break;
          end;
          
          Break;
        end;
      end;

      if not FoundEntry then CurrentOffset := '';
    end;
  finally
    Output.Free;
  end;
end;

{ Extract type information directly by DWARF offset }
function ExtractTypeByOffset(const BinaryPath, DwarfOffset: String): TDwarfTypeInfo;
var
  OutputStr: String;
  Output: TStringList;
  Line: String;
  I: Integer;
  HexPart: String;
  TempSize: LongInt;
  TempSizeStr: String;
  FoundEntry: Boolean;
  CurrentOffset: String;
begin
  // Initialize result
  Result.Name := '';
  Result.Kind := dtkUnknown;
  Result.Size := 0;
  Result.IsSigned := False;
  Result.MaxLength := 0;
  Result.ParentTypeOffset := '';
  Result.DwarfOffset := '';
  SetLength(Result.Fields, 0);

  if DwarfOffset = '' then Exit;

  if not RunCommand('objdump', ['--dwarf=info', BinaryPath], OutputStr) then Exit;

  Output := TStringList.Create;
  try
    Output.Text := OutputStr;

    { Extract just the hex part from DwarfOffset (e.g., "0xb9a" from "<0xb9a>" or "b9a" from "<b9a>") }
    HexPart := Copy(DwarfOffset, 2, Length(DwarfOffset) - 2);
    WriteLn('[DEBUG] Looking up type by offset: ', HexPart);

    { Find the type definition at this offset }
    { The DWARF output shows offsets as <b9a> (without 0x) or <0xb9a> (with 0x) }
    for I := 0 to Output.Count - 1 do
    begin
      Line := Output[I];

      { Try both formats: <0xb9a> and <b9a> }
      if (Pos('<' + HexPart + '>:', Line) > 0) or (Pos('<' + Copy(HexPart, 3, Length(HexPart)) + '>:', Line) > 0) then
      begin
        WriteLn('[DEBUG] Found type at offset ', HexPart, ': ', Line);
        Result.DwarfOffset := DwarfOffset;

        if Pos('DW_TAG_base_type', Line) > 0 then
        begin
          TempSizeStr := FindDwarfAttributeInEntry(Output, I, 'byte_size');
          if TryStrToInt(TempSizeStr, TempSize) then
          begin
            Result.Size := TempSize;
            Result.Kind := dtkPrimitive;
            Result.IsSigned := Pos('signed', FindDwarfAttributeInEntry(Output, I, 'encoding')) > 0;
            Result.Name := FindDwarfAttributeInEntry(Output, I, 'name');
            WriteLn('[DEBUG] Extracted primitive type: ', Result.Name, ' (Size=', Result.Size, ')');
          end;
          Break;
        end;

        if Pos('DW_TAG_typedef', Line) > 0 then
        begin
          { Check the name of the typedef - if it's a string type, identify it }
          Result.Name := FindDwarfAttributeInEntry(Output, I, 'name');
          if Pos('ANSISTRING', UpperCase(Result.Name)) > 0 then
          begin
            Result.Kind := dtkAnsiString;
            Result.Size := 8; { Pointer size }
            WriteLn('[DEBUG] Detected AnsiString typedef: ', Result.Name);
            Break;
          end
          else if Pos('STRING', UpperCase(Result.Name)) > 0 then
          begin
            Result.Kind := dtkUnicodeString;
            Result.Size := 8; { Pointer size }
            WriteLn('[DEBUG] Detected String typedef: ', Result.Name);
            Break;
          end;

          { Follow the typedef }
          CurrentOffset := FindDwarfAttributeInEntry(Output, I, 'type');
          WriteLn('[DEBUG] Typedef found, resolving to: ', CurrentOffset);
          { Recursively extract the target type }
          Result := ExtractTypeByOffset(BinaryPath, CurrentOffset);
          Break;
        end;

        if Pos('DW_TAG_pointer_type', Line) > 0 then
        begin
          { Follow the pointer }
          CurrentOffset := FindDwarfAttributeInEntry(Output, I, 'type');
          WriteLn('[DEBUG] Pointer type found, resolving to: ', CurrentOffset);
          Result := ExtractTypeByOffset(BinaryPath, CurrentOffset);
          Break;
        end;

        if Pos('DW_TAG_structure_type', Line) > 0 then
        begin
          { Check if it's a string type }
          if Pos('AnsiString', FindDwarfAttributeInEntry(Output, I, 'name')) > 0 then
          begin
            Result.Name := 'AnsiString';
            Result.Kind := dtkAnsiString;
            Result.Size := 8; { Pointer size }
            WriteLn('[DEBUG] Extracted AnsiString type');
          end;
          Break;
        end;

        Break;
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
  if not RunCommand('file', [BinaryPath], OutputStr) then Exit;
  Output := TStringList.Create;
  try
    Output.Text := OutputStr;
    for Line in Output do
    begin
      if Pos('x86-64', Line) > 0 then Exit(archX86_64);
      if Pos('80386', Line) > 0 then Exit(archI386);
      if Pos('Intel 80386', Line) > 0 then Exit(archI386);
      if Pos('ARM', Line) > 0 then
      begin
        if Pos('aarch64', Line) > 0 then Exit(archAArch64) else Exit(archARM);
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
  I, J: Integer;
  TypeIDCounter: TTypeID;
  LongIntTypeID: TTypeID;
  BoolTypeID: TTypeID;
  OpdfFields: array of TFieldDescriptor;
  FieldNames: array of String;
  OffsetMap: TOffsetToTypeIDArray;
begin
  Result := False;
  SetLength(OffsetMap, 0);

  Arch := DetectArchitecture(BinaryPath);
  if Arch = archUnknown then
  begin
    WriteLn('[ERROR] Could not detect binary architecture');
    Exit;
  end;
  WriteLn('[INFO] Detected architecture: ', ArchToString(Arch));

  case Arch of
    archI386, archARM, archPowerPC: PointerSize := 4;
    archX86_64, archAArch64, archPowerPC64: PointerSize := 8;
  else
    PointerSize := 8;
  end;

  FileStream := TFileStream.Create(OPDFPath, fmCreate);
  Writer := TOPDFWriter.Create(FileStream, Arch, PointerSize);
  try
    WriteLn('[INFO] Generating OPDF file: ', OPDFPath);
    TypeIDCounter := 100;

    LongIntTypeID := TypeIDCounter;
    Inc(TypeIDCounter);
    Writer.WritePrimitive(LongIntTypeID, 'LongInt', 4, True);

    BoolTypeID := TypeIDCounter;
    Inc(TypeIDCounter);
    Writer.WritePrimitive(BoolTypeID, 'Boolean', 1, False);

    { Extract field types for all classes and add them to the offset map }
    for I := 0 to High(Symbols) do
    begin
      if Symbols[I].TypeInfo.Kind = dtkClass then
      begin
        for J := 0 to High(Symbols[I].TypeInfo.Fields) do
        begin
          { For each field, extract its type from DWARF if not already in map }
          if (Symbols[I].TypeInfo.Fields[J].TypeOffset <> '') and
             (ResolveOffsetToTypeID(OffsetMap, Symbols[I].TypeInfo.Fields[J].TypeOffset) = 0) then
          begin
            { Extract the field type from DWARF }
            WriteLn('[DEBUG] Extracting field type for: ', Symbols[I].TypeInfo.Fields[J].Name,
                    ' (offset=', Symbols[I].TypeInfo.Fields[J].TypeOffset, ')');

            { Extract type by its DWARF offset }
            with ExtractTypeByOffset(BinaryPath, Symbols[I].TypeInfo.Fields[J].TypeOffset) do
            begin
              if Kind <> dtkUnknown then
              begin
                { Add a type definition for this field type }
                AddOffsetMapping(OffsetMap, Symbols[I].TypeInfo.Fields[J].TypeOffset, TypeIDCounter);

                { Write the type to OPDF }
                case Kind of
                  dtkPrimitive:
                    Writer.WritePrimitive(TypeIDCounter, Name, Size, IsSigned);
                  dtkAnsiString:
                    Writer.WriteAnsiString(TypeIDCounter, Name);
                  dtkUnicodeString, dtkWideString:
                    Writer.WriteUnicodeString(TypeIDCounter, Name);
                else
                  { Skip other types for now }
                end;

                WriteLn('[DEBUG]   Added TypeID ', TypeIDCounter, ' for field type: ', Name);
                Inc(TypeIDCounter);
              end;
            end;
          end;
        end;
      end;
    end;

    for I := 0 to High(Symbols) do
    begin
      { Add mapping from DWARF offset to assigned TypeID }
      AddOffsetMapping(OffsetMap, Symbols[I].TypeInfo.DwarfOffset, TypeIDCounter);

      case Symbols[I].TypeInfo.Kind of
        dtkShortString:
        begin
          Writer.WriteShortString(TypeIDCounter, Symbols[I].Name + '_Type', Symbols[I].TypeInfo.MaxLength);
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          Inc(TypeIDCounter);
        end;
        dtkAnsiString:
        begin
          Writer.WriteAnsiString(TypeIDCounter, Symbols[I].Name + '_Type');
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          Inc(TypeIDCounter);
        end;
        dtkUnicodeString, dtkWideString:
        begin
          Writer.WriteUnicodeString(TypeIDCounter, Symbols[I].Name + '_Type');
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          Inc(TypeIDCounter);
        end;
        dtkPrimitive:
        begin
          Writer.WritePrimitive(TypeIDCounter, Symbols[I].TypeInfo.Name,
                               Symbols[I].TypeInfo.Size, Symbols[I].TypeInfo.IsSigned);
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          Inc(TypeIDCounter);
        end;
        dtkClass:
        begin
          SetLength(OpdfFields, Length(Symbols[I].TypeInfo.Fields));
          SetLength(FieldNames, Length(Symbols[I].TypeInfo.Fields));
          for J := 0 to High(Symbols[I].TypeInfo.Fields) do
          begin
            FieldNames[J] := Symbols[I].TypeInfo.Fields[J].Name;
            { Resolve field type ID from DWARF offset }
            OpdfFields[J].FieldTypeID := ResolveOffsetToTypeID(OffsetMap, Symbols[I].TypeInfo.Fields[J].TypeOffset);
            OpdfFields[J].Offset := Symbols[I].TypeInfo.Fields[J].Offset;
            OpdfFields[J].NameLen := Length(FieldNames[J]);
          end;

          Writer.WriteClass(
            TypeIDCounter,
            ResolveOffsetToTypeID(OffsetMap, Symbols[I].TypeInfo.ParentTypeOffset), { Resolved ParentTypeID }
            Symbols[I].TypeInfo.Name,
            0, // Placeholder for VMTAddress
            Symbols[I].TypeInfo.Size,
            OpdfFields,
            FieldNames
          );
          Writer.WriteGlobalVar(Symbols[I].Name, TypeIDCounter, Symbols[I].Address);
          Inc(TypeIDCounter);
        end;
        dtkUnknown:
        begin
          if Pos('Bool', Symbols[I].Name) > 0 then
            Writer.WriteGlobalVar(Symbols[I].Name, BoolTypeID, Symbols[I].Address)
          else
            Writer.WriteGlobalVar(Symbols[I].Name, LongIntTypeID, Symbols[I].Address);
        end;
      end;
    end;

    for I := 0 to High(LineEntries) do
    begin
      Writer.WriteLineInfo(
        LineEntries[I].Address,
        LineEntries[I].FileName,
        LineEntries[I].LineNumber,
        LineEntries[I].ColumnNumber
      );
    end;

    Writer.Finalize;
    WriteLn('[INFO] OPDF generation complete');
    Result := True;
  finally
    Writer.Free;
    FileStream.Free;
  end;
end;

{ Main program }
begin
  WriteLn('OPDF Generator v0.1.0');
  if ParamCount < 1 then
  begin
    WriteLn('Usage: opdf_generator <binary_path>');
    Halt(1);
  end;

  BinaryPath := ParamStr(1);
  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Halt(1);
  end;

  OPDFPath := ChangeFileExt(BinaryPath, '.opdf');

  if not ExtractSymbols(BinaryPath, Symbols) then Halt(1);
  if not ExtractLineInfo(BinaryPath, LineEntries) then Halt(1);
  if not GenerateOPDF(BinaryPath, OPDFPath, Symbols, LineEntries) then Halt(1);

  WriteLn;
  WriteLn('[SUCCESS] OPDF file generated: ', OPDFPath);
  Halt(0);
end.