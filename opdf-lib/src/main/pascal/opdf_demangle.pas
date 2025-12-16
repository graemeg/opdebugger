{
  OPDF Symbol Demangling

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit provides symbol demangling for FPC (Free Pascal Compiler) symbols.
}
unit opdf_demangle;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { Symbol demangler for FPC-style name mangling }
  TFPCDemangler = class
  public
    { Demangle an FPC symbol name }
    class function Demangle(const MangledName: String): String;

    { Check if a name is FPC-mangled }
    class function IsMangledName(const Name: String): Boolean;

    { Extract just the variable/symbol name from mangled name }
    class function ExtractSymbolName(const MangledName: String): String;

    { Convert FPC uppercase identifier to mixed case }
    class function ToMixedCase(const UpperName: String): String;
  end;

implementation

{ TFPCDemangler }

class function TFPCDemangler.IsMangledName(const Name: String): Boolean;
begin
  // FPC mangled names typically start with patterns like:
  // U_$P$ - unit global variables
  // U_$ - unit symbols
  // VMT_$ - virtual method tables
  // INIT_$ - initialization records
  // IID_$ - interface IDs
  // RTTI_$ - RTTI information
  Result := (Pos('U_$P$', Name) = 1) or
            (Pos('U_$', Name) = 1) or
            (Pos('VMT_$', Name) = 1) or
            (Pos('INIT_$', Name) = 1) or
            (Pos('IID_$', Name) = 1) or
            (Pos('IIDSTR_$', Name) = 1) or
            (Pos('RTTI_$', Name) = 1);
end;

class function TFPCDemangler.ExtractSymbolName(const MangledName: String): String;
var
  Pos1, Pos2: Integer;
begin
  Result := MangledName;

  // Pattern: U_$P$MODULENAME_$$_SYMBOLNAME
  // We want to extract SYMBOLNAME

  // Find the _$$_ separator
  Pos1 := Pos('_$$_', MangledName);
  if Pos1 > 0 then
  begin
    // Extract everything after _$$_
    Result := Copy(MangledName, Pos1 + 4, Length(MangledName));

    // Check for $indirect suffix and remove it
    if (Length(Result) > 9) and (Copy(Result, Length(Result) - 8, 9) = '$indirect') then
      Result := Copy(Result, 1, Length(Result) - 9);

    Exit;
  end;

  // Pattern: U_$SYMBOLNAME (simpler form)
  if Pos('U_$', MangledName) = 1 then
  begin
    Result := Copy(MangledName, 4, Length(MangledName));
    Exit;
  end;

  // For other patterns (VMT_$, INIT_$, etc.), just remove the prefix
  if Pos('VMT_$', MangledName) = 1 then
  begin
    Result := Copy(MangledName, 6, Length(MangledName));
    Exit;
  end;

  if Pos('INIT_$', MangledName) = 1 then
  begin
    Result := Copy(MangledName, 7, Length(MangledName));
    Exit;
  end;

  if Pos('IIDSTR_$', MangledName) = 1 then
  begin
    Result := Copy(MangledName, 9, Length(MangledName));
    Exit;
  end;

  if Pos('IID_$', MangledName) = 1 then
  begin
    Result := Copy(MangledName, 6, Length(MangledName));
    Exit;
  end;

  if Pos('RTTI_$', MangledName) = 1 then
  begin
    Result := Copy(MangledName, 7, Length(MangledName));
    Exit;
  end;
end;

class function TFPCDemangler.ToMixedCase(const UpperName: String): String;
var
  I: Integer;
  NextUpper: Boolean;
begin
  if UpperName = '' then
    Exit('');

  Result := LowerCase(UpperName);

  // First character is uppercase
  if Length(Result) > 0 then
    Result[1] := UpCase(Result[1]);

  // Convert to PascalCase (uppercase after underscores)
  NextUpper := False;
  for I := 1 to Length(Result) do
  begin
    if Result[I] = '_' then
      NextUpper := True
    else if NextUpper then
    begin
      Result[I] := UpCase(Result[I]);
      NextUpper := False;
    end;
  end;

  // Remove underscores
  Result := StringReplace(Result, '_', '', [rfReplaceAll]);
end;

class function TFPCDemangler.Demangle(const MangledName: String): String;
var
  SymbolName: String;
begin
  // If it's not a mangled name, return as-is
  if not IsMangledName(MangledName) then
    Exit(MangledName);

  // Extract the symbol name
  SymbolName := ExtractSymbolName(MangledName);

  // Convert to mixed case (PascalCase)
  Result := ToMixedCase(SymbolName);

  // If we couldn't extract anything useful, return original
  if Result = '' then
    Result := MangledName;
end;

end.
