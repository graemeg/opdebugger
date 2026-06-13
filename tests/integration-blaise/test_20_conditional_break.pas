program test_20_conditional_break;

{ Conditional breakpoint with a hit count: 'break ... if count=7' stops on the
  7th hit of the loop body.  Port of the FPC suite's test_20. }

var
  Iter: Integer;
  Sum: Integer;
begin
  Sum := 0;
  for Iter := 1 to 10 do
  begin
    Sum := Sum + Iter;         { breakpoint target inside loop }
  end;
  WriteLn('[PROG] Final sum: ', Sum);
end.
