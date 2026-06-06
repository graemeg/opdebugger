program test_38_nested_fields;

type
  TPoint = record
    XPos: Integer;
    YPos: Integer;
  end;

  TRect = record
    TopLeft: TPoint;
    BottomRight: TPoint;
  end;

  TInner = class
  public
    Value: Integer;
    constructor Create(AValue: Integer);
  end;

  TOuter = class
  public
    Name: ShortString;
    Inner: TInner;
    constructor Create(AName: ShortString; AInner: TInner);
  end;

constructor TInner.Create(AValue: Integer);
begin
  Value := AValue;
end;

constructor TOuter.Create(AName: ShortString; AInner: TInner);
begin
  Name := AName;
  Inner := AInner;
end;

var
  Rect: TRect;
  Obj: TOuter;

begin
  Rect.TopLeft.XPos := 10;
  Rect.TopLeft.YPos := 20;
  Rect.BottomRight.XPos := 100;
  Rect.BottomRight.YPos := 200;

  Obj := TOuter.Create('MyOuter', TInner.Create(42));

  WriteLn('Done');

  Obj.Inner.Free;
  Obj.Free;
end.
