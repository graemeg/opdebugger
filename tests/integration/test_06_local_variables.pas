program test_06_local_variables;
{$mode objfpc}{$H+}

{ Test program for debugging local variables and function parameters }

function Calculate(A, B: Integer): Integer;
var
  Sum: Integer;
  Product: Integer;
begin
  Sum := A + B;
  Product := A * B;
  Result := Sum + Product;  { Breakpoint line for testing locals }
end;

var
  X, Y, ResultValue: Integer;
begin
  X := 5;
  Y := 10;
  ResultValue := Calculate(X, Y);
  WriteLn('Result = ', ResultValue);
  ReadLn;
end.
