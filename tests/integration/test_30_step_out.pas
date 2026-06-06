program test_30_step_out;

{ finish (step-out) inside a called function must return to the caller's
  next line after the call. }

function Double(N: Integer): Integer;
begin
  Result := N * 2;  { line 8: we will be here via step-into }
end;

var
  Value, Doubled: Integer;

begin
  Value := 21;
  Doubled := Double(Value);  { line 16: break here, step in }
  WriteLn(Doubled);          { line 17: finish should land here }
end.
