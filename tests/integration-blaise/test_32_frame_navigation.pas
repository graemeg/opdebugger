program test_32_frame_navigation;

procedure Inner(X: Int);
var
  LocalInner: Int;
begin
  LocalInner := X * 3;
  WriteLn(LocalInner);  { line 8: break here }
end;

procedure Outer(Y: Int);
var
  LocalOuter: Int;
begin
  LocalOuter := Y + 10;
  Inner(LocalOuter);    { line 16 }
end;

begin
  Outer(5);             { line 20 }
end.
