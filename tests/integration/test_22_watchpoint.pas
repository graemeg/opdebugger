program test_22_watchpoint;

{$mode objfpc}{$H+}

var
  Counter: Integer;
  Sentinel: Integer;
begin
  Counter := 0;
  Sentinel := 1;       { line 10: breakpoint here, after Counter assigned }
  Counter := 10;        { watchpoint fires here }
  Counter := 20;        { watchpoint fires again }
  WriteLn('[PROG] Done');
end.
