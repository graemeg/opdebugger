{
  PDR (Pascal Debug Reference) - Main Program

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Command-line debugger for Object Pascal programs using OPDF debug format.
}
program pdr_main;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  ogopdf, pdr_ports, pdr_engine, pdr_typesys, pdr_symbols,
  pdr_linux_ptrace, pdr_arch_adapters, pdr_opdf_adapter;

type
  { CLI Debugger - Simple REPL interface }
  TCLIDebugger = class
  private
    FEngine: TDebuggerEngine;
    FProcessController: IProcessController;
    FDebugInfoReader: IDebugInfoReader;
    FArchAdapter: IArchAdapter;
    FRunning: Boolean;

    procedure PrintHelp;
    procedure ProcessCommand(const CmdLine: String);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Run(const BinaryPath: String);
  end;

{ TCLIDebugger }

constructor TCLIDebugger.Create;
begin
  inherited Create;
  FRunning := True;
end;

destructor TCLIDebugger.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

procedure TCLIDebugger.PrintHelp;
begin
  WriteLn('PDR Debugger Commands:');
  WriteLn('  print <var>    - Print variable value');
  WriteLn('  attach <pid>   - Attach to process');
  WriteLn('  detach         - Detach from process');
  WriteLn('  continue       - Continue execution');
  WriteLn('  step           - Single step');
  WriteLn('  help           - Show this help');
  WriteLn('  quit           - Exit debugger');
  WriteLn;
end;

procedure TCLIDebugger.ProcessCommand(const CmdLine: String);
var
  Parts: TStringArray;
  Cmd: String;
  VarValue: TVariableValue;
  PID: Integer;
begin
  if Trim(CmdLine) = '' then
    Exit;

  Parts := CmdLine.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) = 0 then
    Exit;

  Cmd := LowerCase(Parts[0]);

  case Cmd of
    'help', 'h', '?':
      PrintHelp;

    'quit', 'q', 'exit':
      begin
        WriteLn('Exiting...');
        FRunning := False;
      end;

    'attach':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: attach <pid>');
          Exit;
        end;

        if not TryStrToInt(Parts[1], PID) then
        begin
          WriteLn('[ERROR] Invalid PID: ', Parts[1]);
          Exit;
        end;

        FEngine.Attach(PID);
      end;

    'detach':
      FEngine.Detach;

    'continue', 'c':
      FEngine.Continue;

    'step', 's':
      FEngine.Step;

    'print', 'p':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: print <variable>');
          Exit;
        end;

        VarValue := FEngine.EvaluateExpression(Parts[1]);

        if VarValue.IsValid then
          WriteLn(VarValue.Name, ' = ', VarValue.Value)
        else
          WriteLn('[ERROR] ', VarValue.Value);
      end;

  else
    WriteLn('[ERROR] Unknown command: ', Cmd);
    WriteLn('Type "help" for available commands');
  end;
end;

procedure TCLIDebugger.Run(const BinaryPath: String);
var
  CmdLine: String;
begin
  WriteLn('PDR (Pascal Debug Reference) v0.1.0');
  WriteLn('Copyright (c) 2025 Graeme Geldenhuys');
  WriteLn;

  // Create platform-specific adapters
  FProcessController := TLinuxPtraceAdapter.Create;
  FDebugInfoReader := TOPDFReaderAdapter.Create;

  // Create architecture adapter with process controller
  {$IFDEF CPUX86_64}
  WriteLn('[INFO] Detected architecture: x86_64');
  FArchAdapter := TArchX86_64Adapter.Create(FProcessController);
  {$ENDIF}
  {$IFDEF CPUI386}
  WriteLn('[INFO] Detected architecture: i386');
  FArchAdapter := TArchX86Adapter.Create(FProcessController);
  {$ENDIF}

  // Create debugger engine
  FEngine := TDebuggerEngine.Create(FProcessController, FDebugInfoReader, FArchAdapter);

  // Load program
  if not FEngine.LoadProgram(BinaryPath) then
  begin
    WriteLn('[ERROR] Failed to load program');
    Halt(1);
  end;

  WriteLn('Type "help" for available commands');
  WriteLn;

  // REPL loop
  while FRunning do
  begin
    Write('(pdr) ');
    ReadLn(CmdLine);
    ProcessCommand(CmdLine);
  end;
end;

{ Main program }
var
  BinaryPath: String;
  CLI: TCLIDebugger;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: pdr <binary>');
    WriteLn;
    WriteLn('Debug an Object Pascal program using OPDF debug information.');
    Halt(1);
  end;

  BinaryPath := ParamStr(1);

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Halt(1);
  end;

  CLI := TCLIDebugger.Create;
  try
    CLI.Run(BinaryPath);
  finally
    CLI.Free;
  end;
end.
