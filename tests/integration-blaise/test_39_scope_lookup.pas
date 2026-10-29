program test_39_scope_lookup;

{ Name lookup across scopes.  Blaise links a nested routine to its enclosing
  one (OPDF_FLAG_SCOPE_PARENT), so a name not local to the stopped routine is
  looked up in the real parent, then the globals -- never in an unrelated
  routine that happens to hold a local of the same name (Other.Counter).
  Each unit's OPDF block numbers its scopes from 1, so `locals` in Other
  lists Other's own local only, not those of every unit's scope 1. }

uses Classes;

procedure Other;
var Counter: Integer;
begin
  Counter := 7;
  WriteLn('[PROG] other ', Counter);
end;

procedure Outer;
var
  Captured: Integer;
  Uncaptured: Integer;

  procedure Inner;
  begin
    WriteLn('[PROG] inner ', Captured); { sentinel }
  end;

begin
  Captured := 42;
  Uncaptured := 5;
  Inner();
end;

var
  Counter: Integer;
  SL: TStringList;
begin
  Counter := 99;
  SL := TStringList.Create();
  SL.Add('alpha');
  Other();
  Outer();
  WriteLn('[PROG] done ', Counter, SL.Count); { sentinel }
end.
