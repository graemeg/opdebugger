program test_11_callstack;

{ Call-stack walking: break in the deepest frame and verify the callstack
  names each caller with its line.  Port of the FPC suite's test_11 — the
  interactive ReadLn calls (used there to hold the process) are replaced
  with sentinel assignments, since the harness drives pdr non-interactively. }

procedure Level3;
var
  Marker: Integer;
begin
  WriteLn('In Level3');
  Marker := 1;   { break here }
end;

procedure Level2;
begin
  WriteLn('In Level2');
  Level3;
end;

procedure Level1;
begin
  WriteLn('In Level1');
  Level2;
end;

var
  X, Y: Integer;
  Sentinel: Integer;

begin
  WriteLn('Call Stack Test');
  X := 10;
  Y := 20;
  Level1;
  WriteLn('Done');
  Sentinel := 1;
end.
