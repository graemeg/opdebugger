program test_10_arguments;
{$mode objfpc}{$H+}

{ Test command-line argument passing }

uses
  SysUtils;

var
  I: Integer;
  AllArgs: String;

begin
  WriteLn('Program received ', ParamCount, ' arguments:');

  { Print all arguments }
  AllArgs := '';
  for I := 1 to ParamCount do
  begin
    WriteLn('  Arg[', I, ']: ', ParamStr(I));
    if I > 1 then
      AllArgs := AllArgs + ' ';
    AllArgs := AllArgs + ParamStr(I);
  end;

  WriteLn;
  WriteLn('Combined arguments: ', AllArgs);
  WriteLn;
  WriteLn('Argument processing complete');  { Breakpoint here: line 28 }
  ReadLn;
end.
