program test_40_large_frame;

{ Locals more than 32 KiB below the frame pointer, and a string constant
  longer than 64 KiB.  OPDF once held a frame offset and a constant's value
  length in 2 bytes: Marker was read from a truncated offset, and the long
  constant's length wrapped so its value bytes were taken as its name. }

const
  Big   = {$EMBEDSTR 'test_40_large_frame.txt'};
  Short = 'after';

procedure Probe;
var
  Pad:    array[0..49999] of Byte;
  Marker: Int32;
  Tail:   Int32;
begin
  Pad[0] := 1;
  Marker := 4242;
  Tail := Marker + Pad[0];
  WriteLn(Tail);
end;

begin
  Probe();
  WriteLn(Length(Big), ' ', Short);
end.
