program test_32_frame_navigation;

procedure Inner(X: Integer);
var
  LocalInner: Integer;
begin
  LocalInner := X * 3;
  WriteLn(LocalInner);  { line 8: break here }
end;

procedure Outer(Y: Integer);
var
  LocalOuter: Integer;
begin
  LocalOuter := Y + 10;
  Inner(LocalOuter);    { line 16 }
end;

begin
  Outer(5);             { line 20 }
end.
