program test_08_static_arrays;

{ Static arrays render with their bounds and element type, including
  multi-dimensional arrays (which desugar to nested 'array of array').
  Port of the FPC suite's test_08, adapted to the Blaise type system:
  one UTF-8 string type, 0-based; the FPC 'array of Char' case is dropped
  (Blaise has no array-of-Char type — character data is the string type). }

var
  IntArray: array[0..4] of Integer;
  StringArray: array[0..2] of String;
  TwoDArray: array[0..1, 0..2] of Integer;
  Sentinel: Integer;

begin
  IntArray[0] := 10;
  IntArray[1] := 20;
  IntArray[2] := 30;
  IntArray[3] := 40;
  IntArray[4] := 50;

  StringArray[0] := 'Hello';
  StringArray[1] := 'World';
  StringArray[2] := 'Array';

  TwoDArray[0, 0] := 1;
  TwoDArray[0, 1] := 2;
  TwoDArray[0, 2] := 3;
  TwoDArray[1, 0] := 4;
  TwoDArray[1, 1] := 5;
  TwoDArray[1, 2] := 6;

  Sentinel := 1;   { break here: all arrays initialised }
end.
