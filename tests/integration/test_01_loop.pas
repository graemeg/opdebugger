program test_01_loop;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  SysUtils;

var
  MyGlobalInt: LongInt;
  MyBoolean: Boolean;
  Counter: Integer;

begin
  MyGlobalInt := 42;
  MyBoolean := True;

  WriteLn('Test Program: Primitives (Looping)');
  WriteLn('PID: ', {$IFDEF UNIX}FpGetPID{$ELSE}GetCurrentProcessId{$ENDIF});
  WriteLn('MyGlobalInt = ', MyGlobalInt);
  WriteLn('MyBoolean = ', MyBoolean);
  WriteLn;
  WriteLn('Looping indefinitely (use debugger to attach)...');
  WriteLn;

  Counter := 0;
  while True do
  begin
    Inc(Counter);
    if (Counter mod 100000000) = 0 then
      WriteLn('Still running... Counter = ', Counter);
  end;
end.
