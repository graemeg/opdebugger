program test_34_return;

{ 'return' forces the current function to return immediately; execution
  resumes at the caller's line after the call.  Port of the FPC suite's
  test_34 (LongInt -> Int for the Blaise dialect). }

procedure DoWork;
var
  LocalA: Int;
begin
  LocalA := 10;
  LocalA := 20;
  WriteLn('Inside DoWork');
end;

var
  MainVal: Int;

begin
  MainVal := 1;
  DoWork();
  MainVal := 2;
  WriteLn('Done');
end.
