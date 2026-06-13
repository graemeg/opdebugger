program test_26_step_over;

{ Step-over (next) must NOT enter SetResult; must land on the WriteLn line.
  SetResult body is at higher line numbers than the call site, which tests
  that step-over uses function scope (address range) rather than line numbers.
  Port of the FPC suite's test_26 — feature-agnostic. }

procedure SetResult(var N: Integer; V: Integer);
begin
  N := V;
end;

var
  Counter: Integer;

begin
  Counter := 0;
  SetResult(Counter, 99);   { break here, then next }
  WriteLn(Counter);          { next should land here }
end.
