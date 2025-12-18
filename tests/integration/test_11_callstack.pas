program test_11_callstack;
{$mode objfpc}{$H+}

{ Test call stack walking }

uses
  SysUtils;

procedure Level3;
begin
  WriteLn('In Level3');
  ReadLn;  { Breakpoint here }
end;

procedure Level2;
begin
  WriteLn('In Level2');
  Level3;
end;

procedure Level1;
begin
  WriteLn('In Level1');
  Level2;
end;

var
  X, Y: Integer;

begin
  WriteLn('Call Stack Test');
  X := 10;
  Y := 20;
  Level1;
  WriteLn('Done');
  ReadLn;
end.
