{
  PDR Debugger - Symbol Resolver

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit provides symbol resolution functionality.
  For the MVP, this is a thin wrapper around IDebugInfoReader.
}
unit pdr_symbols;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, opdf_types, pdr_ports;

type
  { Symbol Resolver - provides symbol lookup functionality }
  TSymbolResolver = class
  private
    FDebugInfoReader: IDebugInfoReader;
  public
    constructor Create(ADebugInfoReader: IDebugInfoReader);

    { Resolve a variable by name }
    function ResolveVariable(const Name: String; out VarInfo: TVariableInfo): Boolean;

    { Get all global variables }
    function GetGlobalVariables: TStringArray;

    { Find a type by ID }
    function FindType(TypeID: TTypeID; out TypeInfo: TTypeInfo): Boolean;
  end;

implementation

{ TSymbolResolver }

constructor TSymbolResolver.Create(ADebugInfoReader: IDebugInfoReader);
begin
  inherited Create;
  FDebugInfoReader := ADebugInfoReader;
end;

function TSymbolResolver.ResolveVariable(const Name: String;
  out VarInfo: TVariableInfo): Boolean;
begin
  // For MVP, delegate directly to debug info reader
  Result := FDebugInfoReader.FindVariable(Name, VarInfo);
end;

function TSymbolResolver.GetGlobalVariables: TStringArray;
begin
  Result := FDebugInfoReader.GetGlobalVariables;
end;

function TSymbolResolver.FindType(TypeID: TTypeID; out TypeInfo: TTypeInfo): Boolean;
begin
  Result := FDebugInfoReader.FindType(TypeID, TypeInfo);
end;

end.
