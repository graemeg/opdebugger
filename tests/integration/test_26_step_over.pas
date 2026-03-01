program test_26_step_over;

{ Step-over (next) must NOT enter SetResult; must land on the WriteLn line.
  SetResult body is at higher line numbers than the call site, which tests
  that step-over uses function scope (address range) rather than line numbers. }

{$mode objfpc}{$H+}

procedure SetResult(var N: Integer; V: Integer);
begin
  N := V;
end;

var
  Counter: Integer;

begin
  Counter := 0;
  SetResult(Counter, 99);   { line 19 - break here, then next }
  WriteLn(Counter);          { line 20 - should land here }
end.
