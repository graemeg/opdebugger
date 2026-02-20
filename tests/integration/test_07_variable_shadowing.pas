program test_07_variable_shadowing;
{$mode objfpc}{$H+}

{ Test variable shadowing: local variable should shadow global variable of same name }

var
  Counter: Integer;  // Global variable Counter = 100
  Sentinel: Integer;

procedure ModifyCounter;
var
  Counter: Integer;  // Local variable Counter = 42 (shadows global)
begin
  Counter := 42;
  WriteLn('Inside ModifyCounter, Counter = ', Counter);  // Should print 42
end;

procedure PrintOtherCounter;
var
  Counter: Integer;  // Another local Counter = 99 (shadows global)
begin
  Counter := 99;
  WriteLn('Inside PrintOtherCounter, Counter = ', Counter);  // Should print 99
end;

begin
  Counter := 100;  // Set global Counter to 100
  WriteLn('Global Counter = ', Counter);

  ModifyCounter;    // Call procedure with local Counter = 42
  WriteLn('After ModifyCounter, global Counter = ', Counter);  // Should still be 100

  PrintOtherCounter;  // Call another procedure with local Counter = 99
  WriteLn('After PrintOtherCounter, global Counter = ', Counter);  // Should still be 100

  ReadLn;
  Sentinel := 1;
end.
