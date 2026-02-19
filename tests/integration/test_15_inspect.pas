program test_15_inspect;
{$mode objfpc}{$H+}

{ Test program for 'inspect' command — shows structured type layout }

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
  Sentinel := 1;   { breakpoint here - line 19 }
end.
