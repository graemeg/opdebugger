program test_28_anon_sets;

{ Two distinct sets of distinct enums must get distinct TypeIDs, and each set
  must render against its own enum (an OPDF type-mapper regression test).
  Port of the FPC suite's test_28.  Blaise requires set types to be named in
  the type section (no inline 'set of' in a var, no inline anonymous enums),
  so the enums and set types are named here — the type-distinctness property
  under test is unchanged. }

type
  TEnumA = (sa1, sa2, sa3, sa4);
  TEnumB = (sb1, sb2, sb3, sb4);
  TSetA = set of TEnumA;
  TSetB = set of TEnumB;

var
  SetOne: TSetA;
  SetTwo: TSetB;
  Sentinel: Integer;
begin
  SetOne := [sa1, sa2];
  SetTwo := [sb1, sb2];
  Sentinel := 1;        { break here }
end.
