program test_38_nested_fields;

{ Nested field drilldown: record-in-record (Rect.TopLeft.XPos) and
  class-with-record/class fields (Obj.Inner.Value).  Port of the FPC suite's
  test_38 (ShortString -> the Blaise string type). }

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
    Name: String;
    Inner: TInner;
    constructor Create(AName: String; AInner: TInner);
  end;

constructor TInner.Create(AValue: Integer);
begin
  Value := AValue;
end;

constructor TOuter.Create(AName: String; AInner: TInner);
begin
  Name := AName;
  Inner := AInner;
end;

var
  Rect: TRect;
  Obj: TOuter;
  Sentinel: Integer;

begin
  Rect.TopLeft.XPos := 10;
  Rect.TopLeft.YPos := 20;
  Rect.BottomRight.XPos := 100;
  Rect.BottomRight.YPos := 200;

  Obj := TOuter.Create('MyOuter', TInner.Create(42));

  Sentinel := 1;        { break here }

  Obj.Inner.Free;
  Obj.Free;
end.
