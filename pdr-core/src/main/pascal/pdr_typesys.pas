{
  PDR Debugger - Type System (Strategy Pattern)

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit implements the type evaluation system using the Strategy pattern.
  Type evaluators are responsible for reading and formatting values of specific types.
}
unit pdr_typesys;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Contnrs, ogopdf, opdf_demangle, pdr_ports;

type
  { Type Evaluator Interface - Strategy pattern }
  ITypeEvaluator = interface
    ['{56789012-5678-5678-5678-567890123456}']

    { Evaluate a variable value from memory }
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController): TVariableValue;

    { Check if this evaluator can handle a specific type }
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Primitive Type Evaluator - handles Integer, Boolean, Char, etc. }
  TPrimitiveEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Type System - manages type evaluators }
  TTypeSystem = class
  private
    FEvaluators: TInterfaceList;
    FProcessController: IProcessController;
    FDebugInfoReader: IDebugInfoReader;
  public
    constructor Create(AProcessController: IProcessController; ADebugInfoReader: IDebugInfoReader);
    destructor Destroy; override;

    { Register a type evaluator }
    procedure RegisterEvaluator(Evaluator: ITypeEvaluator);

    { Evaluate a variable by name }
    function EvaluateVariable(const VarName: String): TVariableValue;

    { Evaluate a variable using provided info }
    function EvaluateVariableInfo(const VarInfo: TVariableInfo): TVariableValue;
  end;

implementation

{ TPrimitiveEvaluator }

function TPrimitiveEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  // Primitive types are 1, 2, 4, or 8 bytes
  // This is a simple heuristic - in practice we'd check the type category
  Result := (TypeInfo.Size in [1, 2, 4, 8]);
end;

function TPrimitiveEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController): TVariableValue;
var
  Buffer: array[0..7] of Byte;
  Value: Int64;
  UValue: QWord;
begin
  // Use demangled name for display
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  // Read memory at variable address
  FillChar(Buffer, SizeOf(Buffer), 0);

  if not ProcessController.ReadMemory(VarInfo.Address, TypeInfo.Size, Buffer) then
  begin
    Result.Value := '<error: failed to read memory>';
    Exit;
  end;

  // Parse value based on size and signedness
  if TypeInfo.IsSigned then
  begin
    // Signed integer
    case TypeInfo.Size of
      1: Value := ShortInt(Buffer[0]);
      2: Value := SmallInt(PWord(@Buffer)^);
      4: Value := LongInt(PDWord(@Buffer)^);
      8: Value := Int64(PQWord(@Buffer)^);
    else
      Result.Value := '<error: unsupported size>';
      Exit;
    end;

    Result.Value := IntToStr(Value);
  end
  else
  begin
    // Unsigned integer or Boolean
    case TypeInfo.Size of
      1: UValue := Byte(Buffer[0]);
      2: UValue := Word(PWord(@Buffer)^);
      4: UValue := DWord(PDWord(@Buffer)^);
      8: UValue := QWord(PQWord(@Buffer)^);
    else
      Result.Value := '<error: unsupported size>';
      Exit;
    end;

    // Special formatting for Boolean
    if (TypeInfo.Size = 1) and (Pos('Bool', TypeInfo.Name) > 0) then
    begin
      if UValue <> 0 then
        Result.Value := 'True'
      else
        Result.Value := 'False';
    end
    else
    begin
      Result.Value := IntToStr(UValue);
    end;
  end;

  Result.IsValid := True;
end;

{ TTypeSystem }

constructor TTypeSystem.Create(AProcessController: IProcessController;
  ADebugInfoReader: IDebugInfoReader);
begin
  inherited Create;
  FProcessController := AProcessController;
  FDebugInfoReader := ADebugInfoReader;
  FEvaluators := TInterfaceList.Create;
end;

destructor TTypeSystem.Destroy;
begin
  FEvaluators.Free;
  inherited Destroy;
end;

procedure TTypeSystem.RegisterEvaluator(Evaluator: ITypeEvaluator);
begin
  FEvaluators.Add(Evaluator);
end;

function TTypeSystem.EvaluateVariable(const VarName: String): TVariableValue;
var
  VarInfo: TVariableInfo;
begin
  Result.Name := VarName;
  Result.IsValid := False;

  // Find variable in debug info
  if not FDebugInfoReader.FindVariable(VarName, VarInfo) then
  begin
    Result.Value := '<error: variable not found>';
    Result.TypeName := '<unknown>';
    Exit;
  end;

  Result := EvaluateVariableInfo(VarInfo);
end;

function TTypeSystem.EvaluateVariableInfo(const VarInfo: TVariableInfo): TVariableValue;
var
  TypeInfo: TTypeInfo;
  I: Integer;
  Evaluator: ITypeEvaluator;
begin
  Result.Name := VarInfo.Name;
  Result.IsValid := False;

  // Find type information
  if not FDebugInfoReader.FindType(VarInfo.TypeID, TypeInfo) then
  begin
    Result.Value := '<error: type not found>';
    Result.TypeName := '<unknown>';
    Exit;
  end;

  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;

  // Find appropriate evaluator
  for I := 0 to FEvaluators.Count - 1 do
  begin
    Evaluator := FEvaluators[I] as ITypeEvaluator;
    if Evaluator.CanHandle(TypeInfo) then
    begin
      Result := Evaluator.Evaluate(VarInfo, TypeInfo, FProcessController);
      Exit;
    end;
  end;

  // No evaluator found
  Result.Value := '<error: no evaluator for type>';
end;

end.
