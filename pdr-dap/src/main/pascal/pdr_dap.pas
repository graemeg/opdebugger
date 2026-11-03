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
  Classes, SysUtils, SyncObjs, BaseUnix,
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

type
  { Reads requests on its own thread so a pause can interrupt a blocked
    continue: pause is handled at once, the rest are queued for the main
    thread in order.  An empty entry marks the end of the input. }
  TReader = class(TThread)
  private
    FInput: TStream;
    FSession: TDapSession;
    FQueue: TStringList;
    FLock: TCriticalSection;
    FReady: TEvent;
    procedure Push(const ABody: String);
  protected
    procedure Execute; override;
  public
    constructor Create(AInput: TStream; ASession: TDapSession);
    destructor Destroy; override;
    { The next request, waiting for one; False at the end of the input. }
    function Next(out ABody: String): Boolean;
  end;

constructor TReader.Create(AInput: TStream; ASession: TDapSession);
begin
  FInput := AInput;
  FSession := ASession;
  FQueue := TStringList.Create;
  FLock := TCriticalSection.Create;
  FReady := TEvent.Create(nil, False, False, '');
  inherited Create(False);
end;

destructor TReader.Destroy;
begin
  FReady.Free;
  FLock.Free;
  FQueue.Free;
  inherited Destroy;
end;

procedure TReader.Push(const ABody: String);
begin
  FLock.Enter;
  try
    FQueue.Add(ABody);
  finally
    FLock.Leave;
  end;
  FReady.SetEvent;
end;

procedure TReader.Execute;
var
  Body: String;
begin
  while ReadDapMessage(FInput, Body) do
    if (Body <> '') and not FSession.HandleWhileRunning(Body) then
      Push(Body);
  Push('');
end;

function TReader.Next(out ABody: String): Boolean;
begin
  repeat
    FLock.Enter;
    try
      if FQueue.Count > 0 then
      begin
        ABody := FQueue[0];
        FQueue.Delete(0);
        Exit(ABody <> '');
      end;
    finally
      FLock.Leave;
    end;
    FReady.WaitFor(INFINITE);
  until False;
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
  Reader: TReader;
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
  Reader := TReader.Create(Input, Session);
  try
    while Reader.Next(Body) do
    begin
      Session.Handle(Body);
      if Session.Finished then
        Break;
    end;
  finally
    { The reader may be blocked reading; the process exit ends it. }
    Session.Free;
    Backend.Free;
    Server.Free;
    Input.Free;
  end;
end.
