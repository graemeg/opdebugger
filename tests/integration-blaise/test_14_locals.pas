program test_14_locals;

{ The 'locals' command lists all in-scope variables at a breakpoint.
  Port of the FPC suite's test_14. }

var
  GlobalCount: Int;
  Sentinel: Int;

function Compute(A, B: Int): Int;
var
  Sum: Int;
  Product: Int;
begin
  Sum := A + B;
  Product := A * B;
  Result := Sum + Product;  { break here for locals }
end;

begin
  GlobalCount := 42;
  WriteLn(Compute(3, 7));
  WriteLn(GlobalCount);
  Sentinel := 1;
end.
