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
    FCommandLineArgs: array of String;

    procedure PrintHelp;
    procedure ProcessCommand(const CmdLine: String);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Run(const BinaryPath: String; const Args: array of String);
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
  WriteLn('  run            - Start program (automatically done on launch)');
  WriteLn('  args <args>    - Set command-line arguments for program');
  WriteLn('  print <var>    - Print variable value');
  WriteLn('  attach <pid>   - Attach to running process');
  WriteLn('  detach         - Detach from process');
  WriteLn('  continue, c    - Continue execution');
  WriteLn('  next, n        - Step to next source line');
  WriteLn('  step, s        - Single instruction step');
  WriteLn('  break <loc>    - Set breakpoint at location');
  WriteLn('    Location formats:');
  WriteLn('      file.pas:22        - Source file and line number');
  WriteLn('      0x401000           - Hex address');
  WriteLn('      MyGlobalInt        - Variable name');
  WriteLn('  delete <num>   - Remove breakpoint by number');
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
  BpHandle: TBreakpointHandle;
  BpNum: Integer;
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

    'run', 'r':
      FEngine.Run;

    'args':
      begin
        { Collect all arguments after 'args' command }
        if Length(Parts) > 1 then
        begin
          SetLength(FCommandLineArgs, Length(Parts) - 1);
          for BpNum := 0 to High(FCommandLineArgs) do
            FCommandLineArgs[BpNum] := Parts[BpNum + 1];
          FEngine.SetCommandLineArgs(FCommandLineArgs);
        end
        else
        begin
          WriteLn('[INFO] Usage: args <argument> [<argument> ...]');
          if Length(FCommandLineArgs) > 0 then
            WriteLn('[INFO] Current arguments: ', String.Join(' ', FCommandLineArgs))
          else
            WriteLn('[INFO] No arguments set');
        end;
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

    'next', 'n':
      FEngine.StepLine;

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

    'break', 'b':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: break <location>');
          WriteLn('[INFO] Location can be: hex address (0xNNNN), decimal address, or variable name');
          Exit;
        end;

        BpHandle := FEngine.SetBreakpoint(Parts[1]);
        // Engine already prints success/error messages
      end;

    'delete', 'd':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: delete <breakpoint_number>');
          Exit;
        end;

        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn('[ERROR] Invalid breakpoint number: ', Parts[1]);
          Exit;
        end;

        FEngine.RemoveBreakpoint(BpNum);
        // Engine already prints success/error messages
      end;

  else
    WriteLn('[ERROR] Unknown command: ', Cmd);
    WriteLn('Type "help" for available commands');
  end;
end;

procedure TCLIDebugger.Run(const BinaryPath: String; const Args: array of String);
var
  CmdLine: String;
begin
  WriteLn('PDR (Pascal Debug Reference) v0.1.0');
  WriteLn('Copyright (c) 2025 Graeme Geldenhuys');
  WriteLn;

  // Store command-line arguments
  SetLength(FCommandLineArgs, Length(Args));
  if Length(Args) > 0 then
    Move(Args[0], FCommandLineArgs[0], Length(Args) * SizeOf(String));

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

  // Set command-line arguments if provided at CLI
  if Length(FCommandLineArgs) > 0 then
  begin
    FEngine.SetCommandLineArgs(FCommandLineArgs);
    WriteLn('[INFO] Command-line arguments set: ', String.Join(' ', FCommandLineArgs));
  end;

  WriteLn;

  // Only auto-run if arguments were provided at CLI startup
  // Otherwise, let user set them via 'args' command before 'run'
  if Length(FCommandLineArgs) > 0 then
  begin
    WriteLn('[INFO] Starting program...');
    if not FEngine.Run then
    begin
      WriteLn('[ERROR] Failed to start program');
      Halt(1);
    end;
  end
  else
  begin
    WriteLn('[INFO] No arguments provided. Use "args" command to set them, then "run"');
  end;

  WriteLn;
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
  I: Integer;
  Args: array of String;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: pdr <binary> [<argument> ...]');
    WriteLn;
    WriteLn('Debug an Object Pascal program using OPDF debug information.');
    WriteLn;
    WriteLn('Arguments:');
    WriteLn('  <binary>       - Path to the binary to debug');
    WriteLn('  <argument>     - Command-line arguments to pass to the program');
    WriteLn;
    WriteLn('Examples:');
    WriteLn('  pdr ./myprogram');
    WriteLn('  pdr ./myprogram arg1 arg2 arg3');
    Halt(1);
  end;

  BinaryPath := ParamStr(1);

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Halt(1);
  end;

  { Collect command-line arguments (all parameters after the binary path) }
  if ParamCount > 1 then
  begin
    SetLength(Args, ParamCount - 1);
    for I := 2 to ParamCount do
      Args[I - 2] := ParamStr(I);
  end;

  CLI := TCLIDebugger.Create;
  try
    CLI.Run(BinaryPath, Args);
  finally
    CLI.Free;
  end;
end.
