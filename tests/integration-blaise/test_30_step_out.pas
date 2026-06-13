program test_30_step_out;

{ finish (step-out) inside a called function must return to the caller's
  next line after the call.  Port of the FPC suite's test_30. }

function Twice(N: Integer): Integer;
begin
  Result := N * 2;
end;

var
  Value, Doubled: Integer;

begin
  Value := 21;
  Doubled := Twice(Value);  { break here, step in }
  WriteLn(Doubled);          { finish should land here }
end.
