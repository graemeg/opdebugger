program test_18_inspect_class_intf;
{$mode objfpc}{$H+}
{$interfaces corba}

{ Test program for 'inspect' command — class and interface types }

type
  { A simple interface with two methods }
  ICounter = interface
    procedure Increment;
    function GetValue: Integer;
  end;

  { A class that implements ICounter }
  TSimpleCounter = class(TObject, ICounter)
  private
    FCount: Integer;
  public
    procedure Increment;
    function GetValue: Integer;
  end;

  { A simple class with a field and a property }
  TMyBox = class
  private
    FWidth: Integer;
    FHeight: Integer;
  public
    property Width: Integer read FWidth write FWidth;
    property Height: Integer read FHeight write FHeight;
  end;

procedure TSimpleCounter.Increment;
begin
  Inc(FCount);
end;

function TSimpleCounter.GetValue: Integer;
begin
  Result := FCount;
end;

var
  Box: TMyBox;
  Counter: ICounter;
  CounterObj: TSimpleCounter;
  Sentinel: Integer;

begin
  Box := TMyBox.Create;
  Box.FWidth := 30;
  Box.FHeight := 20;
  Counter := nil;
  Sentinel := 1;   { breakpoint here — Counter is nil }
  CounterObj := TSimpleCounter.Create;
  CounterObj.FCount := 42;
  Counter := CounterObj;
  Sentinel := 2;   { breakpoint here — Counter is non-nil }
  Box.Free;
  CounterObj.Free;
end.
