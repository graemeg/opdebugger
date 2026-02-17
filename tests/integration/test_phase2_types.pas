program test_phase2_types;

{$mode objfpc}{$H+}

type
  { Enum type }
  TColor = (clRed, clGreen, clBlue, clYellow);

  { Record type }
  TPoint = record
    X: Integer;
    Y: Integer;
  end;

  { Record with mixed field types }
  TNamedPoint = record
    Name: ShortString;
    Pos: TPoint;
    Color: TColor;
  end;

  { Static array type }
  TIntArray5 = array[0..4] of Integer;

  { Pointer type }
  PInteger = ^Integer;

  { Base class }
  TShape = class
  private
    FName: AnsiString;
    FColor: TColor;
  public
    constructor Create(const AName: AnsiString; AColor: TColor);
    property Name: AnsiString read FName write FName;
    property Color: TColor read FColor write FColor;
  end;

  { Derived class }
  TCircle = class(TShape)
  private
    FRadius: Double;
  public
    constructor Create(const AName: AnsiString; AColor: TColor; ARadius: Double);
    property Radius: Double read FRadius;  // read-only property
  end;

  { COM interface }
  IDrawable = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    procedure Draw;
    function GetName: AnsiString;
  end;

  { CORBA interface }
  ISerializable = interface
    procedure Serialize;
    procedure Deserialize;
  end;

{ TShape }

constructor TShape.Create(const AName: AnsiString; AColor: TColor);
begin
  FName := AName;
  FColor := AColor;
end;

{ TCircle }

constructor TCircle.Create(const AName: AnsiString; AColor: TColor; ARadius: Double);
begin
  inherited Create(AName, AColor);
  FRadius := ARadius;
end;

{ Test procedure with locals and params }
procedure TestLocalsAndParams(AValue: Integer; const AName: AnsiString; var AResult: Integer);
var
  LocalInt: Integer;
  LocalStr: ShortString;
  LocalFloat: Double;
begin
  LocalInt := AValue * 2;
  LocalStr := 'hello';
  LocalFloat := 3.14;
  AResult := LocalInt;
  { Use the variables to prevent optimization }
  if Length(LocalStr) > 0 then
    AResult := AResult + Round(LocalFloat);
  WriteLn('TestLocalsAndParams: AValue=', AValue, ' AName=', AName, ' Result=', AResult);
end;

var
  { Float variables }
  MySingle: Single;
  MyDouble: Double;

  { String variables }
  MyShortStr: ShortString;
  MyAnsiStr: AnsiString;
  MyUnicodeStr: UnicodeString;

  { Enum variable }
  MyColor: TColor;

  { Pointer variable }
  MyPtr: PInteger;
  MyIntTarget: Integer;

  { Static array }
  MyStaticArr: TIntArray5;

  { Dynamic array }
  MyDynArr: array of Integer;

  { Record variable }
  MyPoint: TPoint;
  MyNamedPt: TNamedPoint;

  { Class variables }
  MyShape: TShape;
  MyCircle: TCircle;

  { For procedure test }
  ResultVal: Integer;

begin
  { Float types }
  MySingle := 1.5;
  MyDouble := 2.718281828;

  { String types }
  MyShortStr := 'Short';
  MyAnsiStr := 'AnsiString value';
  MyUnicodeStr := 'Unicode value';

  { Enum }
  MyColor := clBlue;

  { Pointer }
  MyIntTarget := 42;
  MyPtr := @MyIntTarget;

  { Static array }
  MyStaticArr[0] := 10;
  MyStaticArr[1] := 20;
  MyStaticArr[2] := 30;
  MyStaticArr[3] := 40;
  MyStaticArr[4] := 50;

  { Dynamic array }
  SetLength(MyDynArr, 3);
  MyDynArr[0] := 100;
  MyDynArr[1] := 200;
  MyDynArr[2] := 300;

  { Record }
  MyPoint.X := 10;
  MyPoint.Y := 20;
  MyNamedPt.Name := 'Origin';
  MyNamedPt.Pos := MyPoint;
  MyNamedPt.Color := clRed;

  { Classes }
  MyShape := TShape.Create('BaseShape', clGreen);
  MyCircle := TCircle.Create('MyCircle', clYellow, 5.0);

  { Procedure with locals and params }
  ResultVal := 0;
  TestLocalsAndParams(7, 'test', ResultVal);

  WriteLn('Phase 2 type test complete');  { breakpoint line }
  WriteLn('Single=', MySingle:0:2, ' Double=', MyDouble:0:6);
  WriteLn('ShortStr=', MyShortStr, ' AnsiStr=', MyAnsiStr);
  WriteLn('Color=', Ord(MyColor));
  WriteLn('Ptr^=', MyPtr^);
  WriteLn('StaticArr[2]=', MyStaticArr[2]);
  WriteLn('DynArr[1]=', MyDynArr[1]);
  WriteLn('Point=(', MyPoint.X, ',', MyPoint.Y, ')');
  WriteLn('Shape.Name=', MyShape.Name);
  WriteLn('Result=', ResultVal);

  { Cleanup }
  MyShape.Free;
  MyCircle.Free;
end.
