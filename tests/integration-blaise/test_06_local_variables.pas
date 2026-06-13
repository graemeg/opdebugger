program test_06_local_variables;

{ Local variables and function parameters are visible at a breakpoint inside
  the function.  Port of the FPC suite's test_06. }

function Calculate(A, B: Integer): Integer;
var
  Sum: Integer;
  Product: Integer;
begin
  Sum := A + B;
  Product := A * B;
  Result := Sum + Product;  { break here for locals }
end;

var
  X, Y, ResultValue: Integer;
  Sentinel: Integer;
begin
  X := 5;
  Y := 10;
  ResultValue := Calculate(X, Y);
  Sentinel := 1;
end.
