program test_09_dynamic_arrays;
{$mode objfpc}{$H+}

{ Test dynamic arrays with runtime-determined length }

var
  DynIntArray: array of Integer;
  DynStringArray: array of String;
  NilArray: array of Integer;

begin
  { Create and initialize dynamic integer array }
  SetLength(DynIntArray, 5);
  DynIntArray[0] := 100;
  DynIntArray[1] := 200;
  DynIntArray[2] := 300;
  DynIntArray[3] := 400;
  DynIntArray[4] := 500;

  { Create and initialize dynamic string array }
  SetLength(DynStringArray, 3);
  DynStringArray[0] := 'First';
  DynStringArray[1] := 'Second';
  DynStringArray[2] := 'Third';

  { Leave NilArray as nil }

  WriteLn('Dynamic arrays initialized');  { Breakpoint here: line 28 }
  ReadLn;
end.
