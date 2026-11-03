{
  PDR Debugger - Debug Adapter Protocol session

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Turns DAP requests into IDebugBackend calls and answers with responses
  and events.  One thread ("main", id 1); a frame's id is its index; the
  Locals scope of frame N has variablesReference N + 1, and the Globals
  scope GlobalsReference.

  Launch flow: initialize, launch (the program starts paused at its entry
  point), "initialized" event, setBreakpoints..., configurationDone (the
  program runs unless stopOnEntry).  Execution requests block until the
  program stops; meanwhile the reader thread hands requests to
  HandleWhileRunning, which answers pause at once.
}
unit dap_session;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson, jsonparser, pdr_ports, dap_backend;

type
  TDapSend = procedure(const AJson: String) of object;

  TDapSession = class
  private
    FBackend: IDebugBackend;
    FSend: TDapSend;
    FSeq: Integer;
    FStopOnEntry: Boolean;
    FLaunched: Boolean;
    FFinished: Boolean;
    { Breakpoint handles per source path, replaced by each setBreakpoints. }
    FBreakpoints: TStringList;
    FLock: TCriticalSection;
    procedure Send(AMessage: TJSONObject);
    procedure Respond(ARequest: TJSONObject; ABody: TJSONObject);
    procedure Fail(ARequest: TJSONObject; const AMessage: String);
    procedure Event(const AName: String; ABody: TJSONObject);
    procedure ReportStop(const AStop: TStopInfo);
    procedure DoInitialize(R: TJSONObject);
    procedure DoLaunch(R: TJSONObject);
    procedure DoSetBreakpoints(R: TJSONObject);
    procedure DoConfigurationDone(R: TJSONObject);
    procedure DoThreads(R: TJSONObject);
    procedure DoStackTrace(R: TJSONObject);
    procedure DoScopes(R: TJSONObject);
    procedure DoVariables(R: TJSONObject);
    procedure DoEvaluate(R: TJSONObject);
    procedure DoExecution(R: TJSONObject; const ACommand: String);
    procedure DoDisconnect(R: TJSONObject);
    procedure DoSetExceptionBreakpoints(R: TJSONObject);
    procedure DoPause(R: TJSONObject);
  public
    constructor Create(ABackend: IDebugBackend; ASend: TDapSend);
    destructor Destroy; override;
    { Handle one request (a JSON object). }
    procedure Handle(const ARequest: String);
    { Called on the reader thread while another request may be running:
      handles ARequest now and returns True when it is a pause, else
      returns False and leaves it for Handle. }
    function HandleWhileRunning(const ARequest: String): Boolean;
    { A disconnect or terminate request has been handled. }
    property Finished: Boolean read FFinished;
  end;

implementation

const
  GlobalsReference = 1000000;

function Args(R: TJSONObject): TJSONObject;
var
  D: TJSONData;
begin
  D := R.Find('arguments');
  if (D <> nil) and (D.JSONType = jtObject) then
    Result := TJSONObject(D)
  else
    Result := nil;
end;

function Str(O: TJSONObject; const AName: String): String;
var
  D: TJSONData;
begin
  Result := '';
  if O = nil then
    Exit;
  D := O.Find(AName);
  if (D <> nil) and (D.JSONType = jtString) then
    Result := D.AsString;
end;

function Int(O: TJSONObject; const AName: String; ADefault: Integer): Integer;
var
  D: TJSONData;
begin
  Result := ADefault;
  if O = nil then
    Exit;
  D := O.Find(AName);
  if (D <> nil) and (D.JSONType = jtNumber) then
    Result := D.AsInteger;
end;

function Bool(O: TJSONObject; const AName: String): Boolean;
var
  D: TJSONData;
begin
  Result := False;
  if O = nil then
    Exit;
  D := O.Find(AName);
  if (D <> nil) and (D.JSONType = jtBoolean) then
    Result := D.AsBoolean;
end;

constructor TDapSession.Create(ABackend: IDebugBackend; ASend: TDapSend);
begin
  inherited Create;
  FBackend := ABackend;
  FSend := ASend;
  FBreakpoints := TStringList.Create;
  FBreakpoints.OwnsObjects := True;
  FLock := TCriticalSection.Create;
end;

destructor TDapSession.Destroy;
begin
  FBreakpoints.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TDapSession.Send(AMessage: TJSONObject);
begin
  { The reader thread answers pause while the main thread may be sending. }
  FLock.Enter;
  try
    Inc(FSeq);
    AMessage.Add('seq', FSeq);
    FSend(AMessage.AsJSON);
  finally
    FLock.Leave;
    AMessage.Free;
  end;
end;

procedure TDapSession.Respond(ARequest: TJSONObject; ABody: TJSONObject);
var
  M: TJSONObject;
begin
  M := TJSONObject.Create;
  M.Add('type', 'response');
  M.Add('request_seq', Int(ARequest, 'seq', 0));
  M.Add('success', True);
  M.Add('command', Str(ARequest, 'command'));
  if ABody <> nil then
    M.Add('body', ABody);
  Send(M);
end;

procedure TDapSession.Fail(ARequest: TJSONObject; const AMessage: String);
var
  M: TJSONObject;
begin
  M := TJSONObject.Create;
  M.Add('type', 'response');
  M.Add('request_seq', Int(ARequest, 'seq', 0));
  M.Add('success', False);
  M.Add('command', Str(ARequest, 'command'));
  M.Add('message', AMessage);
  Send(M);
end;

procedure TDapSession.Event(const AName: String; ABody: TJSONObject);
var
  M: TJSONObject;
begin
  M := TJSONObject.Create;
  M.Add('type', 'event');
  M.Add('event', AName);
  if ABody <> nil then
    M.Add('body', ABody);
  Send(M);
end;

procedure TDapSession.ReportStop(const AStop: TStopInfo);
var
  B: TJSONObject;
begin
  if AStop.Reason = srExited then
  begin
    B := TJSONObject.Create;
    B.Add('exitCode', AStop.ExitCode);
    Event('exited', B);
    Event('terminated', nil);
    Exit;
  end;
  B := TJSONObject.Create;
  case AStop.Reason of
    srEntry: B.Add('reason', 'entry');
    srBreakpoint: B.Add('reason', 'breakpoint');
    srStep: B.Add('reason', 'step');
    srException: B.Add('reason', 'exception');
    srPause: B.Add('reason', 'pause');
  end;
  if AStop.Text <> '' then
    B.Add('text', AStop.Text);
  B.Add('threadId', 1);
  B.Add('allThreadsStopped', True);
  Event('stopped', B);
end;

procedure TDapSession.DoInitialize(R: TJSONObject);
var
  B, F: TJSONObject;
  L: TJSONArray;
begin
  B := TJSONObject.Create;
  B.Add('supportsConfigurationDoneRequest', True);
  B.Add('supportsConditionalBreakpoints', True);
  B.Add('supportsEvaluateForHovers', True);
  B.Add('supportsTerminateRequest', True);
  F := TJSONObject.Create;
  F.Add('filter', 'raised');
  F.Add('label', 'Raised exceptions');
  F.Add('default', True);
  L := TJSONArray.Create;
  L.Add(F);
  B.Add('exceptionBreakpointFilters', L);
  Respond(R, B);
end;

procedure TDapSession.DoLaunch(R: TJSONObject);
var
  A: TJSONObject;
  D: TJSONData;
  ProgArgs: array of String;
  I: Integer;
  Err: String;
begin
  A := Args(R);
  if Str(A, 'program') = '' then
  begin
    Fail(R, 'launch needs a "program"');
    Exit;
  end;
  SetLength(ProgArgs, 0);
  if A <> nil then
  begin
    D := A.Find('args');
    if (D <> nil) and (D.JSONType = jtArray) then
    begin
      SetLength(ProgArgs, D.Count);
      for I := 0 to D.Count - 1 do
        ProgArgs[I] := D.Items[I].AsString;
    end;
  end;
  FStopOnEntry := Bool(A, 'stopOnEntry');
  if not FBackend.Launch(Str(A, 'program'), ProgArgs, Str(A, 'cwd'), Err) then
  begin
    Fail(R, Err);
    Exit;
  end;
  FLaunched := True;
  Respond(R, nil);
  Event('initialized', nil);
end;

procedure TDapSession.DoSetBreakpoints(R: TJSONObject);
var
  A, Src, Bp, Out_: TJSONObject;
  D: TJSONData;
  Path: String;
  Idx, I, H: Integer;
  Handles: TStringList;
  Res: TBreakpointResult;
  List: TJSONArray;
  B: TJSONObject;
begin
  A := Args(R);
  Src := nil;
  if A <> nil then
  begin
    D := A.Find('source');
    if (D <> nil) and (D.JSONType = jtObject) then
      Src := TJSONObject(D);
  end;
  Path := Str(Src, 'path');
  if Path = '' then
  begin
    Fail(R, 'setBreakpoints needs source.path');
    Exit;
  end;
  { Replace the file's breakpoints. }
  Idx := FBreakpoints.IndexOf(Path);
  if Idx >= 0 then
  begin
    Handles := TStringList(FBreakpoints.Objects[Idx]);
    for I := 0 to Handles.Count - 1 do
      FBackend.ClearBreakpoint(StrToInt(Handles[I]));
    Handles.Clear;
  end
  else
  begin
    Handles := TStringList.Create;
    FBreakpoints.AddObject(Path, Handles);
  end;
  List := TJSONArray.Create;
  D := nil;
  if A <> nil then
    D := A.Find('breakpoints');
  if (D <> nil) and (D.JSONType = jtArray) then
    for I := 0 to D.Count - 1 do
    begin
      if D.Items[I].JSONType <> jtObject then
        Continue;
      Bp := TJSONObject(D.Items[I]);
      Res := FBackend.SetBreakpoint(Path, Int(Bp, 'line', 0), Str(Bp, 'condition'));
      Out_ := TJSONObject.Create;
      Out_.Add('verified', Res.Verified);
      Out_.Add('line', Res.Line);
      if Res.Verified then
      begin
        H := Res.Handle;
        Out_.Add('id', H);
        Handles.Add(IntToStr(H));
      end;
      if Res.Message <> '' then
        Out_.Add('message', Res.Message);
      List.Add(Out_);
    end;
  B := TJSONObject.Create;
  B.Add('breakpoints', List);
  Respond(R, B);
end;

procedure TDapSession.DoConfigurationDone(R: TJSONObject);
begin
  Respond(R, nil);
  if not FLaunched then
    Exit;
  if FStopOnEntry then
    ReportStop(StopInfo(srEntry))
  else
    ReportStop(FBackend.Resume);
end;

procedure TDapSession.DoThreads(R: TJSONObject);
var
  B, T: TJSONObject;
  L: TJSONArray;
begin
  T := TJSONObject.Create;
  T.Add('id', 1);
  T.Add('name', 'main');
  L := TJSONArray.Create;
  L.Add(T);
  B := TJSONObject.Create;
  B.Add('threads', L);
  Respond(R, B);
end;

procedure TDapSession.DoStackTrace(R: TJSONObject);
var
  Frames: TStackFrameArray;
  L: TJSONArray;
  F, Src, B: TJSONObject;
  I: Integer;
begin
  Frames := FBackend.Frames;
  L := TJSONArray.Create;
  for I := 0 to High(Frames) do
  begin
    F := TJSONObject.Create;
    F.Add('id', I);
    F.Add('name', Frames[I].FunctionName);
    if Frames[I].HasLine then
    begin
      Src := TJSONObject.Create;
      Src.Add('name', ExtractFileName(Frames[I].FileName));
      Src.Add('path', Frames[I].FileName);
      F.Add('source', Src);
      F.Add('line', Frames[I].LineNumber);
    end
    else
      F.Add('line', 0);
    F.Add('column', 1);
    F.Add('instructionPointerReference', '0x' + IntToHex(Frames[I].Address, 16));
    L.Add(F);
  end;
  B := TJSONObject.Create;
  B.Add('stackFrames', L);
  B.Add('totalFrames', Length(Frames));
  Respond(R, B);
end;

procedure TDapSession.DoScopes(R: TJSONObject);
var
  S, B: TJSONObject;
  L: TJSONArray;
begin
  S := TJSONObject.Create;
  S.Add('name', 'Locals');
  S.Add('presentationHint', 'locals');
  S.Add('variablesReference', Int(Args(R), 'frameId', 0) + 1);
  S.Add('expensive', False);
  L := TJSONArray.Create;
  L.Add(S);
  S := TJSONObject.Create;
  S.Add('name', 'Globals');
  S.Add('variablesReference', GlobalsReference);
  S.Add('expensive', False);
  L.Add(S);
  B := TJSONObject.Create;
  B.Add('scopes', L);
  Respond(R, B);
end;

procedure TDapSession.DoVariables(R: TJSONObject);
var
  Ref, I: Integer;
  Vars: TVariableValueArray;
  L: TJSONArray;
  V, B: TJSONObject;
begin
  Ref := Int(Args(R), 'variablesReference', 0);
  L := TJSONArray.Create;
  if Ref > 0 then
  begin
    if Ref = GlobalsReference then
      Vars := FBackend.Globals
    else
      Vars := FBackend.Locals(Ref - 1);
    for I := 0 to High(Vars) do
    begin
      V := TJSONObject.Create;
      V.Add('name', Vars[I].Name);
      if Vars[I].IsValid then
        V.Add('value', Vars[I].Value)
      else
        V.Add('value', '<unavailable>');
      V.Add('type', Vars[I].TypeName);
      V.Add('variablesReference', 0);
      L.Add(V);
    end;
  end;
  B := TJSONObject.Create;
  B.Add('variables', L);
  Respond(R, B);
end;

procedure TDapSession.DoEvaluate(R: TJSONObject);
var
  V: TVariableValue;
  B: TJSONObject;
begin
  V := FBackend.Evaluate(Int(Args(R), 'frameId', 0), Str(Args(R), 'expression'));
  if not V.IsValid then
  begin
    Fail(R, 'cannot evaluate ' + Str(Args(R), 'expression'));
    Exit;
  end;
  B := TJSONObject.Create;
  B.Add('result', V.Value);
  B.Add('type', V.TypeName);
  B.Add('variablesReference', 0);
  Respond(R, B);
end;

procedure TDapSession.DoExecution(R: TJSONObject; const ACommand: String);
var
  B: TJSONObject;
begin
  if ACommand = 'continue' then
  begin
    B := TJSONObject.Create;
    B.Add('allThreadsContinued', True);
    Respond(R, B);
    ReportStop(FBackend.Resume);
  end
  else
  begin
    Respond(R, nil);
    if ACommand = 'next' then
      ReportStop(FBackend.StepOver)
    else if ACommand = 'stepIn' then
      ReportStop(FBackend.StepIn)
    else
      ReportStop(FBackend.StepOut);
  end;
end;

procedure TDapSession.DoSetExceptionBreakpoints(R: TJSONObject);
var
  D: TJSONData;
  I: Integer;
  Catch: Boolean;
begin
  Catch := False;
  if Args(R) <> nil then
  begin
    D := Args(R).Find('filters');
    if (D <> nil) and (D.JSONType = jtArray) then
      for I := 0 to D.Count - 1 do
        if D.Items[I].AsString = 'raised' then
          Catch := True;
  end;
  FBackend.SetCatchExceptions(Catch);
  Respond(R, nil);
end;

procedure TDapSession.DoPause(R: TJSONObject);
begin
  FBackend.Pause;
  Respond(R, nil);
end;

function TDapSession.HandleWhileRunning(const ARequest: String): Boolean;
var
  D: TJSONData;
begin
  Result := False;
  try
    D := GetJSON(ARequest);
  except
    on E: Exception do
      Exit;
  end;
  try
    if (D.JSONType = jtObject) and (Str(TJSONObject(D), 'type') = 'request')
      and (Str(TJSONObject(D), 'command') = 'pause') then
    begin
      DoPause(TJSONObject(D));
      Result := True;
    end;
  finally
    D.Free;
  end;
end;

procedure TDapSession.DoDisconnect(R: TJSONObject);
begin
  if FLaunched then
    FBackend.Terminate;
  FLaunched := False;
  Respond(R, nil);
  FFinished := True;
end;

procedure TDapSession.Handle(const ARequest: String);
var
  D: TJSONData;
  R: TJSONObject;
  Cmd: String;
begin
  try
    D := GetJSON(ARequest);
  except
    on E: Exception do
      Exit;
  end;
  try
    if D.JSONType <> jtObject then
      Exit;
    R := TJSONObject(D);
    if Str(R, 'type') <> 'request' then
      Exit;
    Cmd := Str(R, 'command');
    try
      if Cmd = 'initialize' then DoInitialize(R)
      else if Cmd = 'launch' then DoLaunch(R)
      else if Cmd = 'setBreakpoints' then DoSetBreakpoints(R)
      else if Cmd = 'setExceptionBreakpoints' then DoSetExceptionBreakpoints(R)
      else if Cmd = 'pause' then DoPause(R)
      else if Cmd = 'configurationDone' then DoConfigurationDone(R)
      else if Cmd = 'threads' then DoThreads(R)
      else if Cmd = 'stackTrace' then DoStackTrace(R)
      else if Cmd = 'scopes' then DoScopes(R)
      else if Cmd = 'variables' then DoVariables(R)
      else if Cmd = 'evaluate' then DoEvaluate(R)
      else if (Cmd = 'continue') or (Cmd = 'next') or (Cmd = 'stepIn') or (Cmd = 'stepOut') then
        DoExecution(R, Cmd)
      else if (Cmd = 'disconnect') or (Cmd = 'terminate') then DoDisconnect(R)
      else
        Fail(R, 'unsupported request: ' + Cmd);
    except
      on E: Exception do
        Fail(R, E.ClassName + ': ' + E.Message);
    end;
  finally
    D.Free;
  end;
end;

end.
