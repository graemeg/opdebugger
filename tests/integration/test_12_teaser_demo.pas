program test_12_teaser_demo;

{$mode objfpc}{$H+}

{ Teaser Demo — demonstrates nested scope variable access, class inspection,
  and enum-indexed arrays. This mirrors the original TeaserDemo.pas scenario. }

uses
  SysUtils;

type
  TDays = (Mon, Tue, Wed, Thu, Fri, Sat, Sun);

  TTeaser = class
  private
    FData: string;
    FDay: TDays;
  public
    constructor Create(const AValue: string; ADay: TDays);
  end;

constructor TTeaser.Create(const AValue: string; ADay: TDays);
begin
  FData := AValue;
  FDay := ADay;
end;

procedure OuterProcedure;
var
  ParentVar: string;
  Counter: Integer;

  { Nested procedure that accesses ParentVar from the enclosing scope }
  procedure InnerNested;
  begin
    ParentVar := 'Modified by InnerNested';
    Inc(Counter);
    WriteLn('[PROG] InnerNested: Counter=', Counter);
    { Breakpoint here to test nested scope access }
  end;

begin
  ParentVar := 'Initial Value';
  Counter := 0;
  InnerNested;
end;

var
  Obj: TTeaser;
begin
  Obj := TTeaser.Create('FPC Mystery', Wed);
  WriteLn('[PROG] Obj.FData=', Obj.FData);
  OuterProcedure;
  Obj.Free;
end.
