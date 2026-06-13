program test_21_display;

{ 'display' re-evaluates expressions each time the program stops.
  Port of the FPC suite's test_21. }

var
  Iter: Integer;
  Sum: Integer;
begin
  Sum := 0;
  for Iter := 1 to 5 do
  begin
    Sum := Sum + Iter;         { break target inside loop }
  end;
  WriteLn('[PROG] Final sum: ', Sum);
end.
