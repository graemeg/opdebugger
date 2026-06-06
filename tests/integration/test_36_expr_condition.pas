program test_36_expr_condition;

var
  Idx: Integer;
  Total: Integer;

begin
  Total := 0;
  for Idx := 1 to 10 do
  begin
    Total := Total + Idx;
  end;
  WriteLn('Total = ', Total);
end.
