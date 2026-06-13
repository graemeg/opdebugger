program test_07_variable_shadowing;

{ A local variable shadows a global of the same name; the debugger resolves
  the in-scope (local) one at a breakpoint inside each procedure.  Port of the
  FPC suite's test_07. }

var
  Counter: Integer;  // global Counter
  Sentinel: Integer;

procedure ModifyCounter;
var
  Counter: Integer;  // local, shadows global
begin
  Counter := 42;
  WriteLn('Inside ModifyCounter, Counter = ', Counter);  { break here: 42 }
end;

procedure PrintOtherCounter;
var
  Counter: Integer;  // local, shadows global
begin
  Counter := 99;
  WriteLn('Inside PrintOtherCounter, Counter = ', Counter);  { break here: 99 }
end;

begin
  Counter := 100;
  WriteLn('Global Counter = ', Counter);
  ModifyCounter;
  WriteLn('After ModifyCounter, global Counter = ', Counter);
  PrintOtherCounter;
  WriteLn('After PrintOtherCounter, global Counter = ', Counter);
  Sentinel := 1;
end.
