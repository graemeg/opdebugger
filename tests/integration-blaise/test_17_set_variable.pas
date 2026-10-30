program test_17_set_variable;

{ The 'set' command modifies a variable's value in the running process.
  Port of the FPC suite's test_17. }

var
  Counter: Int;
  MyFlag: Boolean;
  Sentinel: Int;

begin
  Counter := 5;
  MyFlag := False;
  Sentinel := 1;        { break here }
end.
