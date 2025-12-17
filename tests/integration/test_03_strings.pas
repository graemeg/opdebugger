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
  MyUnicodeString: UnicodeString;
  MyWideString: WideString;
  EmptyShort: String[10];
  EmptyAnsi: AnsiString;
  EmptyUnicode: UnicodeString;
  EmptyWide: WideString;

begin
  WriteLn('Test Program: String Types');
  WriteLn('PID: ', {$IFDEF UNIX}FpGetPID{$ELSE}GetCurrentProcessId{$ENDIF});
  WriteLn;

  MyShortString := 'Hello';
  MyAnsiString := 'World';
  MyUnicodeString := 'Unicode';
  MyWideString := 'Wide';
  EmptyShort := '';
  EmptyAnsi := '';
  EmptyUnicode := '';
  EmptyWide := '';  // <-- Breakpoint will be here (line 33)

  WriteLn('Press Enter to continue...');
  ReadLn;

  WriteLn('Program exiting.');
end.
