program test_19_nested_scope;
{$mode objfpc}{$H+}

  procedure Foo;
  var
    SeenByBar: Integer;

    procedure Bar;
    var
      BarLocal: Integer;
    begin
      SeenByBar := 1;
      BarLocal := 2;
      WriteLn('[PROG] inside bar'); { sentinel }
    end;

  var
    NotSeenByBar: Integer;

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
