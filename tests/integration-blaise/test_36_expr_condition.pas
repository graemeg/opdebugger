program test_36_expr_condition;

{ Conditional breakpoints with expressions, and 'condition' to change one.
  Port of the FPC suite's test_36. }

var
  Idx: Integer;
  Total: Integer;

begin
  Total := 0;
  for Idx := 1 to 10 do
  begin
    Total := Total + Idx;          { break target }
  end;
  WriteLn('Total = ', Total);
end.
