program test_25_constants;

{$mode objfpc}{$H+}

{ Test: compile-time constant display via 'print' command.
  Covers: constord (Integer, Boolean, Char), constreal, conststring. }

const
  MaxItems    = 100;
  Enabled     = True;
  InitialChar = 'A';
  PiApprox    = 3.14159;
  AppTitle    = 'Hello Debug';
  rocketUTF8  = #$F0#$9F#$9A#$80;

var
  Sentinel: Integer;

begin
  Sentinel := 1;        { breakpoint target }
  Sentinel := Sentinel + 1;
end.
