program test_37_bp_commands;

var
  Idx: Integer;
  Total: Integer;

begin
  Total := 0;
  for Idx := 1 to 5 do
  begin
    Total := Total + Idx;
  end;
  WriteLn('Done: Total = ', Total);
end.
