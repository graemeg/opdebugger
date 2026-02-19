program test_17_set_variable;
{$mode objfpc}{$H+}

{ Test program for 'set' command — modifies variable values in-process }

var
  Counter: Integer;
  MyFlag: Boolean;
  Sentinel: Integer;

begin
  Counter := 5;
  MyFlag := False;
  Sentinel := 1;        { breakpoint here - line 13 }
end.
