program test_08_static_arrays;
{$mode objfpc}{$H+}

{ Test static arrays with fixed bounds }

var
  IntArray: array[0..4] of Integer;
  CharArray: array[1..3] of Char;
  StringArray: array[0..2] of String;
  TwoDArray: array[0..1, 0..2] of Integer;
  Sentinel: Integer;

begin
  { Initialize integer array }
  IntArray[0] := 10;
  IntArray[1] := 20;
  IntArray[2] := 30;
  IntArray[3] := 40;
  IntArray[4] := 50;

  { Initialize character array }
  CharArray[1] := 'A';
  CharArray[2] := 'B';
  CharArray[3] := 'C';

  { Initialize string array }
  StringArray[0] := 'Hello';
  StringArray[1] := 'World';
  StringArray[2] := 'Array';

  { Initialize 2D array }
  TwoDArray[0, 0] := 1;
  TwoDArray[0, 1] := 2;
  TwoDArray[0, 2] := 3;
  TwoDArray[1, 0] := 4;
  TwoDArray[1, 1] := 5;
  TwoDArray[1, 2] := 6;

  WriteLn('Arrays initialized');  { Breakpoint here: line 38 }
  ReadLn;
  Sentinel := 1;
end.
