program test_19_nested_scope;

{ Nested-procedure scoping: 'locals scoped' in Bar sees Bar's own locals and
  the enclosing Foo local it references (SeenByBar), but not Foo's other local
  (NotSeenByBar).  Port of the FPC suite's test_19. }

  procedure Foo;
  var
    SeenByBar: Int;

    procedure Bar;
    var
      BarLocal: Int;
    begin
      SeenByBar := 1;
      BarLocal := 2;
      WriteLn('[PROG] inside bar'); { sentinel }
    end;

  var
    NotSeenByBar: Int;

  begin
    SeenByBar := 99;
    NotSeenByBar := 99;
    Bar();
    WriteLn('[PROG] after bar'); { sentinel }
  end;

begin
  WriteLn('[PROG] running test');
  Foo();
  WriteLn('[PROG] done');
end.
