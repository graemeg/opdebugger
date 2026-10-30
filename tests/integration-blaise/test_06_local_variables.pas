program test_06_local_variables;

{ Local variables and function parameters are visible at a breakpoint inside
  the function.  Port of the FPC suite's test_06. }

function Calculate(A, B: Int): Int;
var
  Sum: Int;
  Product: Int;
begin
  Sum := A + B;
  Product := A * B;
  Result := Sum + Product;  { break here for locals }
end;

var
  X, Y, ResultValue: Int;
  Sentinel: Int;
begin
  X := 5;
  Y := 10;
  ResultValue := Calculate(X, Y);
  Sentinel := 1;
end.
