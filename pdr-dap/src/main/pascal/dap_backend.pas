{
  PDR Debugger - Debug Adapter Protocol backend port

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  What the DAP session needs from a debugger, so the protocol logic can be
  tested without a debuggee: TEngineBackend implements it over
  TDebuggerEngine, the tests implement it with a script.  Lines are
  1-based, frames are numbered from the innermost (0).
}
unit dap_backend;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, pdr_ports;

type
  TStopReason = (srEntry, srBreakpoint, srStep, srException, srPause, srExited);

  TStopInfo = record
    Reason: TStopReason;
    { Exception class and message, for srException. }
    Text: String;
    ExitCode: Integer;
  end;

  TBreakpointResult = record
    Handle: Integer;
    Verified: Boolean;
    Line: Integer;
    Message: String;
  end;

  IDebugBackend = interface
    { Load AProgram and start it, paused at its entry point. }
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
    { Interrupt the running program; the blocked Resume or step returns
      srPause.  Called on another thread while Resume or a step runs. }
    procedure Pause;
    { Stop when the program raises an exception (the default). }
    procedure SetCatchExceptions(ACatch: Boolean);
  end;

function StopInfo(AReason: TStopReason; const AText: String = ''; AExitCode: Integer = 0): TStopInfo;

implementation

function StopInfo(AReason: TStopReason; const AText: String; AExitCode: Integer): TStopInfo;
begin
  Result.Reason := AReason;
  Result.Text := AText;
  Result.ExitCode := AExitCode;
end;

end.
