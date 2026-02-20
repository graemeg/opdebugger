program test_01_primitives;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  SysUtils;

var
  MyGlobalInt: LongInt;
  MyBoolean: Boolean;
  Sentinel: Integer;

begin
  MyGlobalInt := 42;
  MyBoolean := True;

  WriteLn('Test Program: Primitives');
  WriteLn('PID: ', {$IFDEF UNIX}FpGetPID{$ELSE}GetCurrentProcessId{$ENDIF});
  WriteLn('[PROG] MyGlobalInt = ', MyGlobalInt);
  WriteLn('[PROG] MyBoolean = ', MyBoolean);
  WriteLn;
  WriteLn('Press Enter to continue (debugger can attach now)...');
  ReadLn;

  WriteLn('Program exiting.');
  Sentinel := 1;
end.
