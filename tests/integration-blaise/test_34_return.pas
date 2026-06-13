program test_34_return;

{ 'return' forces the current function to return immediately; execution
  resumes at the caller's line after the call.  Port of the FPC suite's
  test_34 (LongInt -> Integer for the Blaise dialect). }

procedure DoWork;
var
  LocalA: Integer;
begin
  LocalA := 10;
  LocalA := 20;
  WriteLn('Inside DoWork');
end;

var
  MainVal: Integer;

begin
  MainVal := 1;
  DoWork;
  MainVal := 2;
  WriteLn('Done');
end.
