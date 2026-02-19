program test_16_array_slice;
{$mode objfpc}{$H+}

{ Test program for array slice display: print MyArray[N..M] }

var
  BigArray: array[0..9] of Integer;
  Sentinel: Integer;
  I: Integer;

begin
  for I := 0 to 9 do
    BigArray[I] := (I + 1) * 10;     { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 }
  Sentinel := 1;                      { breakpoint here - line 14 }
end.
