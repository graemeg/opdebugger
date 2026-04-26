program test_29_class_var;

{$mode objfpc}{$H+}

type
  TCounter = class
    Total: Integer; static;     // static field modifier syntax
    class var Count: Integer;   // class var block syntax (equivalent)
    const MaxCount = 50;
    procedure Increment;
  end;

procedure TCounter.Increment;
begin
  Count := Count + 1;
  Total := Total + 10;
end;

var
  C: TCounter;
begin
  C := TCounter.Create;
  TCounter.Count := 42;
  TCounter.Total := 100;
  C.Increment;
  WriteLn('done');
  C.Free;
end.
