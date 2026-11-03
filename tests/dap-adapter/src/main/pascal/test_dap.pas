{
  pdr-dap protocol tests

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Framing round trips, and DAP sessions driven against a scripted backend:
  the launch handshake, breakpoints replaced per file, stops and exits,
  stack frames, locals and evaluate, failures.  Exit code 0 when every
  check passes.
}
program test_dap;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  Classes, SysUtils, fpjson, jsonparser, pdr_ports, dap_wire, dap_backend, dap_session;

type
  TFakeBackend = class(IDebugBackend)
  public
    Log: TStringList;
    Stops: array of TStopInfo;
    NextStop: Integer;
    LaunchFails: Boolean;
    NextHandle: Integer;
    constructor Create;
    destructor Destroy; override;
    function Launch(const AProgram: String; const AArgs: array of String; const ACwd: String;
      out AError: String): Boolean;
    function SetBreakpoint(const APath: String; ALine: Integer; const ACondition: String): TBreakpointResult;
    procedure ClearBreakpoint(AHandle: Integer);
    function Resume: TStopInfo;
    function StepOver: TStopInfo;
    function StepIn: TStopInfo;
    function StepOut: TStopInfo;
    function Frames: TStackFrameArray;
    function Locals(AFrame: Integer): TVariableValueArray;
    function Globals: TVariableValueArray;
    function Evaluate(AFrame: Integer; const AExpr: String): TVariableValue;
    procedure Terminate;
    function Take: TStopInfo;
  end;

  TCapture = class
  public
    Messages: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Send(const AJson: String);
    function Message(I: Integer): TJSONObject;
    function Find(const AType, AName: String): TJSONObject;
  end;

var
  Failures, Checks: Integer;

procedure Check(ACond: Boolean; const AWhat: String);
begin
  Inc(Checks);
  if not ACond then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', AWhat);
  end;
end;

procedure CheckEquals(const AExpected, AActual, AWhat: String);
begin
  Check(AExpected = AActual, AWhat + ': expected "' + AExpected + '", got "' + AActual + '"');
end;

{ TFakeBackend }

constructor TFakeBackend.Create;
begin
  Log := TStringList.Create;
  NextHandle := 1;
end;

destructor TFakeBackend.Destroy;
begin
  Log.Free;
  inherited Destroy;
end;

function TFakeBackend.Launch(const AProgram: String; const AArgs: array of String; const ACwd: String;
  out AError: String): Boolean;
var
  I: Integer;
  S: String;
begin
  S := 'launch ' + AProgram;
  for I := 0 to High(AArgs) do
    S := S + ' ' + AArgs[I];
  if ACwd <> '' then
    S := S + ' in ' + ACwd;
  Log.Add(S);
  AError := 'cannot load ' + AProgram;
  Result := not LaunchFails;
end;

function TFakeBackend.SetBreakpoint(const APath: String; ALine: Integer; const ACondition: String): TBreakpointResult;
begin
  Log.Add(Format('break %s:%d %s', [ExtractFileName(APath), ALine, ACondition]));
  Result.Line := ALine;
  Result.Message := '';
  Result.Verified := ALine <> 999;
  if not Result.Verified then
    Result.Message := 'no code at line 999';
  Result.Handle := NextHandle;
  Inc(NextHandle);
end;

procedure TFakeBackend.ClearBreakpoint(AHandle: Integer);
begin
  Log.Add('clear ' + IntToStr(AHandle));
end;

function TFakeBackend.Take: TStopInfo;
begin
  if NextStop < Length(Stops) then
  begin
    Result := Stops[NextStop];
    Inc(NextStop);
  end
  else
    Result := StopInfo(srExited, '', 0);
end;

function TFakeBackend.Resume: TStopInfo;
begin
  Log.Add('resume');
  Result := Take;
end;

function TFakeBackend.StepOver: TStopInfo;
begin
  Log.Add('over');
  Result := Take;
end;

function TFakeBackend.StepIn: TStopInfo;
begin
  Log.Add('in');
  Result := Take;
end;

function TFakeBackend.StepOut: TStopInfo;
begin
  Log.Add('out');
  Result := Take;
end;

function TFakeBackend.Frames: TStackFrameArray;
begin
  SetLength(Result, 2);
  Result[0].Index := 0;
  Result[0].FunctionName := 'Level2';
  Result[0].FileName := '/src/demo.pas';
  Result[0].LineNumber := 12;
  Result[0].Address := $1000;
  Result[0].HasFunction := True;
  Result[0].HasLine := True;
  Result[1].Index := 1;
  Result[1].FunctionName := '<unknown>';
  Result[1].FileName := '';
  Result[1].LineNumber := 0;
  Result[1].Address := $2000;
  Result[1].HasFunction := False;
  Result[1].HasLine := False;
end;

function TFakeBackend.Locals(AFrame: Integer): TVariableValueArray;
begin
  Log.Add('locals ' + IntToStr(AFrame));
  SetLength(Result, 1);
  Result[0].Name := 'N';
  Result[0].TypeName := 'Int32';
  Result[0].Value := '42';
  Result[0].IsValid := True;
end;

function TFakeBackend.Globals: TVariableValueArray;
begin
  Log.Add('globals');
  SetLength(Result, 1);
  Result[0].Name := 'Total';
  Result[0].TypeName := 'Int64';
  Result[0].Value := '9';
  Result[0].IsValid := True;
end;

function TFakeBackend.Evaluate(AFrame: Integer; const AExpr: String): TVariableValue;
begin
  Log.Add(Format('eval %d %s', [AFrame, AExpr]));
  Result.Name := AExpr;
  Result.TypeName := 'Int32';
  Result.Value := '7';
  Result.IsValid := AExpr <> 'nope';
end;

procedure TFakeBackend.Terminate;
begin
  Log.Add('terminate');
end;

{ TCapture }

constructor TCapture.Create;
begin
  Messages := TStringList.Create;
end;

destructor TCapture.Destroy;
begin
  Messages.Free;
  inherited Destroy;
end;

procedure TCapture.Send(const AJson: String);
begin
  Messages.Add(AJson);
end;

function TCapture.Message(I: Integer): TJSONObject;
begin
  Result := TJSONObject(GetJSON(Messages[I]));
end;

{ The last message of AType ('response' or 'event') named AName. }
function TCapture.Find(const AType, AName: String): TJSONObject;
var
  I: Integer;
  M: TJSONObject;
  Key: String;
begin
  if AType = 'event' then Key := 'event' else Key := 'command';
  for I := Messages.Count - 1 downto 0 do
  begin
    M := Message(I);
    if (M.Get('type', '') = AType) and (M.Get(Key, '') = AName) then
      Exit(M);
    M.Free;
  end;
  Result := nil;
end;

{ Helpers }

var
  Seq: Integer = 0;

function Req(const ACommand, AArgs: String): String;
begin
  Inc(Seq);
  Result := Format('{"seq": %d, "type": "request", "command": "%s"', [Seq, ACommand]);
  if AArgs <> '' then
    Result := Result + ', "arguments": ' + AArgs;
  Result := Result + '}';
end;

procedure NewSession(out B: TFakeBackend; out C: TCapture; out S: TDapSession);
begin
  B := TFakeBackend.Create;
  C := TCapture.Create;
  S := TDapSession.Create(B, @C.Send);
end;

procedure Launch(S: TDapSession; const AExtra: String);
begin
  S.Handle(Req('initialize', '{"adapterID": "pdr"}'));
  S.Handle(Req('launch', '{"program": "/bin/demo", "args": ["a", "b c"], "cwd": "/work"' + AExtra + '}'));
end;

{ Tests }

procedure TestFraming;
var
  M: TMemoryStream;
  Body: String;
begin
  M := TMemoryStream.Create;
  try
    WriteDapMessage(M, '{"a":1}');
    WriteDapMessage(M, '{"b":"é"}');
    M.Position := 0;
    Check(ReadDapMessage(M, Body), 'framing: first message');
    CheckEquals('{"a":1}', Body, 'framing: first body');
    Check(ReadDapMessage(M, Body), 'framing: second message');
    CheckEquals('{"b":"é"}', Body, 'framing: UTF-8 body by byte length');
    Check(not ReadDapMessage(M, Body), 'framing: end of stream');
  finally
    M.Free;
  end;
end;

procedure TestFramingIgnoresOtherHeaders;
var
  M: TStringStream;
  Body: String;
begin
  M := TStringStream.Create('Content-Type: x' + #13#10 + 'Content-Length: 2' + #13#10#13#10 + '{}');
  try
    Check(ReadDapMessage(M, Body), 'headers: read');
    CheckEquals('{}', Body, 'headers: body');
  finally
    M.Free;
  end;
end;

procedure TestLaunchHandshake;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  M: TJSONObject;
begin
  NewSession(B, C, S);
  Launch(S, '');
  M := C.Find('response', 'initialize');
  Check((M <> nil) and M.Booleans['success'], 'initialize succeeds');
  Check((M <> nil) and M.Objects['body'].Booleans['supportsConfigurationDoneRequest'],
    'initialize: configurationDone supported');
  CheckEquals('launch /bin/demo a b c in /work', B.Log[0], 'launch reaches the backend');
  M := C.Find('response', 'launch');
  Check((M <> nil) and M.Booleans['success'], 'launch succeeds');
  Check(C.Find('event', 'initialized') <> nil, 'initialized event after launch');
  { configurationDone runs the program; the fake exits at once. }
  S.Handle(Req('configurationDone', ''));
  CheckEquals('resume', B.Log[B.Log.Count - 1], 'configurationDone resumes');
  M := C.Find('event', 'exited');
  Check((M <> nil) and (M.Objects['body'].Integers['exitCode'] = 0), 'exited event');
  Check(C.Find('event', 'terminated') <> nil, 'terminated event');
end;

procedure TestStopOnEntry;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  M: TJSONObject;
begin
  NewSession(B, C, S);
  Launch(S, ', "stopOnEntry": true');
  S.Handle(Req('configurationDone', ''));
  M := C.Find('event', 'stopped');
  Check(M <> nil, 'stopped on entry');
  if M <> nil then
    CheckEquals('entry', M.Objects['body'].Strings['reason'], 'reason entry');
  Check(B.Log.IndexOf('resume') < 0, 'not resumed');
end;

procedure TestLaunchFailure;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  M: TJSONObject;
begin
  NewSession(B, C, S);
  B.LaunchFails := True;
  Launch(S, '');
  M := C.Find('response', 'launch');
  Check((M <> nil) and not M.Booleans['success'], 'launch fails');
  if M <> nil then
    CheckEquals('cannot load /bin/demo', M.Strings['message'], 'failure message');
  Check(C.Find('event', 'initialized') = nil, 'no initialized event');
end;

procedure TestBreakpointsReplacedPerFile;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  M: TJSONObject;
  L: TJSONArray;
begin
  NewSession(B, C, S);
  Launch(S, '');
  S.Handle(Req('setBreakpoints', '{"source": {"path": "/src/demo.pas"}, "breakpoints": [{"line": 12}, ' +
    '{"line": 999}, {"line": 20, "condition": "N > 3"}]}'));
  M := C.Find('response', 'setBreakpoints');
  L := M.Objects['body'].Arrays['breakpoints'];
  Check(L.Count = 3, 'three results');
  Check(TJSONObject(L[0]).Booleans['verified'], 'line 12 verified');
  Check(not TJSONObject(L[1]).Booleans['verified'], 'line 999 not verified');
  CheckEquals('no code at line 999', TJSONObject(L[1]).Strings['message'], 'unverified message');
  CheckEquals('break demo.pas:20 N > 3', B.Log[3], 'condition passed on');
  { The second request for the file clears the verified ones first. }
  S.Handle(Req('setBreakpoints', '{"source": {"path": "/src/demo.pas"}, "breakpoints": [{"line": 14}]}'));
  Check(B.Log.IndexOf('clear 1') >= 0, 'old breakpoint 1 cleared');
  Check(B.Log.IndexOf('clear 3') >= 0, 'old breakpoint 3 cleared');
  Check(B.Log.IndexOf('clear 2') < 0, 'unverified one was never set');
end;

procedure TestStopsAndSteps;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  M: TJSONObject;
begin
  NewSession(B, C, S);
  SetLength(B.Stops, 3);
  B.Stops[0] := StopInfo(srBreakpoint);
  B.Stops[1] := StopInfo(srStep);
  B.Stops[2] := StopInfo(srException, 'EDivByZero: Division by zero');
  Launch(S, '');
  S.Handle(Req('configurationDone', ''));
  M := C.Find('event', 'stopped');
  CheckEquals('breakpoint', M.Objects['body'].Strings['reason'], 'stopped at a breakpoint');
  Check(M.Objects['body'].Integers['threadId'] = 1, 'thread 1');
  S.Handle(Req('next', '{"threadId": 1}'));
  CheckEquals('over', B.Log[B.Log.Count - 1], 'next steps over');
  M := C.Find('event', 'stopped');
  CheckEquals('step', M.Objects['body'].Strings['reason'], 'stopped after a step');
  S.Handle(Req('continue', '{"threadId": 1}'));
  M := C.Find('event', 'stopped');
  CheckEquals('exception', M.Objects['body'].Strings['reason'], 'stopped on an exception');
  CheckEquals('EDivByZero: Division by zero', M.Objects['body'].Strings['text'], 'exception text');
  M := C.Find('response', 'continue');
  Check(M.Objects['body'].Booleans['allThreadsContinued'], 'continue response');
  S.Handle(Req('stepIn', '{"threadId": 1}'));
  CheckEquals('in', B.Log[B.Log.Count - 1], 'stepIn');
  Check(C.Find('event', 'exited') <> nil, 'then exits');
end;

procedure TestStackScopesVariablesEvaluate;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  M, F: TJSONObject;
  L: TJSONArray;
begin
  NewSession(B, C, S);
  SetLength(B.Stops, 1);
  B.Stops[0] := StopInfo(srBreakpoint);
  Launch(S, '');
  S.Handle(Req('configurationDone', ''));
  S.Handle(Req('threads', ''));
  M := C.Find('response', 'threads');
  CheckEquals('main', TJSONObject(M.Objects['body'].Arrays['threads'][0]).Strings['name'], 'one thread');
  S.Handle(Req('stackTrace', '{"threadId": 1}'));
  M := C.Find('response', 'stackTrace');
  L := M.Objects['body'].Arrays['stackFrames'];
  Check(L.Count = 2, 'two frames');
  F := TJSONObject(L[0]);
  CheckEquals('Level2', F.Strings['name'], 'frame name');
  CheckEquals('/src/demo.pas', F.Objects['source'].Strings['path'], 'frame path');
  Check(F.Integers['line'] = 12, 'frame line');
  Check(TJSONObject(L[1]).Find('source') = nil, 'no source without line info');
  S.Handle(Req('scopes', '{"frameId": 1}'));
  M := C.Find('response', 'scopes');
  Check(TJSONObject(M.Objects['body'].Arrays['scopes'][0]).Integers['variablesReference'] = 2,
    'frame 1 locals reference');
  CheckEquals('Globals', TJSONObject(M.Objects['body'].Arrays['scopes'][1]).Strings['name'], 'globals scope');
  S.Handle(Req('variables', Format('{"variablesReference": %d}',
    [TJSONObject(M.Objects['body'].Arrays['scopes'][1]).Integers['variablesReference']])));
  CheckEquals('globals', B.Log[B.Log.Count - 1], 'globals asked for');
  M := C.Find('response', 'variables');
  CheckEquals('Total', TJSONObject(M.Objects['body'].Arrays['variables'][0]).Strings['name'], 'a global');
  S.Handle(Req('variables', '{"variablesReference": 2}'));
  CheckEquals('locals 1', B.Log[B.Log.Count - 1], 'locals of frame 1');
  M := C.Find('response', 'variables');
  F := TJSONObject(M.Objects['body'].Arrays['variables'][0]);
  CheckEquals('N', F.Strings['name'], 'variable name');
  CheckEquals('42', F.Strings['value'], 'variable value');
  CheckEquals('Int32', F.Strings['type'], 'variable type');
  S.Handle(Req('evaluate', '{"expression": "N + 1", "frameId": 0}'));
  M := C.Find('response', 'evaluate');
  CheckEquals('7', M.Objects['body'].Strings['result'], 'evaluate result');
  S.Handle(Req('evaluate', '{"expression": "nope", "frameId": 0}'));
  M := C.Find('response', 'evaluate');
  Check(not M.Booleans['success'], 'evaluate failure');
end;

procedure TestDisconnectAndUnknown;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  M: TJSONObject;
begin
  NewSession(B, C, S);
  Launch(S, '');
  S.Handle(Req('frobnicate', ''));
  M := C.Find('response', 'frobnicate');
  Check((M <> nil) and not M.Booleans['success'], 'unknown request fails');
  S.Handle('not json at all');
  S.Handle(Req('disconnect', '{"terminateDebuggee": true}'));
  Check(B.Log.IndexOf('terminate') >= 0, 'disconnect terminates the debuggee');
  Check(S.Finished, 'session finished');
end;

procedure TestSequenceNumbers;
var
  B: TFakeBackend;
  C: TCapture;
  S: TDapSession;
  I: Integer;
  M: TJSONObject;
begin
  NewSession(B, C, S);
  Launch(S, '');
  for I := 0 to C.Messages.Count - 1 do
  begin
    M := C.Message(I);
    Check(M.Integers['seq'] = I + 1, 'outgoing seq ' + IntToStr(I + 1));
    M.Free;
  end;
  M := C.Find('response', 'launch');
  Check(M.Integers['request_seq'] > 0, 'request_seq echoed');
end;

begin
  Failures := 0;
  Checks := 0;
  TestFraming;
  TestFramingIgnoresOtherHeaders;
  TestLaunchHandshake;
  TestStopOnEntry;
  TestLaunchFailure;
  TestBreakpointsReplacedPerFile;
  TestStopsAndSteps;
  TestStackScopesVariablesEvaluate;
  TestDisconnectAndUnknown;
  TestSequenceNumbers;
  WriteLn(Checks - Failures, '/', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
