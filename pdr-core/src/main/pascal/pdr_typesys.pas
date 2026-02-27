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
  Classes, SysUtils, Contnrs, opdf_types, opdf_demangle, pdr_ports;

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

  { Float Type Evaluator - handles Single, Double, Extended }
  TFloatEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Pointer Type Evaluator }
  TPointerEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Record Type Evaluator }
  TRecordEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Enum Type Evaluator }
  TEnumEvaluator = class(TInterfacedObject, ITypeEvaluator)
  public
    function Evaluate(const VarInfo: TVariableInfo; const TypeInfo: TTypeInfo;
      ProcessController: IProcessController; TypeSystem: TTypeSystem): TVariableValue;
    function CanHandle(const TypeInfo: TTypeInfo): Boolean;
  end;

  { Set Type Evaluator - decodes a bitfield using the base enum's member names }
  TSetEvaluator = class(TInterfacedObject, ITypeEvaluator)
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
    FEvalDepth: Integer;

    { Resolve dot-notation field access (e.g. MyShape.FName) }
    function ResolveFieldAccess(const BaseName, FieldPath: String): TVariableValue;

    { Resolve a property name on a class instance, walking the inheritance chain }
    function ResolveClassProperty(const ClassTypeInfo: TTypeInfo;
      InstancePtr: QWord; const PropName: String): TVariableValue;
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
    // Special formatting for Char / AnsiChar (display as character, not ordinal)
    else if (TypeInfo.Size = 1) and
            ((UpperCase(TypeInfo.Name) = 'CHAR') or
             (UpperCase(TypeInfo.Name) = 'ANSICHAR')) then
    begin
      Result.Value := Chr(Byte(UValue));
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

{ Helper: Format the return value from an injected method call }
function FormatInjectedReturnValue(RetVal: QWord; TypeID: TTypeID;
  IsManaged: Boolean; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): String;
var
  PropTypeInfo: TTypeInfo;
  StringPtr: QWord;
  HeaderBuf: array[0..7] of Byte;
  Len: LongInt;
  DataBuf: array of Byte;
  I: Integer;
  IntVal: Int64;
begin
  Result := '<error>';

  if not TypeSystem.FDebugInfoReader.FindType(TypeID, PropTypeInfo) then
    Exit;

  if IsManaged and (PropTypeInfo.Category = tcAnsiString) then
  begin
    { RetVal is the address of the result buffer, read the AnsiString pointer from it }
    if not ProcessController.ReadMemory(RetVal, 8, StringPtr) then
      Exit;
    if StringPtr = 0 then
    begin
      Result := '''''';
      Exit;
    end;
    { Read AnsiString length at StringPtr - 8 }
    FillChar(HeaderBuf, SizeOf(HeaderBuf), 0);
    if not ProcessController.ReadMemory(StringPtr - 8, 8, HeaderBuf) then
      Exit;
    Len := PLongInt(@HeaderBuf)^;
    if (Len < 0) or (Len > 65536) then
      Exit;
    SetLength(DataBuf, Len);
    if Len > 0 then
      if not ProcessController.ReadMemory(StringPtr, Len, DataBuf[0]) then
        Exit;
    SetLength(Result, Len);
    for I := 0 to Len - 1 do
      Result[I + 1] := Chr(DataBuf[I]);
    Result := '''' + Result + '''';
  end
  else
  begin
    { Ordinal return in RAX — format based on type }
    if (PropTypeInfo.Category = tcPrimitive) then
    begin
      if (PropTypeInfo.Size = 1) and (Pos('BOOL', UpperCase(PropTypeInfo.Name)) > 0) then
      begin
        if (RetVal and $FF) <> 0 then Result := 'True'
        else Result := 'False';
      end
      else if PropTypeInfo.IsSigned then
      begin
        case PropTypeInfo.Size of
          1: IntVal := ShortInt(RetVal and $FF);
          2: IntVal := SmallInt(RetVal and $FFFF);
          4: IntVal := LongInt(RetVal and $FFFFFFFF);
        else
          IntVal := Int64(RetVal);
        end;
        Result := IntToStr(IntVal);
      end
      else
      begin
        case PropTypeInfo.Size of
          1: Result := IntToStr(RetVal and $FF);
          2: Result := IntToStr(RetVal and $FFFF);
          4: Result := IntToStr(RetVal and $FFFFFFFF);
        else
          Result := IntToStr(RetVal);
        end;
      end;
    end
    else if PropTypeInfo.Category = tcEnum then
    begin
      for I := 0 to High(PropTypeInfo.EnumMembers) do
        if PropTypeInfo.EnumMembers[I].Value = Int64(RetVal) then
        begin
          Result := PropTypeInfo.EnumMembers[I].Name + ' (' + IntToStr(RetVal) + ')';
          Exit;
        end;
      Result := IntToStr(RetVal);
    end
    else
      Result := IntToStr(RetVal);
  end;
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
  Prop: TDebuggerProperty;
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

  // Append field-backed properties (readable without calling a method)
  for I := 0 to High(TypeInfo.ClassInfo^.Properties) do
  begin
    Prop := TypeInfo.ClassInfo^.Properties[I];
    if Prop.ReadKind = pakField then
    begin
      FieldInfo.Name := Prop.Name;
      FieldInfo.TypeID := Prop.TypeID;
      FieldInfo.Address := InstancePtr + Prop.ReadOffset;
      FieldInfo.LocationExpr := 0;
      FieldInfo.LocationData := 0;
      if FieldOutput <> '' then FieldOutput := FieldOutput + ', ';
      FieldValue := TypeSystem.EvaluateVariableInfo(FieldInfo);
      FieldOutput := FieldOutput + Prop.Name + ': ' + FieldValue.Value;
    end;
  end;

  // List method-backed properties without calling (to avoid side effects).
  // Use "print Obj.PropName" to explicitly evaluate via call injection.
  for I := 0 to High(TypeInfo.ClassInfo^.Properties) do
  begin
    Prop := TypeInfo.ClassInfo^.Properties[I];
    if Prop.ReadKind = pakMethod then
    begin
      if FieldOutput <> '' then FieldOutput := FieldOutput + ', ';
      if Prop.ReadMethodName <> '' then
        FieldOutput := FieldOutput + Prop.Name + ': <getter: ' + Prop.ReadMethodName + '>'
      else
        FieldOutput := FieldOutput + Prop.Name + ': <getter>';
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
  MaxElements := ElementCount;
  if MaxElements > 10 then
    MaxElements := 10;

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
  HighBuf: array[0..7] of Byte;
  ArrayPtr: QWord;
  ArrayHigh: Int64;
  ArrayLength: LongInt;
  PtrSize: Byte;
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

  { Get pointer/SizeInt size from debug info (4 for 32-bit, 8 for 64-bit) }
  PtrSize := TypeSystem.FDebugInfoReader.GetPointerSize;
  if PtrSize = 0 then PtrSize := 8; { Default to 64-bit }

  { Read pointer to array data }
  FillChar(PointerBuf, SizeOf(PointerBuf), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, PtrSize, PointerBuf) then
  begin
    Result.Value := '<error: failed to read array pointer>';
    Exit;
  end;

  if PtrSize = 4 then
    ArrayPtr := PDWord(@PointerBuf)^
  else
    ArrayPtr := PQWord(@PointerBuf)^;

  { Nil array }
  if ArrayPtr = 0 then
  begin
    Result.Value := 'nil';
    Result.IsValid := True;
    Exit;
  end;

  { Read array high value. FPC stores the high index (Length-1) at
    ArrayPtr - SizeOf(SizeInt). SizeInt matches pointer size. }
  FillChar(HighBuf, SizeOf(HighBuf), 0);
  if not ProcessController.ReadMemory(ArrayPtr - PtrSize, PtrSize, HighBuf) then
  begin
    Result.Value := '<error: failed to read array length>';
    Exit;
  end;

  if PtrSize = 4 then
    ArrayHigh := PLongInt(@HighBuf)^
  else
    ArrayHigh := PInt64(@HighBuf)^;
  ArrayLength := ArrayHigh + 1;
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

{ TFloatEvaluator }

function TFloatEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcFloat);
end;

function TFloatEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  Buffer: array[0..9] of Byte;
  SingleVal: Single;
  DoubleVal: Double;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  FillChar(Buffer, SizeOf(Buffer), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, TypeInfo.Size, Buffer) then
  begin
    Result.Value := '<error: failed to read memory>';
    Exit;
  end;

  case TypeInfo.Size of
    4: begin  { Single }
         SingleVal := PSingle(@Buffer)^;
         Result.Value := FloatToStrF(SingleVal, ffGeneral, 7, 0);
       end;
    8: begin  { Double, Currency, Comp }
         DoubleVal := PDouble(@Buffer)^;
         Result.Value := FloatToStrF(DoubleVal, ffGeneral, 15, 0);
       end;
    10: begin { Extended }
          { Extended is 10 bytes on x86, read as Double approximation }
          DoubleVal := PExtended(@Buffer)^;
          Result.Value := FloatToStrF(DoubleVal, ffGeneral, 18, 0);
        end;
  else
    Result.Value := '<error: unsupported float size>';
    Exit;
  end;

  Result.IsValid := True;
end;

{ TPointerEvaluator }

function TPointerEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcPointer);
end;

function TPointerEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  PointerBuf: array[0..7] of Byte;
  PtrValue: QWord;
  TargetTypeInfo: TTypeInfo;
  TargetVarInfo: TVariableInfo;
  TargetValue: TVariableValue;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  { Read pointer value }
  FillChar(PointerBuf, SizeOf(PointerBuf), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, 8, PointerBuf) then
  begin
    Result.Value := '<error: failed to read pointer>';
    Exit;
  end;

  PtrValue := PQWord(@PointerBuf)^;

  { Nil pointer }
  if PtrValue = 0 then
  begin
    Result.Value := 'nil';
    Result.IsValid := True;
    Exit;
  end;

  { Try to dereference and show target value }
  if (TypeInfo.PointerTo <> 0) and
     TypeSystem.FDebugInfoReader.FindType(TypeInfo.PointerTo, TargetTypeInfo) then
  begin
    TargetVarInfo.Name := VarInfo.Name + '^';
    TargetVarInfo.TypeID := TypeInfo.PointerTo;
    TargetVarInfo.Address := PtrValue;
    TargetVarInfo.LocationExpr := 0;
    TargetVarInfo.LocationData := 0;

    TargetValue := TypeSystem.EvaluateVariableInfo(TargetVarInfo);
    if TargetValue.IsValid then
      Result.Value := '^' + TargetValue.Value + ' (@$' + IntToHex(PtrValue, 16) + ')'
    else
      Result.Value := '@$' + IntToHex(PtrValue, 16);
  end
  else
    Result.Value := '@$' + IntToHex(PtrValue, 16);

  Result.IsValid := True;
end;

{ TRecordEvaluator }

function TRecordEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcRecord);
end;

function TRecordEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  I: Integer;
  FieldInfo: TVariableInfo;
  FieldValue: TVariableValue;
  FieldOutput: String;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  if TypeInfo.RecordInfo = nil then
  begin
    Result.Value := '<error: no record info>';
    Exit;
  end;

  { Build field output }
  FieldOutput := '';
  for I := 0 to High(TypeInfo.RecordInfo^.Fields) do
  begin
    FieldInfo.Name := TypeInfo.RecordInfo^.Fields[I].Name;
    FieldInfo.TypeID := TypeInfo.RecordInfo^.Fields[I].TypeID;
    FieldInfo.Address := VarInfo.Address + TypeInfo.RecordInfo^.Fields[I].Offset;
    FieldInfo.LocationExpr := 0;
    FieldInfo.LocationData := 0;

    if I > 0 then FieldOutput := FieldOutput + ', ';

    if FieldInfo.TypeID <> 0 then
    begin
      FieldValue := TypeSystem.EvaluateVariableInfo(FieldInfo);
      FieldOutput := FieldOutput + FieldInfo.Name + ': ' + FieldValue.Value;
    end
    else
      FieldOutput := FieldOutput + FieldInfo.Name + ': <untyped>';
  end;

  Result.Value := TypeInfo.Name + ' { ' + FieldOutput + ' }';
  Result.IsValid := True;
end;

{ TEnumEvaluator }

function TEnumEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcEnum);
end;

function TEnumEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  Buffer: array[0..7] of Byte;
  OrdValue: Int64;
  I: Integer;
  MemberName: String;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  { Read ordinal value }
  FillChar(Buffer, SizeOf(Buffer), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, TypeInfo.Size, Buffer) then
  begin
    Result.Value := '<error: failed to read memory>';
    Exit;
  end;

  { Extract value based on size }
  case TypeInfo.Size of
    1: OrdValue := Byte(Buffer[0]);
    2: OrdValue := Word(PWord(@Buffer)^);
    4: OrdValue := DWord(PDWord(@Buffer)^);
  else
    OrdValue := Byte(Buffer[0]);
  end;

  { Find matching member name }
  MemberName := '';
  for I := 0 to High(TypeInfo.EnumMembers) do
  begin
    if TypeInfo.EnumMembers[I].Value = OrdValue then
    begin
      MemberName := TypeInfo.EnumMembers[I].Name;
      Break;
    end;
  end;

  if MemberName <> '' then
    Result.Value := MemberName + ' (' + IntToStr(OrdValue) + ')'
  else
    Result.Value := IntToStr(OrdValue);

  Result.IsValid := True;
end;

{ TSetEvaluator }

function TSetEvaluator.CanHandle(const TypeInfo: TTypeInfo): Boolean;
begin
  Result := (TypeInfo.Category = tcSet);
end;

function TSetEvaluator.Evaluate(const VarInfo: TVariableInfo;
  const TypeInfo: TTypeInfo; ProcessController: IProcessController;
  TypeSystem: TTypeSystem): TVariableValue;
var
  Buffer: array[0..7] of Byte;
  BaseTypeInfo: TTypeInfo;
  HasBaseEnum: Boolean;
  BitNum: Integer;
  OrdValue: Int64;
  I: Integer;
  MemberName: String;
  Members: String;
  ByteIdx: Integer;
  BitIdx: Integer;
  First: Boolean;
begin
  Result.Name := TFPCDemangler.Demangle(VarInfo.Name);
  Result.TypeName := TypeInfo.Name;
  Result.Address := VarInfo.Address;
  Result.IsValid := False;

  if TypeInfo.Size = 0 then
  begin
    Result.Value := '[]';
    Result.IsValid := True;
    Exit;
  end;

  FillChar(Buffer, SizeOf(Buffer), 0);
  if not ProcessController.ReadMemory(VarInfo.Address, TypeInfo.Size, Buffer) then
  begin
    Result.Value := '<error: failed to read memory>';
    Exit;
  end;

  { Look up base enum type for member names }
  HasBaseEnum := (TypeInfo.ElementTypeID <> 0) and
    TypeSystem.FDebugInfoReader.FindType(TypeInfo.ElementTypeID, BaseTypeInfo) and
    (Length(BaseTypeInfo.EnumMembers) > 0);

  Members := '';
  First := True;
  for BitNum := 0 to Integer(TypeInfo.Size) * 8 - 1 do
  begin
    ByteIdx := BitNum div 8;
    BitIdx  := BitNum mod 8;
    if (Buffer[ByteIdx] and (1 shl BitIdx)) <> 0 then
    begin
      OrdValue := TypeInfo.SetLowerBound + BitNum;
      MemberName := '';

      if HasBaseEnum then
        for I := 0 to High(BaseTypeInfo.EnumMembers) do
          if BaseTypeInfo.EnumMembers[I].Value = OrdValue then
          begin
            MemberName := BaseTypeInfo.EnumMembers[I].Name;
            Break;
          end;

      if not First then
        Members := Members + ', ';
      if MemberName <> '' then
        Members := Members + MemberName
      else
        Members := Members + IntToStr(OrdValue);
      First := False;
    end;
  end;

  Result.Value := '[' + Members + ']';
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
  FEvalDepth := 0;
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

function TTypeSystem.ResolveClassProperty(const ClassTypeInfo: TTypeInfo;
  InstancePtr: QWord; const PropName: String): TVariableValue;
var
  CurrentTypeInfo: TTypeInfo;
  ParentTypeInfo: TTypeInfo;
  PropTypeInfo: TTypeInfo;
  I: Integer;
  Prop: TDebuggerProperty;
  PropVarInfo: TVariableInfo;
  FuncInfo: TFunctionInfo;
  IsManaged: Boolean;
  RetVal: QWord;
begin
  Result.IsValid := False;
  Result.Value := '';

  CurrentTypeInfo := ClassTypeInfo;
  { Walk the inheritance chain }
  repeat
    if (CurrentTypeInfo.Category <> tcClass) or (CurrentTypeInfo.ClassInfo = nil) then
      Break;

    { Search properties in this class level }
    for I := 0 to High(CurrentTypeInfo.ClassInfo^.Properties) do
    begin
      Prop := CurrentTypeInfo.ClassInfo^.Properties[I];
      if CompareText(Prop.Name, PropName) = 0 then
      begin
        case Prop.ReadKind of
          pakField:
            begin
              PropVarInfo.Name := Prop.Name;
              PropVarInfo.TypeID := Prop.TypeID;
              PropVarInfo.Address := InstancePtr + Prop.ReadOffset;
              PropVarInfo.LocationExpr := 0;
              PropVarInfo.LocationData := 0;
              Result := EvaluateVariableInfo(PropVarInfo);
            end;
          pakMethod:
            begin
              { Try call injection }
              if (Prop.ReadMethodName <> '') and
                 FDebugInfoReader.FindFunctionByName(Prop.ReadMethodName, FuncInfo) then
              begin
                IsManaged := False;
                if FDebugInfoReader.FindType(Prop.TypeID, PropTypeInfo) then
                  IsManaged := PropTypeInfo.Category in [tcAnsiString, tcUnicodeString, tcArray];
                if FProcessController.InjectCall(FuncInfo.LowPC, InstancePtr, IsManaged, RetVal) then
                begin
                  Result.IsValid := True;
                  Result.Value := FormatInjectedReturnValue(RetVal, Prop.TypeID,
                    IsManaged, FProcessController, Self);
                end
                else
                begin
                  Result.IsValid := True;
                  Result.Value := '<method getter — call injection failed>';
                end;
              end
              else
              begin
                Result.IsValid := True;
                Result.Value := '<method getter — cannot evaluate without calling>';
              end;
            end;
          pakNone:
            begin
              Result.IsValid := True;
              Result.Value := '<write-only property>';
            end;
        end;
        Exit;
      end;
    end;

    { Move up to parent class }
    if (CurrentTypeInfo.ClassInfo^.ParentTypeID = 0) or
       not FDebugInfoReader.FindType(CurrentTypeInfo.ClassInfo^.ParentTypeID, ParentTypeInfo) then
      Break;
    CurrentTypeInfo := ParentTypeInfo;
  until False;
end;

function TTypeSystem.ResolveFieldAccess(const BaseName, FieldPath: String): TVariableValue;
var
  VarInfo: TVariableInfo;
  TypeInfo: TTypeInfo;
  RIP: QWord;
  InstancePtr: QWord;
  PointerBuf: array[0..7] of Byte;
  I: Integer;
  FieldName, RemainingPath: String;
  DotPos: Integer;
  Fields: TDebuggerFieldArray;
  FieldVarInfo: TVariableInfo;
  Found: Boolean;
begin
  Result.Name := BaseName + '.' + FieldPath;
  Result.IsValid := False;

  { Find the base variable }
  RIP := FProcessController.GetLastBreakpointAddress;
  if RIP = 0 then
    RIP := FProcessController.GetCurrentAddress;
  if RIP <> 0 then
  begin
    if not FDebugInfoReader.FindVariableWithScope(BaseName, RIP, VarInfo) then
      if not FDebugInfoReader.FindVariable(BaseName, VarInfo) then
      begin
        Result.Value := '<error: variable not found>';
        Exit;
      end;
  end
  else if not FDebugInfoReader.FindVariable(BaseName, VarInfo) then
  begin
    Result.Value := '<error: variable not found>';
    Exit;
  end;

  { Compute actual address for stack-based variables (same as EvaluateVariableInfo) }
  if VarInfo.LocationExpr = 1 then
  begin
    RIP := FProcessController.GetLastBreakpointAddress;
    if RIP = 0 then
      RIP := FProcessController.GetCurrentAddress;
    InstancePtr := FProcessController.GetLastBreakpointRBP;
    if InstancePtr = 0 then
      InstancePtr := FProcessController.GetFrameBasePointer;
    if InstancePtr <> 0 then
      VarInfo.Address := InstancePtr + VarInfo.LocationData;
  end
  else if VarInfo.LocationExpr = 2 then
  begin
    InstancePtr := FProcessController.GetLastBreakpointRBP;
    if InstancePtr = 0 then
      InstancePtr := FProcessController.GetFrameBasePointer;
    if InstancePtr <> 0 then
    begin
      FillChar(PointerBuf, SizeOf(PointerBuf), 0);
      if FProcessController.ReadMemory(InstancePtr, 8, PointerBuf) then
      begin
        InstancePtr := PQWord(@PointerBuf)^;
        VarInfo.Address := InstancePtr + VarInfo.LocationData;
      end;
    end;
  end;

  { Get type info for the base variable }
  if not FDebugInfoReader.FindType(VarInfo.TypeID, TypeInfo) then
  begin
    Result.Value := '<error: type not found>';
    Exit;
  end;

  { Split field path for potential nested access }
  DotPos := Pos('.', FieldPath);
  if DotPos > 0 then
  begin
    FieldName := Copy(FieldPath, 1, DotPos - 1);
    RemainingPath := Copy(FieldPath, DotPos + 1, Length(FieldPath));
  end
  else
  begin
    FieldName := FieldPath;
    RemainingPath := '';
  end;

  { Handle class types — dereference instance pointer first }
  if (TypeInfo.Category = tcClass) and (TypeInfo.ClassInfo <> nil) then
  begin
    { Read instance pointer }
    FillChar(PointerBuf, SizeOf(PointerBuf), 0);
    if not FProcessController.ReadMemory(VarInfo.Address, 8, PointerBuf) then
    begin
      Result.Value := '<error: failed to read instance pointer>';
      Exit;
    end;
    InstancePtr := PQWord(@PointerBuf)^;
    if InstancePtr = 0 then
    begin
      Result.Value := 'nil';
      Result.IsValid := True;
      Exit;
    end;

    Fields := TypeInfo.ClassInfo^.Fields;

    { Find the matching field (case-insensitive) }
    Found := False;
    for I := 0 to High(Fields) do
    begin
      if CompareText(Fields[I].Name, FieldName) = 0 then
      begin
        FieldVarInfo.Name := Fields[I].Name;
        FieldVarInfo.TypeID := Fields[I].TypeID;
        FieldVarInfo.Address := InstancePtr + Fields[I].Offset;
        FieldVarInfo.LocationExpr := 0;
        FieldVarInfo.LocationData := 0;
        Found := True;
        Break;
      end;
    end;

    if not Found then
    begin
      { Not a direct field — check properties, walking up the inheritance chain }
      Result := ResolveClassProperty(TypeInfo, InstancePtr, FieldName);
      if Result.IsValid then
        Result.Name := BaseName + '.' + FieldName
      else
        Result.Value := '<error: field or property "' + FieldName + '" not found>';
      Exit;
    end;

    if RemainingPath <> '' then
    begin
      { TODO: nested field access }
      Result.Value := '<error: nested field access not yet supported>';
      Exit;
    end;

    Result := EvaluateVariableInfo(FieldVarInfo);
    Result.Name := BaseName + '.' + FieldName;
  end
  { Handle record types — direct memory access }
  else if (TypeInfo.Category = tcRecord) and (TypeInfo.RecordInfo <> nil) then
  begin
    Fields := TypeInfo.RecordInfo^.Fields;

    Found := False;
    for I := 0 to High(Fields) do
    begin
      if CompareText(Fields[I].Name, FieldName) = 0 then
      begin
        FieldVarInfo.Name := Fields[I].Name;
        FieldVarInfo.TypeID := Fields[I].TypeID;
        FieldVarInfo.Address := VarInfo.Address + Fields[I].Offset;
        FieldVarInfo.LocationExpr := 0;
        FieldVarInfo.LocationData := 0;
        Found := True;
        Break;
      end;
    end;

    if not Found then
    begin
      Result.Value := '<error: field "' + FieldName + '" not found>';
      Exit;
    end;

    if RemainingPath <> '' then
    begin
      Result.Value := '<error: nested field access not yet supported>';
      Exit;
    end;

    Result := EvaluateVariableInfo(FieldVarInfo);
    Result.Name := BaseName + '.' + FieldName;
  end
  else
  begin
    Result.Value := '<error: type does not support field access>';
  end;
end;

function TTypeSystem.EvaluateVariable(const VarName: String): TVariableValue;
var
  VarInfo: TVariableInfo;
  ConstInfo: TConstantInfo;
  TypeInfo: TTypeInfo;
  RIP: QWord;
  DotPos: Integer;
  BaseName, FieldPath: String;
  IVal: Int64;
begin
  Result.Name := VarName;
  Result.IsValid := False;

  { Check for dot notation (e.g. MyShape.FName) }
  DotPos := Pos('.', VarName);
  if DotPos > 0 then
  begin
    BaseName := Copy(VarName, 1, DotPos - 1);
    FieldPath := Copy(VarName, DotPos + 1, Length(VarName));
    Result := ResolveFieldAccess(BaseName, FieldPath);
    Exit;
  end;

  { Try scope-aware lookup using the last breakpoint address.
    GetCurrentAddress() returns the RIP AFTER the single-step that reinserts the
    breakpoint, which may be inside a called function (e.g. WriteLn). The last
    breakpoint address is the original source line address and gives the correct scope. }
  RIP := FProcessController.GetLastBreakpointAddress;
  if RIP = 0 then
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
    { Try compile-time constant lookup }
    if FDebugInfoReader.FindConstant(VarName, ConstInfo) then
    begin
      Result.Name := VarName;
      Result.Value := ConstInfo.FormattedValue;
      Result.Address := 0;
      Result.IsValid := True;
      Result.TypeName := '<const>';

      { Refine display for ordinal constants using type info }
      if (ConstInfo.TypeID <> 0) and
         FDebugInfoReader.FindType(ConstInfo.TypeID, TypeInfo) then
      begin
        Result.TypeName := TypeInfo.Name;
        if (TypeInfo.Category = tcPrimitive) and (TypeInfo.Size = 1) and
           (Pos('BOOL', UpperCase(TypeInfo.Name)) > 0) then
        begin
          IVal := StrToInt64Def(ConstInfo.FormattedValue, 0);
          if IVal <> 0 then
            Result.Value := 'True'
          else
            Result.Value := 'False';
        end
        else if (TypeInfo.Category = tcPrimitive) and (TypeInfo.Size = 1) and
                ((UpperCase(TypeInfo.Name) = 'CHAR') or
                 (UpperCase(TypeInfo.Name) = 'ANSICHAR')) then
        begin
          IVal := StrToInt64Def(ConstInfo.FormattedValue, 0);
          if (IVal >= 32) and (IVal <= 126) then
            Result.Value := Chr(IVal)
          else
            Result.Value := '#' + IntToStr(IVal);
        end;
      end;
      Exit;
    end;

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
  ParentRBP: QWord;
  RBPBuf: array[0..7] of Byte;
begin
  Result.Name := VarInfo.Name;
  Result.IsValid := False;

  { Guard against deep/infinite recursion (class fields referencing other classes) }
  Inc(FEvalDepth);
  if FEvalDepth > 3 then
  begin
    Dec(FEvalDepth);
    Result.Value := '...';
    Result.TypeName := '';
    Exit;
  end;
  try

  // Find type information
  if not FDebugInfoReader.FindType(VarInfo.TypeID, TypeInfo) then
  begin
    Result.Value := '<error: type not found>';
    Result.TypeName := '<unknown>';
    Exit;
  end;

  Result.TypeName := TypeInfo.Name;

  { Compute actual address for stack-based variables.
    Use the RBP saved at the last breakpoint hit (before single-step), because after
    the single-step the CPU may have entered a called function, changing the frame. }
  ComputedVarInfo := VarInfo;
  if (VarInfo.LocationExpr = 1) then { RBP-relative (current frame) }
  begin
    RBP := FProcessController.GetLastBreakpointRBP;
    if RBP = 0 then
      RBP := FProcessController.GetFrameBasePointer;
    if RBP <> 0 then
    begin
      ComputedVarInfo.Address := RBP + VarInfo.LocationData;
      if gVerbose then
        WriteLn('[DEBUG] Computed address for ', VarInfo.Name, ': RBP=$',
                IntToHex(RBP, 16), ' + ', VarInfo.LocationData, ' = $',
                IntToHex(ComputedVarInfo.Address, 16));
    end;
  end
  else if (VarInfo.LocationExpr = 2) then { Parent frame RBP-relative (nested procedure) }
  begin
    RBP := FProcessController.GetLastBreakpointRBP;
    if RBP = 0 then
      RBP := FProcessController.GetFrameBasePointer;
    if RBP <> 0 then
    begin
      { Follow the saved RBP chain: the saved RBP at [RBP+0] is the caller's RBP }
      FillChar(RBPBuf, SizeOf(RBPBuf), 0);
      if FProcessController.ReadMemory(RBP, 8, RBPBuf) then
      begin
        ParentRBP := PQWord(@RBPBuf)^;
        ComputedVarInfo.Address := ParentRBP + VarInfo.LocationData;
        if gVerbose then
          WriteLn('[DEBUG] Computed parent frame address for ', VarInfo.Name,
                  ': ParentRBP=$', IntToHex(ParentRBP, 16), ' + ', VarInfo.LocationData,
                  ' = $', IntToHex(ComputedVarInfo.Address, 16));
      end;
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

  finally
    Dec(FEvalDepth);
  end;
end;

end.
