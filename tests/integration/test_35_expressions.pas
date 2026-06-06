program test_35_expressions;

{$mode objfpc}{$H+}

var
  IntA: LongInt;
  IntB: LongInt;
  FloatC: Double;
  BoolFlag: Boolean;
  MyStr: AnsiString;
  Arr: array[0..4] of LongInt;

begin
  IntA := 10;
  IntB := 3;
  FloatC := 2.5;
  BoolFlag := True;
  MyStr := 'hello';
  Arr[0] := 100;
  Arr[1] := 200;
  Arr[2] := 300;
  Arr[3] := 400;
  Arr[4] := 500;
  WriteLn('Done');
end.
