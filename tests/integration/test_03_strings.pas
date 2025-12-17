program test_03_strings;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  SysUtils;

var
  MyShortString: String[20];
  MyAnsiString: AnsiString;
  EmptyShort: String[10];
  EmptyAnsi: AnsiString;

begin
  WriteLn('Test Program: String Types');
  WriteLn('PID: ', {$IFDEF UNIX}FpGetPID{$ELSE}GetCurrentProcessId{$ENDIF});
  WriteLn;

  MyShortString := 'Hello';
  MyAnsiString := 'World';
  EmptyShort := '';
  EmptyAnsi := '';

  WriteLn('MyShortString = ', MyShortString);
  WriteLn('MyAnsiString = ', MyAnsiString);
  WriteLn('EmptyShort = ', EmptyShort);
  WriteLn('EmptyAnsi = ', EmptyAnsi);
  WriteLn;

  WriteLn('Press Enter to continue...');
  ReadLn;

  WriteLn('Program exiting.');
end.
