program test_18_inspect_class_intf;
{$mode objfpc}{$H+}

{ Test program for 'inspect' command — class and interface types }

type
  { A simple interface with two methods }
  ICounter = interface
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

var
  Box: TMyBox;
  Counter: ICounter;  { nil - we just want the type info }
  Sentinel: Integer;

begin
  Box := TMyBox.Create;
  Box.FWidth := 30;
  Box.FHeight := 20;
  Counter := nil;
  Sentinel := 1;   { breakpoint here - line 33 }
  Box.Free;
end.
