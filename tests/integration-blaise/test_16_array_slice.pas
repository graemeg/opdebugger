program test_16_array_slice;

{ Array slice display: print MyArray[N..M] shows a range of elements.
  Port of the FPC suite's test_16. }

var
  BigArray: array[0..9] of Integer;
  Sentinel: Integer;
  I: Integer;

begin
  for I := 0 to 9 do
    BigArray[I] := (I + 1) * 10;
  Sentinel := 1;                      { break here }
end.
