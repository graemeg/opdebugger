program test_01_open_array;

{ Open-array parameter debug-info regression test.

  An open array is a (data ptr, high index) pair on the stack with no heap
  header.  pdr must read its length from the companion '_high' slot, NOT from
  data-4 (which would yield garbage).  This is a Blaise extension to OPDF —
  FPC's dbgopdf.pas cannot emit it, which is why this test lives in the
  Blaise suite.

  Variable names are deliberately multi-character: the shared output filter
  in run_tests.sh drops single-letter names (to skip incidental WriteLn
  output), so 'a'/'b' would be filtered away. }

type
  TIntArray = array of Integer;

procedure Bar(OpenArr: array of Integer; DynArr: TIntArray);
begin
  WriteLn(OpenArr[1]);   { break here: OpenArr (open) and DynArr (dynamic) are live }
end;

var
  Data: TIntArray;
begin
  SetLength(Data, 3);
  Data[0] := 1;
  Data[1] := 2;
  Data[2] := 3;
  Bar([1, 2, 3], Data);
end.
