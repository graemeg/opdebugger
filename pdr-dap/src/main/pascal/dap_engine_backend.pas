{
  PDR Debugger - Debug Adapter Protocol backend over TDebuggerEngine

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Wires the platform process controller, the OPDF reader and the
  architecture adapter to a TDebuggerEngine (as pdr-cli does) and maps
  IDebugBackend onto it.
}
unit dap_engine_backend;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, SyncObjs, BaseUnix,
  pdr_ports, pdr_engine,
  {$IF DEFINED(FREEBSD)}
  pdr_freebsd_ptrace,
  {$ELSEIF DEFINED(DARWIN)}
  pdr_macos_mach,
  {$ELSE}
  pdr_linux_ptrace,
  {$IFEND}
  pdr_arch_adapters, pdr_opdf_adapter,
  dap_backend;

type
  {$IF DEFINED(FREEBSD)}
  TPlatformPtraceAdapter = TFreeBSDPtraceAdapter;
  {$ELSEIF DEFINED(DARWIN)}
  TPlatformPtraceAdapter = TMacOSMachAdapter;
  {$ELSE}
  TPlatformPtraceAdapter = TLinuxPtraceAdapter;
  {$IFEND}

  TEngineBackend = class(IDebugBackend)
  private
    FController: TPlatformPtraceAdapter;
    FReader: TOPDFReaderAdapter;
    FArch: IArchAdapter;
    FEngine: TDebuggerEngine;
    { Guards FRunning and FPauseRequested, shared with Pause's thread. }
    FLock: TCriticalSection;
    FRunning: Boolean;
    FPauseRequested: Boolean;
    FCatchExceptions: Boolean;
    procedure SetRunning(ARunning: Boolean);
    function StopAfter(AOk: Boolean; AStepping: Boolean): TStopInfo;
  public
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
    procedure Pause;
    procedure SetCatchExceptions(ACatch: Boolean);
  end;

implementation

{$IFDEF DARWIN}
const
  PT_KILL = 8;

function ptrace(ARequest: cint; APid: pid_t; AAddr: Pointer; AData: cint): cint; cdecl; external 'c';
{$ENDIF}

constructor TEngineBackend.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FCatchExceptions := True;
end;

destructor TEngineBackend.Destroy;
begin
  FLock.Free;
  FEngine.Free;
  inherited Destroy;
end;

function TEngineBackend.Launch(const AProgram: String; const AArgs: array of String; const ACwd: String;
  out AError: String): Boolean;
begin
  Result := False;
  AError := '';
  if not FileExists(AProgram) then
  begin
    AError := 'no such program: ' + AProgram;
    Exit;
  end;
  if (ACwd <> '') and not SetCurrentDir(ACwd) then
  begin
    AError := 'no such working directory: ' + ACwd;
    Exit;
  end;
  FController := TPlatformPtraceAdapter.Create;
  FReader := TOPDFReaderAdapter.Create;
  {$IFDEF CPUX86_64}
  FArch := TArchX86_64Adapter.Create(FController);
  {$ENDIF}
  {$IFDEF CPUI386}
  FArch := TArchX86Adapter.Create(FController);
  {$ENDIF}
  {$IFDEF CPUAARCH64}
  FArch := TArchAArch64Adapter.Create(FController);
  {$ENDIF}
  {$IFDEF CPUARM}
  FArch := TArchARMAdapter.Create(FController);
  {$ENDIF}
  FEngine := TDebuggerEngine.Create(FController, FReader, FArch);
  FEngine.CatchExceptions := FCatchExceptions;
  if not FEngine.LoadProgram(AProgram) then
  begin
    AError := 'cannot load ' + AProgram + ' (no OPDF debug information?)';
    Exit;
  end;
  if Length(AArgs) > 0 then
    FEngine.SetCommandLineArgs(AArgs);
  if not FEngine.Run then
  begin
    AError := 'cannot start ' + AProgram;
    Exit;
  end;
  Result := True;
end;

function TEngineBackend.SetBreakpoint(const APath: String; ALine: Integer;
  const ACondition: String): TBreakpointResult;
var
  H: TBreakpointHandle;
begin
  Result.Line := ALine;
  Result.Message := '';
  Result.Handle := -1;
  H := FEngine.SetBreakpoint(ExtractFileName(APath) + ':' + IntToStr(ALine));
  Result.Verified := H >= 0;
  if not Result.Verified then
  begin
    Result.Message := 'no code at line ' + IntToStr(ALine);
    Exit;
  end;
  Result.Handle := H;
  if (ACondition <> '') and not FEngine.SetBreakpointExprCondition(H, ACondition) then
    Result.Message := 'condition not understood: ' + ACondition;
end;

procedure TEngineBackend.ClearBreakpoint(AHandle: Integer);
begin
  FEngine.RemoveBreakpoint(AHandle);
end;

function TEngineBackend.StopAfter(AOk: Boolean; AStepping: Boolean): TStopInfo;
var
  E: TExceptionInfo;
  Paused: Boolean;
begin
  FLock.Enter;
  Paused := FPauseRequested;
  FPauseRequested := False;
  FLock.Leave;
  if FEngine.State in [dsTerminated, dsIdle] then
    Exit(StopInfo(srExited, '', 0));
  if Paused and AOk then
    Exit(StopInfo(srPause));
  { A step the engine could not take leaves the program where it was. }
  if not AOk then
    Exit(StopInfo(srStep));
  E := FEngine.LastException;
  if E.IsValid then
  begin
    if E.Message <> '' then
      Exit(StopInfo(srException, E.ClassName + ': ' + E.Message))
    else
      Exit(StopInfo(srException, E.ClassName));
  end;
  if AStepping then
    Result := StopInfo(srStep)
  else
    Result := StopInfo(srBreakpoint);
end;

function TEngineBackend.Resume: TStopInfo;
var
  Ok: Boolean;
begin
  SetRunning(True);
  try
    Ok := FEngine.Continue;
  finally
    SetRunning(False);
  end;
  Result := StopAfter(Ok, False);
end;

function TEngineBackend.StepOver: TStopInfo;
var
  Ok: Boolean;
begin
  SetRunning(True);
  try
    Ok := FEngine.StepOver;
  finally
    SetRunning(False);
  end;
  Result := StopAfter(Ok, True);
end;

function TEngineBackend.StepIn: TStopInfo;
var
  Ok: Boolean;
begin
  SetRunning(True);
  try
    Ok := FEngine.StepInto;
  finally
    SetRunning(False);
  end;
  Result := StopAfter(Ok, True);
end;

function TEngineBackend.StepOut: TStopInfo;
var
  Ok: Boolean;
begin
  SetRunning(True);
  try
    Ok := FEngine.StepOut;
  finally
    SetRunning(False);
  end;
  Result := StopAfter(Ok, True);
end;

function TEngineBackend.Frames: TStackFrameArray;
begin
  if (FEngine = nil) or (FEngine.State <> dsPaused) then
    Exit(nil);
  Result := FEngine.GetStackFrames(0);
end;

function TEngineBackend.Locals(AFrame: Integer): TVariableValueArray;
begin
  if (FEngine = nil) or (FEngine.State <> dsPaused) then
    Exit(nil);
  FEngine.SelectFrame(AFrame);
  Result := FEngine.GetLocalVariables;
end;

function TEngineBackend.Globals: TVariableValueArray;
begin
  if (FEngine = nil) or (FEngine.State <> dsPaused) then
    Exit(nil);
  Result := FEngine.GetGlobalVariables;
end;

function TEngineBackend.Evaluate(AFrame: Integer; const AExpr: String): TVariableValue;
begin
  Result.IsValid := False;
  if (FEngine = nil) or (FEngine.State <> dsPaused) then
    Exit;
  FEngine.SelectFrame(AFrame);
  Result := FEngine.EvaluateExpression(AExpr);
end;

procedure TEngineBackend.SetRunning(ARunning: Boolean);
begin
  FLock.Enter;
  FRunning := ARunning;
  FLock.Leave;
end;

procedure TEngineBackend.Pause;
begin
  FLock.Enter;
  try
    { A program already stopped has nothing to interrupt; a SIGSTOP sent
      now would stop it again as soon as it resumed. }
    if FRunning and (FController <> nil) and not FPauseRequested then
    begin
      FPauseRequested := True;
      FController.SendInterrupt;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TEngineBackend.SetCatchExceptions(ACatch: Boolean);
begin
  FCatchExceptions := ACatch;
  if FEngine <> nil then
    FEngine.CatchExceptions := ACatch;
end;

procedure TEngineBackend.Terminate;
begin
  if (FController <> nil) and (FController.PID > 0) and (FEngine.State <> dsTerminated) then
  begin
    { On macOS a tracee stopped under ptrace does not act on SIGKILL until
      it is continued, so the wait below would block: PT_KILL ends it. }
    {$IFDEF DARWIN}
    ptrace(PT_KILL, FController.PID, nil, 0);
    {$ENDIF}
    FpKill(FController.PID, SIGKILL);
    FpWaitPid(FController.PID, nil, 0);
  end;
end;

end.
