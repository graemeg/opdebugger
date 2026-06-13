program test_09_dynamic_arrays;

{ Dynamic arrays render with their runtime length; a nil array renders as nil.
  Port of the FPC suite's test_09 (Blaise type system: one UTF-8 string type). }

var
  DynIntArray: array of Integer;
  DynStringArray: array of String;
  NilArray: array of Integer;
  Sentinel: Integer;

begin
  SetLength(DynIntArray, 5);
  DynIntArray[0] := 100;
  DynIntArray[1] := 200;
  DynIntArray[2] := 300;
  DynIntArray[3] := 400;
  DynIntArray[4] := 500;

  SetLength(DynStringArray, 3);
  DynStringArray[0] := 'First';
  DynStringArray[1] := 'Second';
  DynStringArray[2] := 'Third';

  { NilArray is left nil }

  Sentinel := 1;   { break here: dynamic arrays initialised }
end.
