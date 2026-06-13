program test_15_inspect;

{ The 'inspect' command shows a record's structured layout: each field with
  its value and byte offset.  Port of the FPC suite's test_15. }

type
  TMyPoint = record
    PX: Integer;
    PY: Integer;
  end;

var
  MyPt: TMyPoint;
  Sentinel: Integer;

begin
  MyPt.PX := 100;
  MyPt.PY := 200;
  Sentinel := 1;   { break here }
end.
