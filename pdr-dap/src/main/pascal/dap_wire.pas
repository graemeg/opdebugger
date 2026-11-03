{
  PDR Debugger - Debug Adapter Protocol framing

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  DAP messages are JSON bodies preceded by a "Content-Length: N" header
  and a blank line (CRLF CRLF).  Other headers are ignored.
}
unit dap_wire;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ Read one message body; False at end of stream (or a malformed header). }
function ReadDapMessage(AStream: TStream; out ABody: String): Boolean;
procedure WriteDapMessage(AStream: TStream; const ABody: String);

implementation

function ReadHeaderLine(AStream: TStream; out ALine: String): Boolean;
var
  C: Char;
begin
  ALine := '';
  Result := False;
  while AStream.Read(C, 1) = 1 do
  begin
    if C = #10 then
    begin
      if (Length(ALine) > 0) and (ALine[Length(ALine)] = #13) then
        SetLength(ALine, Length(ALine) - 1);
      Exit(True);
    end;
    ALine := ALine + C;
  end;
end;

function ReadDapMessage(AStream: TStream; out ABody: String): Boolean;
var
  Line: String;
  Len, Got, N: Integer;
begin
  ABody := '';
  Len := -1;
  repeat
    if not ReadHeaderLine(AStream, Line) then
      Exit(False);
    if SameText(Copy(Line, 1, 15), 'Content-Length:') then
      Len := StrToIntDef(Trim(Copy(Line, 16, MaxInt)), -1);
  until Line = '';
  if Len < 0 then
    Exit(False);
  SetLength(ABody, Len);
  Got := 0;
  while Got < Len do
  begin
    N := AStream.Read(ABody[Got + 1], Len - Got);
    if N <= 0 then
      Exit(False);
    Inc(Got, N);
  end;
  Result := True;
end;

procedure WriteDapMessage(AStream: TStream; const ABody: String);
var
  Msg: String;
begin
  Msg := 'Content-Length: ' + IntToStr(Length(ABody)) + #13#10#13#10 + ABody;
  AStream.WriteBuffer(Msg[1], Length(Msg));
end;

end.
