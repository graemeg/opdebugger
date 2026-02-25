program test_21_display;

{$mode objfpc}{$H+}

var
  Iter: Integer;
  Sum: Integer;
begin
  Sum := 0;
  for Iter := 1 to 5 do
  begin
    Sum := Sum + Iter;         { line 12: breakpoint target inside loop }
  end;
  WriteLn('[PROG] Final sum: ', Sum);
end.
