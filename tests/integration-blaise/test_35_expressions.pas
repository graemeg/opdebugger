program test_35_expressions;

{ The expression evaluator handles arithmetic, comparison, boolean, bit-shift,
  subscript, and built-in calls in 'print'.  Port of the FPC suite's test_35
  (LongInt -> Integer, AnsiString -> String). }

var
  IntA: Integer;
  IntB: Integer;
  FloatC: Double;
  BoolFlag: Boolean;
  MyStr: String;
  Arr: array[0..4] of Integer;

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
  WriteLn('Done');   { break here }
end.
