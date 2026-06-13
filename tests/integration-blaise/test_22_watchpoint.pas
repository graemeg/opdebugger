program test_22_watchpoint;

{ A watchpoint fires when the watched variable changes.
  Port of the FPC suite's test_22. }

var
  Counter: Integer;
  Sentinel: Integer;
begin
  Counter := 0;
  Sentinel := 1;       { break here, after Counter assigned }
  Counter := 10;        { watchpoint fires }
  Counter := 20;        { watchpoint fires again }
  WriteLn('[PROG] Done');
end.
