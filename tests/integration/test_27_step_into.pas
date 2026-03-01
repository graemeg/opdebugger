program test_27_step_into;

{ step (step-into) at the Triple call must descend into Triple's body,
  not stay on the current line. }

function Triple(N: Integer): Integer;
begin
  Result := N * 3;
end;

var
  Value, Tripled: Integer;

begin
  Value := 7;
  Tripled := Triple(Value);
  WriteLn(Tripled);
end.
