{
  PDR Debugger - Debugger Engine

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit implements the core debugger engine that coordinates all components.
}
unit pdr_engine;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, pdr_ports, pdr_typesys;

type
  { Debugger Engine - implements ICommandHandler }
  TDebuggerEngine = class(TInterfacedObject, ICommandHandler)
  private
    FState: TDebuggerState;
    FProcessController: IProcessController;
    FDebugInfoReader: IDebugInfoReader;
    FArchAdapter: IArchAdapter;
    FTypeSystem: TTypeSystem;
    FBinaryPath: String;
    FAttachedPID: Integer;
  public
    constructor Create(AProcessController: IProcessController;
                      ADebugInfoReader: IDebugInfoReader;
                      AArchAdapter: IArchAdapter);
    destructor Destroy; override;

    { ICommandHandler - Session management }
    function LoadProgram(const BinaryPath: String): Boolean;
    function Attach(PID: Integer): Boolean;
    function Detach: Boolean;

    { ICommandHandler - Execution control }
    function Run: Boolean;
    function Continue: Boolean;
    function Step: Boolean;
    function StepOver: Boolean;
    function Pause: Boolean;

    { ICommandHandler - Breakpoints }
    function SetBreakpoint(const Location: String): TBreakpointHandle;
    function RemoveBreakpoint(Handle: TBreakpointHandle): Boolean;

    { ICommandHandler - Inspection }
    function EvaluateExpression(const Expr: String): TVariableValue;
    function GetLocalVariables: TVariableValueArray;
    function GetCallStack: TStringArray;

    { ICommandHandler - State query }
    function GetState: TDebuggerState;

    { Properties }
    property State: TDebuggerState read FState;
    property BinaryPath: String read FBinaryPath;
    property AttachedPID: Integer read FAttachedPID;
  end;

implementation

{ TDebuggerEngine }

constructor TDebuggerEngine.Create(AProcessController: IProcessController;
  ADebugInfoReader: IDebugInfoReader; AArchAdapter: IArchAdapter);
begin
  inherited Create;

  FProcessController := AProcessController;
  FDebugInfoReader := ADebugInfoReader;
  FArchAdapter := AArchAdapter;
  FState := dsIdle;
  FAttachedPID := -1;

  // Create type system with primitive evaluator
  FTypeSystem := TTypeSystem.Create(FProcessController, FDebugInfoReader);
  FTypeSystem.RegisterEvaluator(TPrimitiveEvaluator.Create);
end;

destructor TDebuggerEngine.Destroy;
begin
  if FState <> dsIdle then
    Detach;

  FTypeSystem.Free;
  inherited Destroy;
end;

{ Session management }

function TDebuggerEngine.LoadProgram(const BinaryPath: String): Boolean;
begin
  Result := False;

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Exit;
  end;

  WriteLn('[INFO] Loading program: ', BinaryPath);

  // Load debug information
  if not FDebugInfoReader.Load(BinaryPath) then
  begin
    WriteLn('[ERROR] Failed to load debug information');
    Exit;
  end;

  FBinaryPath := BinaryPath;
  WriteLn('[INFO] Program loaded successfully');
  Result := True;
end;

function TDebuggerEngine.Attach(PID: Integer): Boolean;
begin
  Result := False;

  if FState <> dsIdle then
  begin
    WriteLn('[ERROR] Already attached to a process');
    Exit;
  end;

  WriteLn('[INFO] Attaching to process ', PID, '...');

  if not FProcessController.Attach(PID) then
  begin
    WriteLn('[ERROR] Failed to attach to process');
    Exit;
  end;

  FAttachedPID := PID;
  FState := dsPaused;

  WriteLn('[INFO] Attached to process ', PID);
  Result := True;
end;

function TDebuggerEngine.Detach: Boolean;
begin
  Result := False;

  if FState = dsIdle then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  WriteLn('[INFO] Detaching from process ', FAttachedPID, '...');

  if not FProcessController.Detach then
  begin
    WriteLn('[ERROR] Failed to detach from process');
    Exit;
  end;

  FAttachedPID := -1;
  FState := dsIdle;

  WriteLn('[INFO] Detached successfully');
  Result := True;
end;

{ Execution control }

function TDebuggerEngine.Run: Boolean;
begin
  Result := False;
  WriteLn('[WARNING] Run not implemented yet');
  // TODO: Start process from beginning
end;

function TDebuggerEngine.Continue: Boolean;
begin
  Result := False;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  WriteLn('[INFO] Continuing process...');

  if not FProcessController.Continue then
  begin
    WriteLn('[ERROR] Failed to continue process');
    Exit;
  end;

  FState := dsRunning;
  WriteLn('[INFO] Process resumed');
  Result := True;
end;

function TDebuggerEngine.Step: Boolean;
begin
  Result := False;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  WriteLn('[INFO] Stepping...');

  if not FProcessController.Step then
  begin
    WriteLn('[ERROR] Failed to step');
    Exit;
  end;

  WriteLn('[INFO] Step complete');
  Result := True;
end;

function TDebuggerEngine.StepOver: Boolean;
begin
  Result := False;
  WriteLn('[WARNING] StepOver not implemented yet');
  // TODO: Implement step over (skip function calls)
end;

function TDebuggerEngine.Pause: Boolean;
begin
  Result := False;
  WriteLn('[WARNING] Pause not implemented yet');
  // TODO: Send SIGSTOP to process
end;

{ Breakpoints }

function TDebuggerEngine.SetBreakpoint(const Location: String): TBreakpointHandle;
begin
  Result := -1;
  WriteLn('[WARNING] SetBreakpoint not implemented yet');
  // TODO: Parse location (address or function name) and set breakpoint
end;

function TDebuggerEngine.RemoveBreakpoint(Handle: TBreakpointHandle): Boolean;
begin
  Result := False;
  WriteLn('[WARNING] RemoveBreakpoint not implemented yet');
  // TODO: Remove breakpoint by handle
end;

{ Inspection }

function TDebuggerEngine.EvaluateExpression(const Expr: String): TVariableValue;
begin
  Result.Name := Expr;
  Result.IsValid := False;

  if FState = dsIdle then
  begin
    Result.Value := '<error: not attached to process>';
    Result.TypeName := '<unknown>';
    Exit;
  end;

  // For MVP, we only support simple variable names
  // TODO: Support complex expressions (e.g., MyVar.Field, MyArray[5])
  Result := FTypeSystem.EvaluateVariable(Expr);
end;

function TDebuggerEngine.GetLocalVariables: TVariableValueArray;
begin
  SetLength(Result, 0);
  WriteLn('[WARNING] GetLocalVariables not implemented yet');
  // TODO: Get local variables from current stack frame
end;

function TDebuggerEngine.GetCallStack: TStringArray;
begin
  SetLength(Result, 0);
  WriteLn('[WARNING] GetCallStack not implemented yet');
  // TODO: Walk stack frames using frame pointer
end;

{ State query }

function TDebuggerEngine.GetState: TDebuggerState;
begin
  Result := FState;
end;

end.
