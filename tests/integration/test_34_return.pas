program test_34_return;

{$mode objfpc}{$H+}

procedure DoWork;
var
  LocalA: LongInt;
begin
  LocalA := 10;
  LocalA := 20;
  WriteLn('Inside DoWork');
end;

var
  MainVal: LongInt;

begin
  MainVal := 1;
  DoWork;
  MainVal := 2;
  WriteLn('Done');
end.
