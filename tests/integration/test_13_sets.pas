program test_13_sets;

{$mode objfpc}{$H+}

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
  Sentinel := 1;       { break here: line 20, all sets are assigned }
end.
