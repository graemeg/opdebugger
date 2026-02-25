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
  opdf_types, pdr_ports, pdr_engine, pdr_typesys, pdr_symbols,
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
    procedure PrintDisplayList;
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
  WriteLn('  run, r         - Start program (automatically done on launch)');
  WriteLn('  args <args>    - Set command-line arguments for program');
  WriteLn('  print <var>    - Print variable value');
  WriteLn('  callstack [n]  - Show call stack (limit to n frames, 0 for all)');
  WriteLn('  cs [n]         - Alias for callstack');
  WriteLn('  attach <pid>   - Attach to running process');
  WriteLn('  detach         - Detach from process');
  WriteLn('  continue, c    - Continue execution');
  WriteLn('  next, n        - Step to next source line');
  WriteLn('  step, s        - Single instruction step');
  WriteLn('  break <loc>    - Set breakpoint at location');
  WriteLn('  break <loc> if count=N - Set breakpoint that fires on Nth hit');
  WriteLn('    Location formats:');
  WriteLn('      file.pas:22        - Source file and line number');
  WriteLn('      0x401000           - Hex address');
  WriteLn('      MyGlobalInt        - Variable name');
  WriteLn('  condition <num> count=N - Set/change hit-count condition');
  WriteLn('  condition <num>  - Remove condition (make unconditional)');
  WriteLn('  delete <num>   - Remove breakpoint by number');
  WriteLn('  info breakpoints - List all breakpoints with conditions');
  WriteLn('  locals         - List all local variables in current scope');
  WriteLn('  locals globals - Also include global variables');
  WriteLn('  inspect <var>  - Show structured type layout with all fields/properties');
  WriteLn('  set <var> = <value> - Assign a value to a variable');
  WriteLn('  display <expr>  - Auto-print expression on every stop');
  WriteLn('  undisplay <expr> - Remove from auto-display list');
  WriteLn('  undisplay      - Remove all display entries');
  WriteLn('  info display   - List all registered display expressions');
  WriteLn('  watch <var>    - Set write watchpoint (break when variable changes)');
  WriteLn('  rwatch <var>   - Set read/write watchpoint');
  WriteLn('  awatch <var>   - Set access (read/write) watchpoint');
  WriteLn('  unwatch <var>  - Remove watchpoint');
  WriteLn('  info watchpoints - List active watchpoints');
  WriteLn('  verbose [on|off] - Enable/disable diagnostic output (default: off)');
  WriteLn('  help, h        - Show this help');
  WriteLn('  quit, q        - Exit debugger');
  WriteLn;
end;

procedure TCLIDebugger.PrintDisplayList;
var
  DisplayVals: TVariableValueArray;
  I: Integer;
begin
  DisplayVals := FEngine.EvaluateDisplayList;
  for I := 0 to High(DisplayVals) do
    WriteLn(DisplayVals[I].Name, ' = ', DisplayVals[I].Value);
end;

{ Parse "VarName[N..M]" slice notation from a print expression.
  Returns True and fills VarName, LowIdx, HighIdx if the pattern is found. }
function TryParseSlice(const Expr: String; out VarName: String;
                       out LowIdx, HighIdx: Int64): Boolean;
var
  BracketOpen, BracketClose, DotDotPos: Integer;
  IndexStr: String;
begin
  Result := False;
  BracketOpen  := Pos('[', Expr);
  BracketClose := Pos(']', Expr);
  if (BracketOpen = 0) or (BracketClose = 0) or (BracketClose < BracketOpen) then
    Exit;

  IndexStr := Copy(Expr, BracketOpen + 1, BracketClose - BracketOpen - 1);
  DotDotPos := Pos('..', IndexStr);
  if DotDotPos = 0 then Exit;

  VarName := Copy(Expr, 1, BracketOpen - 1);
  if VarName = '' then Exit;

  if not TryStrToInt64(Trim(Copy(IndexStr, 1, DotDotPos - 1)), LowIdx) then Exit;
  if not TryStrToInt64(Trim(Copy(IndexStr, DotDotPos + 2, Length(IndexStr))), HighIdx) then Exit;

  Result := True;
end;

procedure TCLIDebugger.ProcessCommand(const CmdLine: String);
var
  Parts: TStringArray;
  Cmd: String;
  VarValue: TVariableValue;
  PID: Integer;
  BpHandle: TBreakpointHandle;
  BpNum: Integer;
  Limit: Integer;
  CallStack: TStringArray;
  LocalVars: TVariableValueArray;
  GlobalNames: TStringArray;
  SliceResult: TVariableValueArray;
  SliceVarName: String;
  SliceLow, SliceHigh: Int64;
  I: Integer;
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
      begin
        FEngine.Continue;
        PrintDisplayList;
      end;

    'next', 'n':
      begin
        FEngine.StepLine;
        PrintDisplayList;
      end;

    'step', 's':
      begin
        FEngine.Step;
        PrintDisplayList;
      end;

    'print', 'p':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: print <variable>');
          Exit;
        end;

        { Check for array slice notation: VarName[N..M] }
        if TryParseSlice(Parts[1], SliceVarName, SliceLow, SliceHigh) then
        begin
          SliceResult := FEngine.EvaluateArraySlice(SliceVarName, SliceLow, SliceHigh);
          for I := 0 to High(SliceResult) do
          begin
            if SliceResult[I].IsValid then
              WriteLn(SliceResult[I].Name, ' = ', SliceResult[I].Value)
            else
              WriteLn('[ERROR] ', SliceResult[I].Name, ': ', SliceResult[I].Value);
          end;
        end
        else
        begin
          VarValue := FEngine.EvaluateExpression(Parts[1]);

          if VarValue.IsValid then
            WriteLn(VarValue.Name, ' = ', VarValue.Value)
          else
            WriteLn('[ERROR] ', VarValue.Value);
        end;
      end;

    'break', 'b':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: break <location> [if count=N]');
          WriteLn('[INFO] Location can be: hex address (0xNNNN), decimal address, or variable name');
          Exit;
        end;

        BpHandle := FEngine.SetBreakpoint(Parts[1]);

        { Check for 'if count=N' condition }
        if (BpHandle >= 0) and (Length(Parts) >= 4) and
           (LowerCase(Parts[2]) = 'if') then
        begin
          if (Length(Parts[3]) > 6) and
             (LowerCase(Copy(Parts[3], 1, 6)) = 'count=') then
          begin
            if TryStrToInt(Copy(Parts[3], 7, Length(Parts[3])), BpNum) and
               (BpNum > 0) then
              FEngine.SetBreakpointCondition(BpHandle, bctHitCount, BpNum)
            else
              WriteLn('[ERROR] Invalid hit count: ', Copy(Parts[3], 7, Length(Parts[3])));
          end
          else
            WriteLn('[ERROR] Unsupported condition: ', Parts[3],
                    '. Use: count=N');
        end;
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

    'condition', 'cond':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: condition <bp-num> [count=N]');
          Exit;
        end;

        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn('[ERROR] Invalid breakpoint number: ', Parts[1]);
          Exit;
        end;

        if Length(Parts) >= 3 then
        begin
          { Set condition: condition N count=K }
          if (Length(Parts[2]) > 6) and
             (LowerCase(Copy(Parts[2], 1, 6)) = 'count=') then
          begin
            if TryStrToInt(Copy(Parts[2], 7, Length(Parts[2])), Limit) and
               (Limit > 0) then
              FEngine.SetBreakpointCondition(BpNum, bctHitCount, Limit)
            else
              WriteLn('[ERROR] Invalid hit count: ', Copy(Parts[2], 7, Length(Parts[2])));
          end
          else
            WriteLn('[ERROR] Unsupported condition: ', Parts[2],
                    '. Use: count=N');
        end
        else
        begin
          { Remove condition: condition N }
          FEngine.SetBreakpointCondition(BpNum, bctNone, 0);
        end;
      end;

    'info':
      begin
        if (Length(Parts) >= 2) and
           ((LowerCase(Parts[1]) = 'breakpoints') or
            (LowerCase(Parts[1]) = 'break') or
            (LowerCase(Parts[1]) = 'b')) then
        begin
          CallStack := FEngine.GetBreakpointList;
          if Length(CallStack) = 0 then
            WriteLn('[INFO] No breakpoints set')
          else
          begin
            WriteLn('[BREAKPOINTS]');
            for I := 0 to High(CallStack) do
              WriteLn(CallStack[I]);
          end;
        end
        else if (Length(Parts) >= 2) and
                (LowerCase(Parts[1]) = 'display') then
        begin
          CallStack := FEngine.GetDisplayList;
          if Length(CallStack) = 0 then
            WriteLn('[INFO] No display expressions set')
          else
          begin
            WriteLn('[DISPLAY]');
            for I := 0 to High(CallStack) do
              WriteLn('  ', I + 1, ': ', CallStack[I]);
          end;
        end
        else if (Length(Parts) >= 2) and
                ((LowerCase(Parts[1]) = 'watchpoints') or
                 (LowerCase(Parts[1]) = 'watch') or
                 (LowerCase(Parts[1]) = 'w')) then
        begin
          CallStack := FEngine.GetWatchpointList;
          if Length(CallStack) = 0 then
            WriteLn('[INFO] No watchpoints set')
          else
          begin
            WriteLn('[WATCHPOINTS]');
            for I := 0 to High(CallStack) do
              WriteLn('  ', CallStack[I]);
          end;
        end
        else
          WriteLn('[ERROR] Usage: info breakpoints | info display | info watchpoints');
      end;

    'callstack', 'cs':
      begin
        { Initialize limit to 0 (no limit) }
        Limit := 0;

        { Parse optional limit parameter }
        if Length(Parts) > 1 then
        begin
          if not TryStrToInt(Parts[1], Limit) or (Limit < 0) then
          begin
            WriteLn('[ERROR] Invalid limit: ', Parts[1]);
            WriteLn('[INFO] Usage: callstack [n] where n >= 0 (0 = no limit)');
            Exit;
          end;
        end;

        { Get call stack with optional limit }
        CallStack := FEngine.GetCallStack(Limit);

        if Length(CallStack) = 0 then
        begin
          WriteLn('[INFO] No call stack available');
        end
        else
        begin
          WriteLn('[CALLSTACK]');
          for I := 0 to High(CallStack) do
            WriteLn(CallStack[I]);
        end;
      end;

    'locals', 'lo':
      begin
        LocalVars := FEngine.GetLocalVariables;

        if Length(LocalVars) = 0 then
          WriteLn('[INFO] No local variables in current scope')
        else
          for I := 0 to High(LocalVars) do
          begin
            if LocalVars[I].IsValid then
              WriteLn(LocalVars[I].Name, ' = ', LocalVars[I].Value)
            else
              WriteLn('[WARN] ', LocalVars[I].Name, ': ', LocalVars[I].Value);
          end;

        { 'locals globals' also lists global variables }
        if (Length(Parts) > 1) and (LowerCase(Parts[1]) = 'globals') then
        begin
          GlobalNames := FDebugInfoReader.GetGlobalVariables;
          for I := 0 to High(GlobalNames) do
          begin
            VarValue := FEngine.EvaluateExpression(GlobalNames[I]);
            if VarValue.IsValid then
              WriteLn(VarValue.Name, ' = ', VarValue.Value)
            else if gVerbose then
              WriteLn('[DEBUG] ', VarValue.Name, ': ', VarValue.Value);
          end;
        end;
      end;

    'inspect', 'ins':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: inspect <variable>');
          Exit;
        end;

        CallStack := FEngine.GetInspectLines(Parts[1]);

        if Length(CallStack) = 0 then
          WriteLn('[INFO] No information available for: ', Parts[1])
        else
          for I := 0 to High(CallStack) do
            WriteLn(CallStack[I]);
      end;

    'set':
      begin
        { Format: set VarName = Value }
        if Length(Parts) < 4 then
        begin
          WriteLn('[ERROR] Usage: set <variable> = <value>');
          Exit;
        end;

        if Parts[2] <> '=' then
        begin
          WriteLn('[ERROR] Usage: set <variable> = <value>');
          Exit;
        end;

        { Reconstruct value in case it contains spaces }
        VarValue.Name := Parts[1];
        VarValue.Value := Parts[3];
        if Length(Parts) > 4 then
        begin
          I := 4;
          while I <= High(Parts) do
          begin
            VarValue.Value := VarValue.Value + ' ' + Parts[I];
            Inc(I);
          end;
        end;

        FEngine.SetVariable(Parts[1], VarValue.Value);
      end;

    'display':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: display <expression>');
          Exit;
        end;
        FEngine.AddDisplay(Parts[1]);
      end;

    'undisplay':
      begin
        if Length(Parts) >= 2 then
          FEngine.RemoveDisplay(Parts[1])
        else
          FEngine.ClearDisplay;
      end;

    'watch':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: watch <variable>');
          Exit;
        end;
        FEngine.SetWatch(Parts[1], wtWrite);
      end;

    'rwatch', 'awatch':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: ', Cmd, ' <variable>');
          Exit;
        end;
        FEngine.SetWatch(Parts[1], wtReadWrite);
      end;

    'unwatch':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn('[ERROR] Usage: unwatch <variable>');
          Exit;
        end;
        FEngine.RemoveWatch(Parts[1]);
      end;

    'verbose', 'v':
      begin
        if (Length(Parts) > 1) and
           ((LowerCase(Parts[1]) = 'off') or (LowerCase(Parts[1]) = 'false') or (Parts[1] = '0')) then
        begin
          gVerbose := False;
          WriteLn('[INFO] Verbose mode off');
        end
        else if (Length(Parts) > 1) and
                ((LowerCase(Parts[1]) = 'on') or (LowerCase(Parts[1]) = 'true') or (Parts[1] = '1')) then
        begin
          gVerbose := True;
          WriteLn('[INFO] Verbose mode on');
        end
        else
          WriteLn('[INFO] Verbose mode is ', BoolToStr(gVerbose, 'on', 'off'),
                  '. Use: verbose on|off');
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
  WriteLn('PDR (Pascal Debug Reference) v0.2.0');
  WriteLn('Copyright (c) 2025-2026 Graeme Geldenhuys');
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
  if gVerbose then
    WriteLn('[INFO] Detected architecture: x86_64');
  FArchAdapter := TArchX86_64Adapter.Create(FProcessController);
  {$ENDIF}
  {$IFDEF CPUI386}
  if gVerbose then
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
  FirstArg: Integer;
begin
  { Scan for --verbose / -v flag (may appear before the binary path) }
  FirstArg := 1;
  for I := 1 to ParamCount do
  begin
    if (ParamStr(I) = '--verbose') or (ParamStr(I) = '-v') then
    begin
      gVerbose := True;
      if I = FirstArg then
        Inc(FirstArg);
    end;
  end;

  if ParamCount < FirstArg then
  begin
    WriteLn('Usage: pdr [--verbose] <binary> [<argument> ...]');
    WriteLn;
    WriteLn('Debug an Object Pascal program using OPDF debug information.');
    WriteLn;
    WriteLn('Options:');
    WriteLn('  --verbose, -v  - Enable diagnostic output at startup');
    WriteLn;
    WriteLn('Arguments:');
    WriteLn('  <binary>       - Path to the binary to debug');
    WriteLn('  <argument>     - Command-line arguments to pass to the program');
    WriteLn;
    WriteLn('Examples:');
    WriteLn('  pdr ./myprogram');
    WriteLn('  pdr --verbose ./myprogram');
    WriteLn('  pdr ./myprogram arg1 arg2 arg3');
    Halt(1);
  end;

  BinaryPath := ParamStr(FirstArg);

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Halt(1);
  end;

  { Collect command-line arguments (all parameters after the binary path) }
  if ParamCount > FirstArg then
  begin
    SetLength(Args, ParamCount - FirstArg);
    for I := FirstArg + 1 to ParamCount do
      Args[I - FirstArg - 1] := ParamStr(I);
  end;

  CLI := TCLIDebugger.Create;
  try
    CLI.Run(BinaryPath, Args);
  finally
    CLI.Free;
  end;
end.
