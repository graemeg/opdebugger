program test_14_locals;
{$mode objfpc}{$H+}

{ Test program for 'locals' command — lists all in-scope variables }

var
  GlobalCount: Integer = 42;

function Compute(A, B: Integer): Integer;
var
  Sum: Integer;
  Product: Integer;
begin
  Sum := A + B;
  Product := A * B;
  Result := Sum + Product;  { breakpoint here — line 16 }
end;

begin
  WriteLn(Compute(3, 7));
  WriteLn(GlobalCount);
end.
