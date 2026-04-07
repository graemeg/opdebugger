program test_28_anon_sets;

{$mode objfpc}{$H+}

{ Regression test: two anonymous sets of two anonymous enums.
  Verifies that the OPDF type mapper allocates distinct TypeIDs
  for each anonymous set type, and that the correct anonymous
  enum is used to render each set's members.

  Bug history: TTypeMapper.GetTypeID hashed by GetTypeName for
  anonymous types, causing "Set Of <enumeration type>" to collide
  for any two anonymous sets, and making the second set's members
  render against the first set's enum. }

var
  SetOne: set of (sa1, sa2, sa3, sa4);
  SetTwo: set of (sb1=2, sb2=8, sb3=44, sb4=55);
  Sentinel: Integer;
begin
  SetOne := [sa1, sa2];
  SetTwo := [sb1, sb2];
  Sentinel := 1;
end.
