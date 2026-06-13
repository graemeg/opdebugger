program test_13_sets;

{ Set values render as bracketed member lists; the empty set as [].
  Port of the FPC suite's test_13 — sets and enums are dialect-neutral. }

type
  TDays = (Mon, Tue, Wed, Thu, Fri, Sat, Sun);
  TDaySet = set of TDays;

var
  WorkingDays: TDaySet;
  Weekend: TDaySet;
  EmptySet: TDaySet;
  Sentinel: Integer;   { dummy breakpoint target after all assignments }

begin
  WorkingDays := [Mon, Tue, Wed, Thu, Fri];
  Weekend := [Sat, Sun];
  EmptySet := [];
  Sentinel := 1;       { break here: all sets are assigned }
end.
