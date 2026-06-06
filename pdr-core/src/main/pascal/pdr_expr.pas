{
  PDR Expression Parser — Tokeniser and recursive-descent parser

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Produces a simple AST from debugger expression strings such as:
    A + B * 2
    Obj.Field.SubField
    Arr[I * 2 + 1]
    Length(Items) - 1
    Integer(Ptr)
    (Token.Kind = tkIdentifier) and (Token.Value = 'begin')
}
unit pdr_expr;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { Token types produced by the lexer }
  TExprTokenKind = (
    etkEOF,
    etkInteger,       // 42, $FF, 0xFF
    etkFloat,         // 3.14
    etkString,        // 'hello'
    etkIdent,         // variable/function name
    etkPlus,          // +
    etkMinus,         // -
    etkStar,          // *
    etkSlash,         // /
    etkLParen,        // (
    etkRParen,        // )
    etkLBracket,      // [
    etkRBracket,      // ]
    etkDot,           // .
    etkComma,         // ,
    etkEqual,         // =
    etkNotEqual,      // <>
    etkLess,          // <
    etkGreater,       // >
    etkLessEqual,     // <=
    etkGreaterEqual,  // >=
    etkCaret,         // ^ (pointer deref)
    etkAt             // @ (address-of)
  );

  TExprToken = record
    Kind: TExprTokenKind;
    IntValue: Int64;
    FloatValue: Double;
    StrValue: String;
  end;

  { AST node types }
  TExprNodeKind = (
    enkLitInt,        // integer literal
    enkLitFloat,      // float literal
    enkLitStr,        // string literal
    enkLitBool,       // True/False
    enkLitNil,        // nil
    enkIdent,         // bare identifier (variable/const name)
    enkDot,           // field access: Left.Right
    enkIndex,         // array index: Left[Right]
    enkCall,          // function call: Name(Args...)
    enkCast,          // type cast: TypeName(Expr)
    enkUnaryMinus,    // -Expr
    enkUnaryNot,      // not Expr
    enkUnaryAddr,     // @Expr
    enkUnaryDeref,    // Expr^
    enkBinAdd,        // +
    enkBinSub,        // -
    enkBinMul,        // *
    enkBinFDiv,       // /
    enkBinIDiv,       // div
    enkBinMod,        // mod
    enkBinShl,        // shl
    enkBinShr,        // shr
    enkBinAnd,        // and
    enkBinOr,         // or
    enkBinXor,        // xor
    enkCmpEq,         // =
    enkCmpNe,         // <>
    enkCmpLt,         // <
    enkCmpGt,         // >
    enkCmpLe,         // <=
    enkCmpGe          // >=
  );

  TExprNode = class;
  TExprNodeArray = array of TExprNode;

  TExprNode = class
    Kind: TExprNodeKind;
    IntValue: Int64;
    FloatValue: Double;
    StrValue: String;
    Left: TExprNode;
    Right: TExprNode;
    Args: TExprNodeArray;
    destructor Destroy; override;
  end;

  { Tokeniser }
  TExprLexer = class
  private
    FSource: String;
    FPos: Integer;
    function PeekChar: Char;
    function ReadChar: Char;
    procedure SkipWhitespace;
  public
    constructor Create(const ASource: String);
    function NextToken: TExprToken;
  end;

  { Recursive-descent parser }
  TExprParser = class
  private
    FLexer: TExprLexer;
    FCurrent: TExprToken;
    procedure Advance;
    procedure Expect(Kind: TExprTokenKind);
    function ParseExpr: TExprNode;
    function ParseOr: TExprNode;
    function ParseAnd: TExprNode;
    function ParseComparison: TExprNode;
    function ParseAddSub: TExprNode;
    function ParseMulDiv: TExprNode;
    function ParseUnary: TExprNode;
    function ParsePostfix: TExprNode;
    function ParsePrimary: TExprNode;
    function IsBuiltinFunc(const Name: String): Boolean;
  public
    constructor Create(const ASource: String);
    destructor Destroy; override;
    function Parse: TExprNode;
  end;

  EExprParseError = class(Exception);

implementation

{ TExprNode }

destructor TExprNode.Destroy;
var
  I: Integer;
begin
  Left.Free;
  Right.Free;
  for I := 0 to High(Args) do
    Args[I].Free;
  inherited Destroy;
end;

{ TExprLexer }

constructor TExprLexer.Create(const ASource: String);
begin
  inherited Create;
  FSource := ASource;
  FPos := 1;
end;

function TExprLexer.PeekChar: Char;
begin
  if FPos <= Length(FSource) then
    Result := FSource[FPos]
  else
    Result := #0;
end;

function TExprLexer.ReadChar: Char;
begin
  Result := PeekChar;
  Inc(FPos);
end;

procedure TExprLexer.SkipWhitespace;
begin
  while (FPos <= Length(FSource)) and (FSource[FPos] in [' ', #9]) do
    Inc(FPos);
end;

function TExprLexer.NextToken: TExprToken;
var
  C, C2: Char;
  Start: Integer;
  S: String;
  NumStr: String;
  Code: Integer;
begin
  Result.Kind := etkEOF;
  Result.IntValue := 0;
  Result.FloatValue := 0;
  Result.StrValue := '';

  SkipWhitespace;

  if FPos > Length(FSource) then
    Exit;

  C := PeekChar;

  { String literal }
  if C = '''' then
  begin
    Inc(FPos);
    S := '';
    while FPos <= Length(FSource) do
    begin
      C := ReadChar;
      if C = '''' then
      begin
        if PeekChar = '''' then
        begin
          S := S + '''';
          Inc(FPos);
        end
        else
          Break;
      end
      else
        S := S + C;
    end;
    Result.Kind := etkString;
    Result.StrValue := S;
    Exit;
  end;

  { Hex literal: $FF or 0xFF / 0XFF }
  if C = '$' then
  begin
    Inc(FPos);
    S := '';
    while (FPos <= Length(FSource)) and
          (FSource[FPos] in ['0'..'9', 'a'..'f', 'A'..'F']) do
    begin
      S := S + FSource[FPos];
      Inc(FPos);
    end;
    if S = '' then
      raise EExprParseError.Create('Expected hex digits after $');
    Result.Kind := etkInteger;
    Val('$' + S, Result.IntValue, Code);
    if Code <> 0 then
      raise EExprParseError.Create('Invalid hex literal: $' + S);
    Exit;
  end;

  if (C = '0') and (FPos + 1 <= Length(FSource)) and
     (FSource[FPos + 1] in ['x', 'X']) then
  begin
    Inc(FPos, 2);
    S := '';
    while (FPos <= Length(FSource)) and
          (FSource[FPos] in ['0'..'9', 'a'..'f', 'A'..'F']) do
    begin
      S := S + FSource[FPos];
      Inc(FPos);
    end;
    if S = '' then
      raise EExprParseError.Create('Expected hex digits after 0x');
    Result.Kind := etkInteger;
    Val('$' + S, Result.IntValue, Code);
    if Code <> 0 then
      raise EExprParseError.Create('Invalid hex literal: 0x' + S);
    Exit;
  end;

  { Numeric literal (integer or float) }
  if C in ['0'..'9'] then
  begin
    Start := FPos;
    while (FPos <= Length(FSource)) and (FSource[FPos] in ['0'..'9']) do
      Inc(FPos);
    if (FPos <= Length(FSource)) and (FSource[FPos] = '.') and
       (FPos + 1 <= Length(FSource)) and (FSource[FPos + 1] in ['0'..'9']) then
    begin
      Inc(FPos);
      while (FPos <= Length(FSource)) and (FSource[FPos] in ['0'..'9']) do
        Inc(FPos);
      NumStr := Copy(FSource, Start, FPos - Start);
      Result.Kind := etkFloat;
      Val(NumStr, Result.FloatValue, Code);
      if Code <> 0 then
        raise EExprParseError.Create('Invalid float literal: ' + NumStr);
    end
    else
    begin
      NumStr := Copy(FSource, Start, FPos - Start);
      Result.Kind := etkInteger;
      Val(NumStr, Result.IntValue, Code);
      if Code <> 0 then
        raise EExprParseError.Create('Invalid integer literal: ' + NumStr);
    end;
    Exit;
  end;

  { Identifier or keyword }
  if C in ['a'..'z', 'A'..'Z', '_'] then
  begin
    Start := FPos;
    while (FPos <= Length(FSource)) and
          (FSource[FPos] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(FPos);
    S := Copy(FSource, Start, FPos - Start);
    Result.Kind := etkIdent;
    Result.StrValue := S;
    Exit;
  end;

  { Operators and punctuation }
  C := ReadChar;
  case C of
    '+': Result.Kind := etkPlus;
    '-': Result.Kind := etkMinus;
    '*': Result.Kind := etkStar;
    '/': Result.Kind := etkSlash;
    '(': Result.Kind := etkLParen;
    ')': Result.Kind := etkRParen;
    '[': Result.Kind := etkLBracket;
    ']': Result.Kind := etkRBracket;
    '.': Result.Kind := etkDot;
    ',': Result.Kind := etkComma;
    '^': Result.Kind := etkCaret;
    '@': Result.Kind := etkAt;
    '=': Result.Kind := etkEqual;
    '<':
      begin
        C2 := PeekChar;
        if C2 = '>' then
        begin
          Inc(FPos);
          Result.Kind := etkNotEqual;
        end
        else if C2 = '=' then
        begin
          Inc(FPos);
          Result.Kind := etkLessEqual;
        end
        else
          Result.Kind := etkLess;
      end;
    '>':
      begin
        if PeekChar = '=' then
        begin
          Inc(FPos);
          Result.Kind := etkGreaterEqual;
        end
        else
          Result.Kind := etkGreater;
      end;
  else
    raise EExprParseError.Create('Unexpected character: ' + C);
  end;
end;

{ TExprParser }

constructor TExprParser.Create(const ASource: String);
begin
  inherited Create;
  FLexer := TExprLexer.Create(ASource);
  Advance;
end;

destructor TExprParser.Destroy;
begin
  FLexer.Free;
  inherited Destroy;
end;

procedure TExprParser.Advance;
begin
  FCurrent := FLexer.NextToken;
end;

procedure TExprParser.Expect(Kind: TExprTokenKind);
begin
  if FCurrent.Kind <> Kind then
    raise EExprParseError.CreateFmt('Expected token %d, got %d',
      [Ord(Kind), Ord(FCurrent.Kind)]);
  Advance;
end;

function TExprParser.IsBuiltinFunc(const Name: String): Boolean;
var
  LName: String;
begin
  LName := LowerCase(Name);
  Result := (LName = 'length') or (LName = 'ord') or (LName = 'chr') or
            (LName = 'pos') or (LName = 'sizeof') or (LName = 'high') or
            (LName = 'low') or (LName = 'abs') or (LName = 'pred') or
            (LName = 'succ');
end;

function TExprParser.Parse: TExprNode;
begin
  Result := ParseExpr;
  if FCurrent.Kind <> etkEOF then
  begin
    Result.Free;
    raise EExprParseError.Create('Unexpected token after expression');
  end;
end;

{ Expression = Or }
function TExprParser.ParseExpr: TExprNode;
begin
  Result := ParseOr;
end;

{ Or = And (('or' | 'xor') And)* }
function TExprParser.ParseOr: TExprNode;
var
  Node: TExprNode;
  LName: String;
begin
  Result := ParseAnd;
  try
    while (FCurrent.Kind = etkIdent) do
    begin
      LName := LowerCase(FCurrent.StrValue);
      if LName = 'or' then
      begin
        Advance;
        Node := TExprNode.Create;
        Node.Kind := enkBinOr;
        Node.Left := Result;
        Result := Node;
        Node.Right := ParseAnd;
      end
      else if LName = 'xor' then
      begin
        Advance;
        Node := TExprNode.Create;
        Node.Kind := enkBinXor;
        Node.Left := Result;
        Result := Node;
        Node.Right := ParseAnd;
      end
      else
        Break;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ And = Comparison ('and' Comparison)* }
function TExprParser.ParseAnd: TExprNode;
var
  Node: TExprNode;
begin
  Result := ParseComparison;
  try
    while (FCurrent.Kind = etkIdent) and
          (LowerCase(FCurrent.StrValue) = 'and') do
    begin
      Advance;
      Node := TExprNode.Create;
      Node.Kind := enkBinAnd;
      Node.Left := Result;
      Result := Node;
      Node.Right := ParseComparison;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ Comparison = AddSub (('=' | '<>' | '<' | '>' | '<=' | '>=') AddSub)? }
function TExprParser.ParseComparison: TExprNode;
var
  Node: TExprNode;
  NK: TExprNodeKind;
begin
  Result := ParseAddSub;
  try
    case FCurrent.Kind of
      etkEqual:        NK := enkCmpEq;
      etkNotEqual:     NK := enkCmpNe;
      etkLess:         NK := enkCmpLt;
      etkGreater:      NK := enkCmpGt;
      etkLessEqual:    NK := enkCmpLe;
      etkGreaterEqual: NK := enkCmpGe;
    else
      Exit;
    end;
    Advance;
    Node := TExprNode.Create;
    Node.Kind := NK;
    Node.Left := Result;
    Result := Node;
    Node.Right := ParseAddSub;
  except
    Result.Free;
    raise;
  end;
end;

{ AddSub = MulDiv (('+' | '-') MulDiv)* }
function TExprParser.ParseAddSub: TExprNode;
var
  Node: TExprNode;
begin
  Result := ParseMulDiv;
  try
    while FCurrent.Kind in [etkPlus, etkMinus] do
    begin
      Node := TExprNode.Create;
      if FCurrent.Kind = etkPlus then
        Node.Kind := enkBinAdd
      else
        Node.Kind := enkBinSub;
      Advance;
      Node.Left := Result;
      Result := Node;
      Node.Right := ParseMulDiv;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ MulDiv = Unary (('*' | '/' | 'div' | 'mod' | 'shl' | 'shr') Unary)* }
function TExprParser.ParseMulDiv: TExprNode;
var
  Node: TExprNode;
  NK: TExprNodeKind;
  LName: String;
begin
  Result := ParseUnary;
  try
    while True do
    begin
      case FCurrent.Kind of
        etkStar:  NK := enkBinMul;
        etkSlash: NK := enkBinFDiv;
        etkIdent:
          begin
            LName := LowerCase(FCurrent.StrValue);
            if LName = 'div' then NK := enkBinIDiv
            else if LName = 'mod' then NK := enkBinMod
            else if LName = 'shl' then NK := enkBinShl
            else if LName = 'shr' then NK := enkBinShr
            else Break;
          end;
      else
        Break;
      end;
      Advance;
      Node := TExprNode.Create;
      Node.Kind := NK;
      Node.Left := Result;
      Result := Node;
      Node.Right := ParseUnary;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ Unary = '-' Unary | 'not' Unary | '@' Unary | Postfix }
function TExprParser.ParseUnary: TExprNode;
var
  Node: TExprNode;
begin
  if FCurrent.Kind = etkMinus then
  begin
    Advance;
    Node := TExprNode.Create;
    Node.Kind := enkUnaryMinus;
    Node.Left := Self.ParseUnary;
    Result := Node;
  end
  else if FCurrent.Kind = etkAt then
  begin
    Advance;
    Node := TExprNode.Create;
    Node.Kind := enkUnaryAddr;
    Node.Left := Self.ParseUnary;
    Result := Node;
  end
  else if (FCurrent.Kind = etkIdent) and
          (LowerCase(FCurrent.StrValue) = 'not') then
  begin
    Advance;
    Node := TExprNode.Create;
    Node.Kind := enkUnaryNot;
    Node.Left := Self.ParseUnary;
    Result := Node;
  end
  else
    Result := ParsePostfix;
end;

{ Postfix = Primary ('.' Ident | '[' Expr ']' | '^')* }
function TExprParser.ParsePostfix: TExprNode;
var
  Node: TExprNode;
begin
  Result := ParsePrimary;
  try
    while True do
    begin
      if FCurrent.Kind = etkDot then
      begin
        Advance;
        if FCurrent.Kind <> etkIdent then
        begin
          raise EExprParseError.Create('Expected identifier after "."');
        end;
        Node := TExprNode.Create;
        Node.Kind := enkDot;
        Node.Left := Result;
        Result := Node;
        Node.Right := TExprNode.Create;
        Node.Right.Kind := enkIdent;
        Node.Right.StrValue := FCurrent.StrValue;
        Advance;
      end
      else if FCurrent.Kind = etkLBracket then
      begin
        Advance;
        Node := TExprNode.Create;
        Node.Kind := enkIndex;
        Node.Left := Result;
        Result := Node;
        Node.Right := ParseExpr;
        Expect(etkRBracket);
      end
      else if FCurrent.Kind = etkCaret then
      begin
        Advance;
        Node := TExprNode.Create;
        Node.Kind := enkUnaryDeref;
        Node.Left := Result;
        Result := Node;
      end
      else
        Break;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ Primary = Integer | Float | String | 'True' | 'False' | 'nil'
          | Ident '(' [Expr (',' Expr)*] ')'   -- function call or type cast
          | Ident
          | '(' Expr ')' }
function TExprParser.ParsePrimary: TExprNode;
var
  Name: String;
  Arg: TExprNode;
begin
  case FCurrent.Kind of
    etkInteger:
      begin
        Result := TExprNode.Create;
        Result.Kind := enkLitInt;
        Result.IntValue := FCurrent.IntValue;
        Advance;
      end;

    etkFloat:
      begin
        Result := TExprNode.Create;
        Result.Kind := enkLitFloat;
        Result.FloatValue := FCurrent.FloatValue;
        Advance;
      end;

    etkString:
      begin
        Result := TExprNode.Create;
        Result.Kind := enkLitStr;
        Result.StrValue := FCurrent.StrValue;
        Advance;
      end;

    etkIdent:
      begin
        Name := FCurrent.StrValue;

        if LowerCase(Name) = 'true' then
        begin
          Result := TExprNode.Create;
          Result.Kind := enkLitBool;
          Result.IntValue := 1;
          Advance;
          Exit;
        end;

        if LowerCase(Name) = 'false' then
        begin
          Result := TExprNode.Create;
          Result.Kind := enkLitBool;
          Result.IntValue := 0;
          Advance;
          Exit;
        end;

        if LowerCase(Name) = 'nil' then
        begin
          Result := TExprNode.Create;
          Result.Kind := enkLitNil;
          Advance;
          Exit;
        end;

        Advance;

        { Check for function call or type cast: Name(...) }
        if FCurrent.Kind = etkLParen then
        begin
          Advance;
          Result := TExprNode.Create;
          try
            if IsBuiltinFunc(Name) then
              Result.Kind := enkCall
            else
              Result.Kind := enkCast;
            Result.StrValue := Name;

            if FCurrent.Kind <> etkRParen then
            begin
              Arg := ParseExpr;
              SetLength(Result.Args, 1);
              Result.Args[0] := Arg;

              while FCurrent.Kind = etkComma do
              begin
                Advance;
                Arg := ParseExpr;
                SetLength(Result.Args, Length(Result.Args) + 1);
                Result.Args[High(Result.Args)] := Arg;
              end;
            end;

            Expect(etkRParen);
          except
            Result.Free;
            raise;
          end;
          Exit;
        end;

        { Plain identifier }
        Result := TExprNode.Create;
        Result.Kind := enkIdent;
        Result.StrValue := Name;
      end;

    etkLParen:
      begin
        Advance;
        Result := ParseExpr;
        try
          Expect(etkRParen);
        except
          Result.Free;
          raise;
        end;
      end;

  else
    raise EExprParseError.CreateFmt('Unexpected token (kind=%d)',
      [Ord(FCurrent.Kind)]);
  end;
end;

end.
