program TeaserDemo;

{$mode objfpc}{$H+}

uses
  SysUtils;

type
  TDays = (Mon, Tue, Wed, Thu, Fri, Sat, Sun);
  TDaySet = set of TDays;
  // A non-zero based array using an Enum as an index
  TDayNames = array[TDays] of string;

  TTeaser = class
  private
    FData: string;
    function GetWrappedData: string;
  public
    constructor Create(const AValue: string);
    // 1. The "Holy Grail": A Property with a getter function
    property WrappedData: string read GetWrappedData;
  end;

constructor TTeaser.Create(const AValue: string);
begin
  FData := AValue;
end;

function TTeaser.GetWrappedData: string;
begin
  Result := '<<' + FData + '>>';
end;

procedure OuterProcedure;
var
  ParentVar: string;
  WorkingSet: TDaySet;
  Names: TDayNames;

  // 2. Nested Procedure accessing ParentVar (Static Link)
  procedure InnerNested;
  begin
    ParentVar := 'Modified by Nest';
    // DEBUG HERE: Can the debugger see ParentVar and WorkingSet?
    WriteLn(ParentVar);
  end;

begin
  ParentVar := 'Initial Value';
  WorkingSet := [Mon, Wed, Fri];

  // 3. Managed Types & 4. Non-zero Arrays
  Names[Mon] := 'Monday';
  Names[Tue] := 'Tuesday';

  InnerNested;
end;

var
  Obj: TTeaser;
begin
  Obj := TTeaser.Create('FPC Mystery');

  // DEBUG HERE: Try to "Watch" Obj.WrappedData
  WriteLn(Obj.WrappedData);

  OuterProcedure;

  Obj.Free;
end.
