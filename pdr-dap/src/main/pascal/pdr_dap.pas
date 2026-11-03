{
  PDR Debugger - Debug Adapter Protocol server

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Speaks the Debug Adapter Protocol on stdin and stdout, for IDEs such as
  Hexagram and VS Code:

    pdr-dap

  stdin and stdout carry only the protocol.  Before anything else runs,
  the adapter keeps private copies of them and points fd 1 at stderr, so
  the engine's messages and the debuggee's output (which inherits fd 1
  and 2) go to stderr; the debuggee's stdin is /dev/null.
}
program pdr_dap;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, BaseUnix,
  dap_wire, dap_backend, dap_session, dap_engine_backend;

type
  TServer = class
  private
    FOut: THandleStream;
  public
    constructor Create(AOutFd: cint);
    destructor Destroy; override;
    procedure Send(const AJson: String);
  end;

constructor TServer.Create(AOutFd: cint);
begin
  FOut := THandleStream.Create(AOutFd);
end;

destructor TServer.Destroy;
begin
  FOut.Free;
  inherited Destroy;
end;

procedure TServer.Send(const AJson: String);
begin
  WriteDapMessage(FOut, AJson);
end;

{ A private copy of AFd that children do not inherit. }
function PrivateCopy(AFd: cint): cint;
begin
  Result := FpDup(AFd);
  FpFcntl(Result, F_SETFD, FD_CLOEXEC);
end;

var
  InFd, OutFd, NullFd: cint;
  Input: THandleStream;
  Server: TServer;
  Backend: TEngineBackend;
  Session: TDapSession;
  Body: String;
begin
  InFd := PrivateCopy(0);
  OutFd := PrivateCopy(1);
  NullFd := FpOpen('/dev/null', O_RDWR);
  if NullFd >= 0 then
  begin
    FpDup2(NullFd, 0);
    if NullFd > 2 then
      FpClose(NullFd);
  end;
  FpDup2(2, 1);

  Input := THandleStream.Create(InFd);
  Server := TServer.Create(OutFd);
  Backend := TEngineBackend.Create;
  Session := TDapSession.Create(Backend, @Server.Send);
  try
    while ReadDapMessage(Input, Body) do
    begin
      Session.Handle(Body);
      if Session.Finished then
        Break;
    end;
  finally
    Session.Free;
    Backend.Free;
    Server.Free;
    Input.Free;
  end;
end.
