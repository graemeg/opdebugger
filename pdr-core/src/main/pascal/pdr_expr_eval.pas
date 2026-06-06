{
  PDR Expression Evaluator — walks AST and produces typed values

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Evaluates parsed expression ASTs by resolving identifiers through
  the existing TTypeSystem, then performing arithmetic/logic on the
  results. All intermediate values are Int64, Double, String, or Boolean.
}
unit pdr_expr_eval;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, pdr_ports, pdr_typesys, pdr_expr;

type
  TExprValueKind = (
    evkInt,
    evkFloat,
    evkBool,
    evkStr,
    evkPointer,
    evkNil
  );

  TExprValue = record
    Kind: TExprValueKind;
    IntVal: Int64;
    FloatVal: Double;
    StrVal: String;
    BoolVal: Boolean;
    PtrVal: QWord;
    TypeName: String;
    DisplayName: String;
  end;

  TArraySliceFunc = function(const VarName: String;
    LowIndex, HighIndex: Int64): TVariableValueArray of object;

  TExprEvaluator = class
  private
    FTypeSystem: TTypeSystem;
    FDebugInfoReader: IDebugInfoReader;
    FArraySliceFunc: TArraySliceFunc;
    function EvalNode(Node: TExprNode): TExprValue;
    function EvalIdent(Node: TExprNode): TExprValue;
    function EvalDot(Node: TExprNode): TExprValue;
    function EvalIndex(Node: TExprNode): TExprValue;
    function EvalCall(Node: TExprNode): TExprValue;
    function EvalCast(Node: TExprNode): TExprValue;
    function EvalBinary(Node: TExprNode): TExprValue;
    function EvalComparison(Node: TExprNode): TExprValue;
    function EvalUnary(Node: TExprNode): TExprValue;
    function VarValueToExprValue(const VV: TVariableValue): TExprValue;
    function CoerceToInt(const V: TExprValue): Int64;
    function CoerceToFloat(const V: TExprValue): Double;
    function CoerceToBool(const V: TExprValue): Boolean;
    function BuildDotPath(Node: TExprNode): String;
  public
    constructor Create(ATypeSystem: TTypeSystem; ADebugInfoReader: IDebugInfoReader;
      AArraySliceFunc: TArraySliceFunc);
    function Evaluate(Node: TExprNode): TExprValue;
    function FormatValue(const V: TExprValue): String;
  end;

  EExprEvalError = class(Exception);

implementation

constructor TExprEvaluator.Create(ATypeSystem: TTypeSystem;
  ADebugInfoReader: IDebugInfoReader; AArraySliceFunc: TArraySliceFunc);
begin
  inherited Create;
  FTypeSystem := ATypeSystem;
  FDebugInfoReader := ADebugInfoReader;
  FArraySliceFunc := AArraySliceFunc;
end;

function TExprEvaluator.Evaluate(Node: TExprNode): TExprValue;
begin
  Result := EvalNode(Node);
end;

function TExprEvaluator.FormatValue(const V: TExprValue): String;
begin
  case V.Kind of
    evkInt:     Result := IntToStr(V.IntVal);
    evkFloat:   Result := FloatToStr(V.FloatVal);
    evkBool:
      if V.BoolVal then Result := 'True'
      else Result := 'False';
    evkStr:     Result := '''' + V.StrVal + '''';
    evkPointer: Result := '$' + IntToHex(V.PtrVal, 16);
    evkNil:     Result := 'nil';
  end;
end;

function TExprEvaluator.VarValueToExprValue(const VV: TVariableValue): TExprValue;
var
  S: String;
  IVal: Int64;
  FVal: Double;
  Code: Integer;
begin
  Result.Kind := evkStr;
  Result.IntVal := 0;
  Result.FloatVal := 0;
  Result.StrVal := '';
  Result.BoolVal := False;
  Result.PtrVal := 0;
  Result.TypeName := VV.TypeName;
  Result.DisplayName := VV.Name;

  if not VV.IsValid then
    raise EExprEvalError.Create(VV.Value);

  S := VV.Value;

  { Boolean }
  if (LowerCase(VV.TypeName) = 'boolean') or
     (LowerCase(S) = 'true') or (LowerCase(S) = 'false') then
  begin
    Result.Kind := evkBool;
    Result.BoolVal := (LowerCase(S) = 'true');
    Result.IntVal := Ord(Result.BoolVal);
    Exit;
  end;

  { nil pointer }
  if LowerCase(S) = 'nil' then
  begin
    Result.Kind := evkNil;
    Exit;
  end;

  { Pointer: $XXXXXXXX or 0xXXXXXXXX }
  if (Length(S) > 1) and (S[1] = '$') then
  begin
    Val(S, Result.PtrVal, Code);
    if Code = 0 then
    begin
      Result.Kind := evkPointer;
      Exit;
    end;
  end;

  { Quoted string: 'xxx' }
  if (Length(S) >= 2) and (S[1] = '''') and (S[Length(S)] = '''') then
  begin
    Result.Kind := evkStr;
    Result.StrVal := Copy(S, 2, Length(S) - 2);
    Exit;
  end;

  { Enum: try to keep as integer for comparisons }
  { First try integer parse }
  Val(S, IVal, Code);
  if Code = 0 then
  begin
    Result.Kind := evkInt;
    Result.IntVal := IVal;
    Exit;
  end;

  { Try float parse }
  Val(S, FVal, Code);
  if Code = 0 then
  begin
    Result.Kind := evkFloat;
    Result.FloatVal := FVal;
    Exit;
  end;

  { Fall back to string (enum names, etc.) }
  Result.Kind := evkStr;
  Result.StrVal := S;
end;

function TExprEvaluator.CoerceToInt(const V: TExprValue): Int64;
begin
  case V.Kind of
    evkInt:     Result := V.IntVal;
    evkFloat:   Result := Trunc(V.FloatVal);
    evkBool:    Result := Ord(V.BoolVal);
    evkPointer: Result := Int64(V.PtrVal);
    evkNil:     Result := 0;
  else
    raise EExprEvalError.Create('Cannot convert string to integer');
  end;
end;

function TExprEvaluator.CoerceToFloat(const V: TExprValue): Double;
begin
  case V.Kind of
    evkInt:     Result := V.IntVal;
    evkFloat:   Result := V.FloatVal;
    evkBool:    Result := Ord(V.BoolVal);
  else
    raise EExprEvalError.Create('Cannot convert to float');
  end;
end;

function TExprEvaluator.CoerceToBool(const V: TExprValue): Boolean;
begin
  case V.Kind of
    evkBool:    Result := V.BoolVal;
    evkInt:     Result := V.IntVal <> 0;
    evkPointer: Result := V.PtrVal <> 0;
    evkNil:     Result := False;
  else
    raise EExprEvalError.Create('Cannot convert to boolean');
  end;
end;

function TExprEvaluator.BuildDotPath(Node: TExprNode): String;
begin
  if Node.Kind = enkIdent then
    Result := Node.StrValue
  else if Node.Kind = enkDot then
    Result := BuildDotPath(Node.Left) + '.' + Node.Right.StrValue
  else
    Result := '';
end;

function TExprEvaluator.EvalNode(Node: TExprNode): TExprValue;
begin
  case Node.Kind of
    enkLitInt:
      begin
        Result.Kind := evkInt;
        Result.IntVal := Node.IntValue;
        Result.TypeName := 'Int64';
      end;
    enkLitFloat:
      begin
        Result.Kind := evkFloat;
        Result.FloatVal := Node.FloatValue;
        Result.TypeName := 'Double';
      end;
    enkLitStr:
      begin
        Result.Kind := evkStr;
        Result.StrVal := Node.StrValue;
        Result.TypeName := 'String';
      end;
    enkLitBool:
      begin
        Result.Kind := evkBool;
        Result.BoolVal := Node.IntValue <> 0;
        Result.IntVal := Node.IntValue;
        Result.TypeName := 'Boolean';
      end;
    enkLitNil:
      begin
        Result.Kind := evkNil;
        Result.TypeName := 'Pointer';
      end;
    enkIdent:
      Result := EvalIdent(Node);
    enkDot:
      Result := EvalDot(Node);
    enkIndex:
      Result := EvalIndex(Node);
    enkCall:
      Result := EvalCall(Node);
    enkCast:
      Result := EvalCast(Node);
    enkUnaryMinus, enkUnaryNot, enkUnaryAddr, enkUnaryDeref:
      Result := EvalUnary(Node);
    enkBinAdd, enkBinSub, enkBinMul, enkBinFDiv, enkBinIDiv,
    enkBinMod, enkBinShl, enkBinShr, enkBinAnd, enkBinOr, enkBinXor:
      Result := EvalBinary(Node);
    enkCmpEq, enkCmpNe, enkCmpLt, enkCmpGt, enkCmpLe, enkCmpGe:
      Result := EvalComparison(Node);
  else
    raise EExprEvalError.Create('Unknown AST node kind');
  end;
end;

function TExprEvaluator.EvalIdent(Node: TExprNode): TExprValue;
var
  VV: TVariableValue;
begin
  VV := FTypeSystem.EvaluateVariable(Node.StrValue);
  Result := VarValueToExprValue(VV);
end;

function TExprEvaluator.EvalDot(Node: TExprNode): TExprValue;
var
  Path: String;
  VV: TVariableValue;
begin
  Path := BuildDotPath(Node);
  if Path <> '' then
  begin
    VV := FTypeSystem.EvaluateVariable(Path);
    Result := VarValueToExprValue(VV);
  end
  else
    raise EExprEvalError.Create('Invalid field access expression');
end;

function TExprEvaluator.EvalIndex(Node: TExprNode): TExprValue;
var
  BasePath: String;
  IdxVal: TExprValue;
  Idx: Int64;
  SliceResult: TVariableValueArray;
begin
  BasePath := BuildDotPath(Node.Left);
  if BasePath = '' then
    raise EExprEvalError.Create('Array base must be an identifier or field path');

  IdxVal := EvalNode(Node.Right);
  Idx := CoerceToInt(IdxVal);

  if not Assigned(FArraySliceFunc) then
    raise EExprEvalError.Create('Array indexing not available');

  SliceResult := FArraySliceFunc(BasePath, Idx, Idx);
  if (Length(SliceResult) > 0) and SliceResult[0].IsValid then
    Result := VarValueToExprValue(SliceResult[0])
  else if (Length(SliceResult) > 0) then
    raise EExprEvalError.Create(SliceResult[0].Value)
  else
    raise EExprEvalError.Create('Array index out of bounds');
end;

function TExprEvaluator.EvalCall(Node: TExprNode): TExprValue;
var
  FuncName: String;
  ArgVal: TExprValue;
  TypeInfo: TTypeInfo;
begin
  FuncName := LowerCase(Node.StrValue);

  if Length(Node.Args) < 1 then
    raise EExprEvalError.CreateFmt('%s() requires an argument', [Node.StrValue]);

  ArgVal := EvalNode(Node.Args[0]);

  if FuncName = 'length' then
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    if ArgVal.Kind = evkStr then
      Result.IntVal := Length(ArgVal.StrVal)
    else
      raise EExprEvalError.Create('Length() requires a string or array argument');
  end
  else if FuncName = 'ord' then
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    if ArgVal.Kind = evkStr then
    begin
      if Length(ArgVal.StrVal) = 1 then
        Result.IntVal := Ord(ArgVal.StrVal[1])
      else
        raise EExprEvalError.Create('Ord() requires a single character');
    end
    else if ArgVal.Kind = evkBool then
      Result.IntVal := Ord(ArgVal.BoolVal)
    else if ArgVal.Kind = evkInt then
      Result.IntVal := ArgVal.IntVal
    else
      raise EExprEvalError.Create('Ord() requires an ordinal argument');
  end
  else if FuncName = 'chr' then
  begin
    Result.Kind := evkStr;
    Result.TypeName := 'Char';
    Result.StrVal := Chr(CoerceToInt(ArgVal) and $FF);
  end
  else if FuncName = 'abs' then
  begin
    if ArgVal.Kind = evkFloat then
    begin
      Result.Kind := evkFloat;
      Result.FloatVal := Abs(ArgVal.FloatVal);
      Result.TypeName := 'Double';
    end
    else
    begin
      Result.Kind := evkInt;
      Result.IntVal := Abs(CoerceToInt(ArgVal));
      Result.TypeName := 'Int64';
    end;
  end
  else if FuncName = 'pred' then
  begin
    Result.Kind := evkInt;
    Result.IntVal := CoerceToInt(ArgVal) - 1;
    Result.TypeName := ArgVal.TypeName;
  end
  else if FuncName = 'succ' then
  begin
    Result.Kind := evkInt;
    Result.IntVal := CoerceToInt(ArgVal) + 1;
    Result.TypeName := ArgVal.TypeName;
  end
  else if FuncName = 'sizeof' then
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    if FDebugInfoReader.FindTypeByName(Node.Args[0].StrValue, TypeInfo) then
      Result.IntVal := TypeInfo.Size
    else
      raise EExprEvalError.CreateFmt('Unknown type: %s', [Node.Args[0].StrValue]);
  end
  else if FuncName = 'high' then
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    if (Node.Args[0].Kind = enkIdent) and
       FDebugInfoReader.FindTypeByName(Node.Args[0].StrValue, TypeInfo) then
    begin
      if TypeInfo.Category = tcArray then
      begin
        if Length(TypeInfo.Bounds) > 0 then
          Result.IntVal := TypeInfo.Bounds[0].UpperBound
        else
          raise EExprEvalError.Create('Array has no bounds information');
      end
      else if TypeInfo.Category = tcEnum then
      begin
        if Length(TypeInfo.EnumMembers) > 0 then
          Result.IntVal := TypeInfo.EnumMembers[High(TypeInfo.EnumMembers)].Value
        else
          raise EExprEvalError.Create('Enum has no members');
      end
      else
        raise EExprEvalError.Create('High() requires an array or enum type');
    end
    else
      raise EExprEvalError.CreateFmt('Unknown type: %s', [Node.Args[0].StrValue]);
  end
  else if FuncName = 'low' then
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    if (Node.Args[0].Kind = enkIdent) and
       FDebugInfoReader.FindTypeByName(Node.Args[0].StrValue, TypeInfo) then
    begin
      if TypeInfo.Category = tcArray then
      begin
        if Length(TypeInfo.Bounds) > 0 then
          Result.IntVal := TypeInfo.Bounds[0].LowerBound
        else
          raise EExprEvalError.Create('Array has no bounds information');
      end
      else if TypeInfo.Category = tcEnum then
      begin
        if Length(TypeInfo.EnumMembers) > 0 then
          Result.IntVal := TypeInfo.EnumMembers[0].Value
        else
          raise EExprEvalError.Create('Enum has no members');
      end
      else
        raise EExprEvalError.Create('Low() requires an array or enum type');
    end
    else
      raise EExprEvalError.CreateFmt('Unknown type: %s', [Node.Args[0].StrValue]);
  end
  else if FuncName = 'pos' then
  begin
    if Length(Node.Args) < 2 then
      raise EExprEvalError.Create('Pos() requires two arguments');
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    ArgVal := EvalNode(Node.Args[1]);
    if (EvalNode(Node.Args[0]).Kind <> evkStr) or (ArgVal.Kind <> evkStr) then
      raise EExprEvalError.Create('Pos() requires string arguments');
    Result.IntVal := Pos(EvalNode(Node.Args[0]).StrVal, ArgVal.StrVal);
  end
  else
    raise EExprEvalError.CreateFmt('Unknown function: %s', [Node.StrValue]);
end;

function TExprEvaluator.EvalCast(Node: TExprNode): TExprValue;
var
  ArgVal: TExprValue;
  CastName: String;
begin
  if Length(Node.Args) < 1 then
    raise EExprEvalError.CreateFmt('%s() requires an argument', [Node.StrValue]);

  ArgVal := EvalNode(Node.Args[0]);
  CastName := LowerCase(Node.StrValue);

  if (CastName = 'integer') or (CastName = 'longint') or
     (CastName = 'int64') or (CastName = 'smallint') or
     (CastName = 'shortint') or (CastName = 'byte') or
     (CastName = 'word') or (CastName = 'cardinal') or
     (CastName = 'qword') or (CastName = 'nativeint') or
     (CastName = 'nativeuint') then
  begin
    Result.Kind := evkInt;
    Result.IntVal := CoerceToInt(ArgVal);
    Result.TypeName := Node.StrValue;
  end
  else if (CastName = 'boolean') then
  begin
    Result.Kind := evkBool;
    Result.BoolVal := CoerceToBool(ArgVal);
    Result.IntVal := Ord(Result.BoolVal);
    Result.TypeName := 'Boolean';
  end
  else if (CastName = 'char') then
  begin
    Result.Kind := evkStr;
    Result.StrVal := Chr(CoerceToInt(ArgVal) and $FF);
    Result.TypeName := 'Char';
  end
  else if (CastName = 'pointer') then
  begin
    Result.Kind := evkPointer;
    Result.PtrVal := QWord(CoerceToInt(ArgVal));
    Result.TypeName := 'Pointer';
  end
  else
    raise EExprEvalError.CreateFmt('Unsupported cast to %s', [Node.StrValue]);
end;

function TExprEvaluator.EvalBinary(Node: TExprNode): TExprValue;
var
  L, R: TExprValue;
  UseFloat: Boolean;
begin
  L := EvalNode(Node.Left);
  R := EvalNode(Node.Right);

  { String concatenation }
  if (Node.Kind = enkBinAdd) and
     ((L.Kind = evkStr) or (R.Kind = evkStr)) then
  begin
    Result.Kind := evkStr;
    Result.TypeName := 'String';
    if L.Kind = evkStr then
      Result.StrVal := L.StrVal
    else
      Result.StrVal := FormatValue(L);
    if R.Kind = evkStr then
      Result.StrVal := Result.StrVal + R.StrVal
    else
      Result.StrVal := Result.StrVal + FormatValue(R);
    Exit;
  end;

  { Logical operators }
  if Node.Kind in [enkBinAnd, enkBinOr, enkBinXor] then
  begin
    if (L.Kind = evkBool) or (R.Kind = evkBool) then
    begin
      Result.Kind := evkBool;
      Result.TypeName := 'Boolean';
      case Node.Kind of
        enkBinAnd: Result.BoolVal := CoerceToBool(L) and CoerceToBool(R);
        enkBinOr:  Result.BoolVal := CoerceToBool(L) or CoerceToBool(R);
        enkBinXor: Result.BoolVal := CoerceToBool(L) xor CoerceToBool(R);
      end;
      Result.IntVal := Ord(Result.BoolVal);
      Exit;
    end
    else
    begin
      Result.Kind := evkInt;
      Result.TypeName := 'Int64';
      case Node.Kind of
        enkBinAnd: Result.IntVal := CoerceToInt(L) and CoerceToInt(R);
        enkBinOr:  Result.IntVal := CoerceToInt(L) or CoerceToInt(R);
        enkBinXor: Result.IntVal := CoerceToInt(L) xor CoerceToInt(R);
      end;
      Exit;
    end;
  end;

  { Shift operators — always integer }
  if Node.Kind in [enkBinShl, enkBinShr] then
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    case Node.Kind of
      enkBinShl: Result.IntVal := CoerceToInt(L) shl CoerceToInt(R);
      enkBinShr: Result.IntVal := CoerceToInt(L) shr CoerceToInt(R);
    end;
    Exit;
  end;

  { Integer div/mod — always integer }
  if Node.Kind in [enkBinIDiv, enkBinMod] then
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    if CoerceToInt(R) = 0 then
      raise EExprEvalError.Create('Division by zero');
    case Node.Kind of
      enkBinIDiv: Result.IntVal := CoerceToInt(L) div CoerceToInt(R);
      enkBinMod:  Result.IntVal := CoerceToInt(L) mod CoerceToInt(R);
    end;
    Exit;
  end;

  { Float division — always float }
  if Node.Kind = enkBinFDiv then
  begin
    Result.Kind := evkFloat;
    Result.TypeName := 'Double';
    if CoerceToFloat(R) = 0 then
      raise EExprEvalError.Create('Division by zero');
    Result.FloatVal := CoerceToFloat(L) / CoerceToFloat(R);
    Exit;
  end;

  { Arithmetic: promote to float if either operand is float }
  UseFloat := (L.Kind = evkFloat) or (R.Kind = evkFloat);

  if UseFloat then
  begin
    Result.Kind := evkFloat;
    Result.TypeName := 'Double';
    case Node.Kind of
      enkBinAdd: Result.FloatVal := CoerceToFloat(L) + CoerceToFloat(R);
      enkBinSub: Result.FloatVal := CoerceToFloat(L) - CoerceToFloat(R);
      enkBinMul: Result.FloatVal := CoerceToFloat(L) * CoerceToFloat(R);
    end;
  end
  else
  begin
    Result.Kind := evkInt;
    Result.TypeName := 'Int64';
    case Node.Kind of
      enkBinAdd: Result.IntVal := CoerceToInt(L) + CoerceToInt(R);
      enkBinSub: Result.IntVal := CoerceToInt(L) - CoerceToInt(R);
      enkBinMul: Result.IntVal := CoerceToInt(L) * CoerceToInt(R);
    end;
  end;
end;

function TExprEvaluator.EvalComparison(Node: TExprNode): TExprValue;
var
  L, R: TExprValue;
  CmpResult: Boolean;
begin
  L := EvalNode(Node.Left);
  R := EvalNode(Node.Right);

  Result.Kind := evkBool;
  Result.TypeName := 'Boolean';
  CmpResult := False;

  { String comparison }
  if (L.Kind = evkStr) and (R.Kind = evkStr) then
  begin
    case Node.Kind of
      enkCmpEq: CmpResult := L.StrVal = R.StrVal;
      enkCmpNe: CmpResult := L.StrVal <> R.StrVal;
      enkCmpLt: CmpResult := L.StrVal < R.StrVal;
      enkCmpGt: CmpResult := L.StrVal > R.StrVal;
      enkCmpLe: CmpResult := L.StrVal <= R.StrVal;
      enkCmpGe: CmpResult := L.StrVal >= R.StrVal;
    end;
  end
  { Nil comparison }
  else if (L.Kind = evkNil) or (R.Kind = evkNil) then
  begin
    case Node.Kind of
      enkCmpEq: CmpResult := CoerceToInt(L) = CoerceToInt(R);
      enkCmpNe: CmpResult := CoerceToInt(L) <> CoerceToInt(R);
    else
      raise EExprEvalError.Create('Invalid comparison with nil');
    end;
  end
  { Float comparison }
  else if (L.Kind = evkFloat) or (R.Kind = evkFloat) then
  begin
    case Node.Kind of
      enkCmpEq: CmpResult := CoerceToFloat(L) = CoerceToFloat(R);
      enkCmpNe: CmpResult := CoerceToFloat(L) <> CoerceToFloat(R);
      enkCmpLt: CmpResult := CoerceToFloat(L) < CoerceToFloat(R);
      enkCmpGt: CmpResult := CoerceToFloat(L) > CoerceToFloat(R);
      enkCmpLe: CmpResult := CoerceToFloat(L) <= CoerceToFloat(R);
      enkCmpGe: CmpResult := CoerceToFloat(L) >= CoerceToFloat(R);
    end;
  end
  { Integer/boolean/pointer comparison }
  else
  begin
    case Node.Kind of
      enkCmpEq: CmpResult := CoerceToInt(L) = CoerceToInt(R);
      enkCmpNe: CmpResult := CoerceToInt(L) <> CoerceToInt(R);
      enkCmpLt: CmpResult := CoerceToInt(L) < CoerceToInt(R);
      enkCmpGt: CmpResult := CoerceToInt(L) > CoerceToInt(R);
      enkCmpLe: CmpResult := CoerceToInt(L) <= CoerceToInt(R);
      enkCmpGe: CmpResult := CoerceToInt(L) >= CoerceToInt(R);
    end;
  end;

  Result.BoolVal := CmpResult;
  Result.IntVal := Ord(CmpResult);
end;

function TExprEvaluator.EvalUnary(Node: TExprNode): TExprValue;
var
  Operand: TExprValue;
begin
  Operand := EvalNode(Node.Left);

  case Node.Kind of
    enkUnaryMinus:
      begin
        if Operand.Kind = evkFloat then
        begin
          Result.Kind := evkFloat;
          Result.FloatVal := -Operand.FloatVal;
          Result.TypeName := 'Double';
        end
        else
        begin
          Result.Kind := evkInt;
          Result.IntVal := -CoerceToInt(Operand);
          Result.TypeName := 'Int64';
        end;
      end;
    enkUnaryNot:
      begin
        if Operand.Kind = evkBool then
        begin
          Result.Kind := evkBool;
          Result.BoolVal := not Operand.BoolVal;
          Result.IntVal := Ord(Result.BoolVal);
          Result.TypeName := 'Boolean';
        end
        else
        begin
          Result.Kind := evkInt;
          Result.IntVal := not CoerceToInt(Operand);
          Result.TypeName := 'Int64';
        end;
      end;
    enkUnaryAddr:
      raise EExprEvalError.Create('Address-of operator (@) not yet supported');
    enkUnaryDeref:
      raise EExprEvalError.Create('Pointer dereference (^) not yet supported');
  end;
end;

end.
