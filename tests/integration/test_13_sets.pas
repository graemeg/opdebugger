program test_13_sets;

{$mode objfpc}{$H+}

type
  TDays = (Mon, Tue, Wed, Thu, Fri, Sat, Sun);
  TDaySet = set of TDays;

var
  WorkingDays: TDaySet;
  Weekend: TDaySet;
  EmptySet: TDaySet;

begin
  WorkingDays := [Mon, Tue, Wed, Thu, Fri];
  Weekend := [Sat, Sun];
  EmptySet := [];
  WriteLn('[PROG] WorkingDays set test');
  WriteLn('[PROG] Done');
end.
