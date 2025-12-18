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
  { Forward declarations }
  TTypeSystem = class;

  { Type Evaluator Interface - Strategy pattern }
  ITypeEvaluator = interface
    ['{56789012-5678-5678-5678-567890123456}']

    { Evaluate a variable value from memory }
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;

    { Check if this evaluator can handle a specific type }
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Primitive Type Evaluator - handles Integer, Boolean, Char, etc. }
  TPrimitiveEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { ShortString Type Evaluator }
  TShortStringEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { AnsiString Type Evaluator }
  TAnsiStringEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { UnicodeString Type Evaluator }
  TUnicodeStringEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Class Type Evaluator }
  TClassEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Static Array Type Evaluator }
  TStaticArrayEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Dynamic Array Type Evaluator }
  TDynamicArrayEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
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
  Result := (TypeInfo.Category = tcPrimitive);
end;

function TPrimitiveEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
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

    // Special formatting for Boolean (case-insensitive check)
    if (TypeInfo.Size = 1) and (Pos('BOOL', UpperCase(TypeInfo.Name)) > 0) then
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

{ TShortStringEvaluator }

function TShortStringEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcShortString);
end;

function TShortStringEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  Buffer: array[0..255] of Byte;
  Len: Byte;
  Str: String;
  I: Integer;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  // ShortString format: [length byte][data bytes]
  // Read length byte + max possible data
  FillChar(Buffer, SizeOf(Buffer), 0);

  if not ProcessController.ReadMemory(VarInfo.Address, TypeInfo.MaxLength + 1, Buffer) then
  begin
    Result.Value := '<error: failed to read memory>';
    Exit;
  end;

  // First byte is the current length
  Len := Buffer[0];

  // Sanity check
  if Len > TypeInfo.MaxLength then
  begin
    Result.Value := '<error: invalid length>';
    Exit;
  end;

  // Extract string data
  SetLength(Str, Len);
  for I := 0 to Len - 1 do
    Str[I + 1] := Chr(Buffer[I + 1]);

  Result.Value := '''' + Str + '''';  // Manually add quotes
  Result.IsValid := True;
end;

{ TAnsiStringEvaluator }

function TAnsiStringEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcAnsiString);
end;

function TAnsiStringEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  PointerBuf: array[0..7] of Byte;
  StringPtr: QWord;
  HeaderBuf: array[0..15] of Byte;
  Len: LongInt;
  DataBuf: array of Byte;
  Str: String;
  I: Integer;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  // AnsiString is a pointer to heap memory
  // Format: [pointer] -> [length: LongInt at -8][refcount: LongInt at -4][data bytes][null]

  // Read pointer
  FillChar(PointerBuf, SizeOf(PointerBuf), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, 8, PointerBuf) then
  begin
    Result.Value := '<error: failed to read pointer>';
    Exit;
  end;

  StringPtr := PQWord(@PointerBuf)^;

  // Nil pointer means empty string
  if StringPtr = 0 then
  begin
    Result.Value := '''''';  // Empty string with quotes
    Result.IsValid := True;
    Exit;
  end;

  // Read header (length at StringPtr - 8)
  FillChar(HeaderBuf, SizeOf(HeaderBuf), 0);
  if not ProcessController.ReadMemory(StringPtr - 8, 8, HeaderBuf) then
  begin
    Result.Value := '<error: failed to read string header>';
    Exit;
  end;

  Len := PLongInt(@HeaderBuf)^;

  // Sanity check (limit to 64KB)
  if (Len < 0) or (Len > 65536) then
  begin
    Result.Value := '<error: invalid string length>';
    Exit;
  end;

  // Read string data
  SetLength(DataBuf, Len);
  if Len > 0 then
  begin
    if not ProcessController.ReadMemory(StringPtr, Len, DataBuf[0]) then
    begin
      Result.Value := '<error: failed to read string data>';
      Exit;
    end;
  end;

  // Convert to Pascal string
  SetLength(Str, Len);
  for I := 0 to Len - 1 do
    Str[I + 1] := Chr(DataBuf[I]);

  Result.Value := '''' + Str + '''';  // Manually add quotes
  Result.IsValid := True;
end;

{ TUnicodeStringEvaluator }

function TUnicodeStringEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  // Handle both UnicodeString and WideString (same UTF-16 layout)
  Result := (TypeInfo.Category = tcUnicodeString) or (TypeInfo.Category = tcWideString);
end;

function TUnicodeStringEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  PointerBuf: array[0..7] of Byte;
  StringPtr: QWord;
  HeaderBuf: array[0..15] of Byte;
  Len: LongInt;
  DataBuf: array of Byte;
  WideStr: UnicodeString;
  I: Integer;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  // UnicodeString is a pointer to heap memory (similar to AnsiString but WideChar elements)
  // Format: [pointer] -> [length: LongInt at -8][refcount: LongInt at -4][WideChar data][null]

  // Read pointer
  FillChar(PointerBuf, SizeOf(PointerBuf), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, 8, PointerBuf) then
  begin
    Result.Value := '<error: failed to read pointer>';
    Exit;
  end;

  StringPtr := PQWord(@PointerBuf)^;

  // Nil pointer means empty string
  if StringPtr = 0 then
  begin
    Result.Value := '''''';  // Empty string with quotes
    Result.IsValid := True;
    Exit;
  end;

  // Read header (length at StringPtr - 8)
  FillChar(HeaderBuf, SizeOf(HeaderBuf), 0);
  if not ProcessController.ReadMemory(StringPtr - 8, 8, HeaderBuf) then
  begin
    Result.Value := '<error: failed to read string header>';
    Exit;
  end;

  Len := PLongInt(@HeaderBuf)^;

  // Sanity check (limit to 32K characters = 64KB)
  if (Len < 0) or (Len > 32768) then
  begin
    Result.Value := '<error: invalid string length>';
    Exit;
  end;

  // Read string data (Len * 2 bytes for WideChar)
  SetLength(DataBuf, Len * 2);
  if Len > 0 then
  begin
    if not ProcessController.ReadMemory(StringPtr, Len * 2, DataBuf[0]) then
    begin
      Result.Value := '<error: failed to read string data>';
      Exit;
    end;
  end;

  // Convert to UnicodeString
  SetLength(WideStr, Len);
  for I := 0 to Len - 1 do
    WideStr[I + 1] := WideChar(PWord(@DataBuf[I * 2])^);

  Result.Value := '''' + UTF8Encode(WideStr) + '''';  // Manually add quotes
  Result.IsValid := True;
end;

{ TClassEvaluator }

function TClassEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcClass);
end;

function TClassEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  PointerBuf: array[0..7] of Byte;
  InstancePtr: QWord;
  I: Integer;
  FieldInfo: TVariableInfo;
  FieldValue: TVariableValue;
  FieldOutput: String;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  // Check if ClassInfo exists
  if TypeInfo.ClassInfo = nil then
  begin
    Result.Value := '<error: no class info>';
    Exit;
  end;

  // Read instance pointer (class variable is a pointer to instance)
  FillChar(PointerBuf, SizeOf(PointerBuf), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, 8, PointerBuf) then
  begin
    Result.Value := '<error: failed to read instance pointer>';
    Exit;
  end;

  InstancePtr := PQWord(@PointerBuf)^;

  // Check for nil instance
  if InstancePtr = 0 then
  begin
    Result.Value := 'nil';
    Result.IsValid := True;
    Exit;
  end;

  // Build field output
  FieldOutput := '';
  for I := 0 to High(TypeInfo.ClassInfo^.Fields) do
  begin
    FieldInfo.Name := TypeInfo.ClassInfo^.Fields[I].Name;
    FieldInfo.TypeID := TypeInfo.ClassInfo^.Fields[I].TypeID;
    FieldInfo.Address := InstancePtr + TypeInfo.ClassInfo^.Fields[I].Offset;

    if I > 0 then FieldOutput := FieldOutput + ', ';

    // Only evaluate if TypeID is known (not 0)
    if FieldInfo.TypeID <> 0 then
    begin
      // Recursive evaluation
      FieldValue := TypeSystem.EvaluateVariableInfo(FieldInfo);
      FieldOutput := FieldOutput + FieldInfo.Name + ': ' + FieldValue.Value;
    end
    else
    begin
      // TypeID not resolved yet, skip detailed evaluation
      FieldOutput := FieldOutput + FieldInfo.Name + ': <untyped>';
    end;
  end;

  Result.Value := TypeInfo.Name + '(@$' + IntToHex(InstancePtr, 16) +
                  ') { ' + FieldOutput + ' }';
  Result.IsValid := True;
end;

{ TStaticArrayEvaluator }

function TStaticArrayEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcArray) and not TypeInfo.IsDynamic;
end;

function TStaticArrayEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  I, ElementCount, MaxElements: Integer;
  ElementSize: Cardinal;
  ElementTypeInfo: TTypeInfo;
  ElementVarInfo: TVariableInfo;
  ElementValue: TVariableValue;
  ElementOutput: String;
  BoundsStr: String;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  { Get element type information }
  if not TypeSystem.FDebugInfoReader.FindType(TypeInfo.ElementTypeID, ElementTypeInfo) then
  begin
    Result.Value := '<error: element type not found>';
    Exit;
  end;

  { Calculate number of elements from bounds }
  if (Length(TypeInfo.Bounds) = 0) or (TypeInfo.Dimensions = 0) then
  begin
    Result.Value := '<error: no array bounds>';
    Exit;
  end;

  ElementCount := Integer(TypeInfo.Bounds[0].UpperBound - TypeInfo.Bounds[0].LowerBound + 1);
  if ElementCount < 0 then ElementCount := 0;

  { Limit to first 10 elements for display }
  MaxElements := 10;
  if ElementCount > MaxElements then
    MaxElements := ElementCount;

  { Build bounds string }
  BoundsStr := '[' + IntToStr(TypeInfo.Bounds[0].LowerBound) + '..' +
               IntToStr(TypeInfo.Bounds[0].UpperBound) + ']';

  ElementSize := ElementTypeInfo.Size;
  if ElementSize = 0 then ElementSize := 1;

  { Read and format elements }
  ElementOutput := '';
  for I := 0 to MaxElements - 1 do
  begin
    ElementVarInfo.Name := 'Element' + IntToStr(I);
    ElementVarInfo.TypeID := TypeInfo.ElementTypeID;
    ElementVarInfo.Address := VarInfo.Address + (I * ElementSize);
    ElementVarInfo.LocationExpr := 0;
    ElementVarInfo.LocationData := 0;

    if I > 0 then ElementOutput := ElementOutput + ', ';

    ElementValue := TypeSystem.EvaluateVariableInfo(ElementVarInfo);
    ElementOutput := ElementOutput + ElementValue.Value;
  end;

  if ElementCount > MaxElements then
    ElementOutput := ElementOutput + ', ...';

  Result.Value := 'array' + BoundsStr + ' of ' + ElementTypeInfo.Name +
                  ' = [' + ElementOutput + ']';
  Result.IsValid := True;
end;

{ TDynamicArrayEvaluator }

function TDynamicArrayEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcArray) and TypeInfo.IsDynamic;
end;

function TDynamicArrayEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  PointerBuf: array[0..7] of Byte;
  LengthBuf: array[0..3] of Byte;
  ArrayPtr: QWord;
  ArrayLength: LongInt;
  I, MaxElements: Integer;
  ElementSize: Cardinal;
  ElementTypeInfo: TTypeInfo;
  ElementVarInfo: TVariableInfo;
  ElementValue: TVariableValue;
  ElementOutput: String;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  { Read pointer to array data }
  FillChar(PointerBuf, SizeOf(PointerBuf), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, 8, PointerBuf) then
  begin
    Result.Value := '<error: failed to read array pointer>';
    Exit;
  end;

  ArrayPtr := PQWord(@PointerBuf)^;

  { Nil array }
  if ArrayPtr = 0 then
  begin
    Result.Value := 'nil';
    Result.IsValid := True;
    Exit;
  end;

  { Read array length (stored at ArrayPtr - 4) }
  FillChar(LengthBuf, SizeOf(LengthBuf), 0);
  if not ProcessController.ReadMemory(ArrayPtr - 4, 4, LengthBuf) then
  begin
    Result.Value := '<error: failed to read array length>';
    Exit;
  end;

  ArrayLength := PLongInt(@LengthBuf)^;
  if ArrayLength < 0 then ArrayLength := 0;

  { Get element type information }
  if not TypeSystem.FDebugInfoReader.FindType(TypeInfo.ElementTypeID, ElementTypeInfo) then
  begin
    Result.Value := '<error: element type not found>';
    Exit;
  end;

  ElementSize := ElementTypeInfo.Size;
  if ElementSize = 0 then ElementSize := 1;

  { Limit to first 10 elements for display }
  MaxElements := 10;
  if ArrayLength < MaxElements then
    MaxElements := ArrayLength;

  { Read and format elements }
  ElementOutput := '';
  for I := 0 to MaxElements - 1 do
  begin
    ElementVarInfo.Name := 'Element' + IntToStr(I);
    ElementVarInfo.TypeID := TypeInfo.ElementTypeID;
    ElementVarInfo.Address := ArrayPtr + (I * ElementSize);
    ElementVarInfo.LocationExpr := 0;
    ElementVarInfo.LocationData := 0;

    if I > 0 then ElementOutput := ElementOutput + ', ';

    ElementValue := TypeSystem.EvaluateVariableInfo(ElementVarInfo);
    ElementOutput := ElementOutput + ElementValue.Value;
  end;

  if ArrayLength > MaxElements then
    ElementOutput := ElementOutput + ', ...';

  Result.Value := 'array of ' + ElementTypeInfo.Name + ' (Length=' +
                  IntToStr(ArrayLength) + ') = [' + ElementOutput + ']';
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
  RIP: QWord;
begin
  Result.Name := VarName;
  Result.IsValid := False;

  { Try scope-aware lookup first if process is running }
  RIP := FProcessController.GetCurrentAddress;
  if RIP <> 0 then
  begin
    if FDebugInfoReader.FindVariableWithScope(VarName, RIP, VarInfo) then
    begin
      Result := EvaluateVariableInfo(VarInfo);
      Exit;
    end;
  end;

  { Fall back to simple global variable lookup }
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
  ComputedVarInfo: TVariableInfo;
  RBP: QWord;
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

  { Compute actual address for stack-based variables }
  ComputedVarInfo := VarInfo;
  if (VarInfo.LocationExpr = 1) then { RBP-relative }
  begin
    RBP := FProcessController.GetFrameBasePointer;
    if RBP <> 0 then
    begin
      ComputedVarInfo.Address := RBP + VarInfo.LocationData;
      WriteLn('[DEBUG] Computed address for ', VarInfo.Name, ': RBP=$',
              IntToHex(RBP, 16), ' + ', VarInfo.LocationData, ' = $',
              IntToHex(ComputedVarInfo.Address, 16));
    end;
  end;

  Result.Address := ComputedVarInfo.Address;

  // Find appropriate evaluator
  for I := 0 to FEvaluators.Count - 1 do
  begin
    Evaluator := FEvaluators[I] as ITypeEvaluator;
    if Evaluator.CanHandle(TypeInfo) then
    begin
      Result := Evaluator.Evaluate(ComputedVarInfo, TypeInfo, FProcessController, Self);
      Exit;
    end;
  end;

  // No evaluator found
  Result.Value := '<error: no evaluator for type>';
end;

end.
