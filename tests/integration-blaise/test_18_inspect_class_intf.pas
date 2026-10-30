program test_18_inspect_class_intf;

{ 'inspect' on a class shows fields (with offsets), properties, and methods;
  an interface variable shows nil or its pointer.  Port of the FPC suite's
  test_18 (Blaise interfaces are CORBA-style natively — no directive needed). }

type
  ICounter = interface
    procedure Increment;
    function GetValue: Int;
  end;

  TSimpleCounter = class(TObject, ICounter)
  private
    FCount: Int;
  public
    procedure Increment;
    function GetValue: Int;
  end;

  TMyBox = class
  private
    FWidth: Int32;
    FHeight: Int32;
  public
    property Width: Int32 read FWidth write FWidth;
    property Height: Int32 read FHeight write FHeight;
  end;

procedure TSimpleCounter.Increment;
begin
  Inc(FCount);
end;

function TSimpleCounter.GetValue: Int;
begin
  Result := FCount;
end;

var
  Box: TMyBox;
  Counter: ICounter;
  CounterObj: TSimpleCounter;
  Sentinel: Int;

begin
  Box := TMyBox.Create;
  Box.FWidth := 30;
  Box.FHeight := 20;
  Counter := nil;
  Sentinel := 1;   { break here: Counter is nil }
  CounterObj := TSimpleCounter.Create;
  CounterObj.FCount := 42;
  Counter := CounterObj;
  Sentinel := 2;   { break here: Counter is non-nil }
  Box.Free();
  CounterObj.Free();
end.
