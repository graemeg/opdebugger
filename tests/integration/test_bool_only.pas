program test_bool_only;
uses baseunix;
var
  B: Boolean;
begin
  B := True;
  WriteLn('Program running. PID: ', FpGetPID);
  ReadLn;
end.
