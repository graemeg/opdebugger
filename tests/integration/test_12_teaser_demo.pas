program test_12_teaser_demo;

{$mode objfpc}{$H+}

{ Teaser Demo - showcases class instance inspection and enum variable display }

uses
  SysUtils;

type
  TDays = (Mon, Tue, Wed, Thu, Fri, Sat, Sun);

  TTeaser = class
  private
    FData: string;
    FCount: Integer;
    FDay: TDays;
  public
    constructor Create(const AValue: string; ACount: Integer; ADay: TDays);
  end;

constructor TTeaser.Create(const AValue: string; ACount: Integer; ADay: TDays);
begin
  FData := AValue;
  FCount := ACount;
  FDay := ADay;
end;

var
  Obj: TTeaser;
  Today: TDays;
begin
  Obj := TTeaser.Create('FPC Mystery', 42, Wed);
  Today := Fri;
  WriteLn('Teaser Demo running');  { Breakpoint at next line }
  WriteLn('Done');
  Obj.Free;
end.
