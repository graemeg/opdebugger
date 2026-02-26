program test_24_method_properties;

{$mode objfpc}{$H+}

type
  TMyClass = class
  private
    FName: AnsiString;
    FAge: Integer;
    function GetName: AnsiString;
    function GetAge: Integer;
  public
    property Name: AnsiString read GetName;
    property Age: Integer read GetAge;
  end;

function TMyClass.GetName: AnsiString;
begin
  Result := FName;
end;

function TMyClass.GetAge: Integer;
begin
  Result := FAge;
end;

var
  Obj: TMyClass;
  Sentinel: Integer;

begin
  Obj := TMyClass.Create;
  Obj.FName := 'Alice';
  Obj.FAge := 30;
  WriteLn('[PROG] ready');
  Obj.Free;
  Sentinel := 1;
end.
