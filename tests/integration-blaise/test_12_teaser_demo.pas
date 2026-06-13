program test_12_teaser_demo;

{ Nested-scope variable access: a nested procedure modifies an enclosing
  local, visible at a breakpoint inside the nested proc.  Port of the FPC
  suite's test_12 (trimmed to the nested-scope assertion). }

type
  TDays = (Mon, Tue, Wed, Thu, Fri, Sat, Sun);

  TTeaser = class
  private
    FData: String;
    FDay: TDays;
  public
    constructor Create(const AValue: String; ADay: TDays);
  end;

constructor TTeaser.Create(const AValue: String; ADay: TDays);
begin
  FData := AValue;
  FDay := ADay;
end;

procedure OuterProcedure;
var
  ParentVar: String;
  Counter: Integer;

  procedure InnerNested;
  begin
    ParentVar := 'Modified by InnerNested';
    Inc(Counter);
    WriteLn('[PROG] InnerNested: Counter=', Counter);  { break here }
  end;

begin
  ParentVar := 'Initial Value';
  Counter := 0;
  InnerNested;
end;

var
  Obj: TTeaser;
  Sentinel: Integer;
begin
  Obj := TTeaser.Create('Mystery', Wed);
  OuterProcedure;
  Obj.Free;
  Sentinel := 1;
end.
