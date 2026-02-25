program test_20_conditional_break;

{$mode objfpc}{$H+}

var
  Iter: Integer;
  Sum: Integer;
begin
  Sum := 0;
  for Iter := 1 to 10 do
  begin
    Sum := Sum + Iter;         { line 12: breakpoint target inside loop }
  end;
  WriteLn('[PROG] Final sum: ', Sum);
end.
