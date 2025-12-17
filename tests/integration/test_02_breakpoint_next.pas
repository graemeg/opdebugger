program test_02_breakpoint_next;

{$mode objfpc}{$H+}

var
  MyInt: Integer;

begin
  WriteLn('Test: Breakpoint and Next');
  
  MyInt := 10;
  WriteLn('Set MyInt to 10');
  
  MyInt := 20;
  WriteLn('Set MyInt to 20');
  
  MyInt := 30;
  WriteLn('Set MyInt to 30');
  
  WriteLn('Done');
end.
