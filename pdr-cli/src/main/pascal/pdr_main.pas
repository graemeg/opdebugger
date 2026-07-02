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
  {$IFDEF FREEBSD}
  pdr_freebsd_ptrace,
  {$ELSE}
  pdr_linux_ptrace,
  {$ENDIF}
  pdr_arch_adapters, pdr_opdf_adapter;

type
  { Platform process-controller selection.  Both adapters expose the same
    surface (IProcessController plus a RedirectChildIO property), so the
    construction code below stays platform-agnostic via this alias. }
  {$IFDEF FREEBSD}
  TPlatformPtraceAdapter = TFreeBSDPtraceAdapter;
  {$ELSE}
  TPlatformPtraceAdapter = TLinuxPtraceAdapter;
  {$ENDIF}

{$IFDEF UNIX}
function c_isatty(fd: LongInt): LongInt; cdecl; external 'c' name 'isatty';
{$ENDIF}

const
  PDR_VERSION = {$I version.inc};
  PDR_BUILD_DATE = {$I %DATE%};

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

    FQuiet: Boolean;
    FBatch: Boolean;
    { True when output is being consumed by a machine rather than shown to a
      person: --batch, or a --source script driving the session.  In this mode
      the startup banner and the '(pdr) ' prompt are suppressed (matching GDB's
      batch mode), so captured/piped output carries only command results.  Use
      'pdr --version' to stamp the version into a log. }
    FNonInteractive: Boolean;

    { Pending input lines for the current driver (a --source script).  When
      non-empty, NextInputLine pulls from here so that multi-line sub-blocks
      like 'commands N ... end' read from the SAME source as the surrounding
      commands, rather than falling through to stdin.  Empty in interactive /
      piped-stdin mode, where NextInputLine reads stdin directly. }
    FInputLines: TStringArray;
    FInputPos: Integer;

    function NextInputLine(out ALine: String): Boolean;

    procedure PrintHelp;
    procedure PrintDisplayList;
    procedure PrintExceptionInfo;
    procedure RunBreakpointCommands;
    function HandleListCommand(const Parts: TStringArray): TStringArray;
    function ProcessCommand(const CmdLine: String): Boolean;
    function ExecuteScript(const Filename: String): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Run(const BinaryPath: String; const Args: array of String;
      const ExCommands: array of String; const SourceFiles: array of String);
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

procedure PrintCommandHelp; forward;

procedure TCLIDebugger.PrintHelp;
begin
  PrintCommandHelp;
end;

procedure PrintCommandHelp;
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
  WriteLn('  next, n        - Step over: next source line, skipping into calls');
  WriteLn('  step, s        - Step into: next source line, descending into calls');
  WriteLn('  finish, fin    - Step out: run until current function returns');
  WriteLn('  until, u       - Continue until past current line');
  WriteLn('  until <loc>    - Continue until location (tbreak + continue)');
  WriteLn('  list, l        - Show source around current stop location');
  WriteLn('  list file:N    - Show source around line N of file');
  WriteLn('  up             - Select caller frame (move up the call stack)');
  WriteLn('  down           - Select callee frame (move down the call stack)');
  WriteLn('  frame <N>      - Select frame N (0 = innermost/current)');
  WriteLn('  break <loc>    - Set breakpoint at location');
  WriteLn('  tbreak <loc>   - Set temporary breakpoint (auto-removed after first hit)');
  WriteLn('  break <loc> if count=N - Set breakpoint that fires on Nth hit');
  WriteLn('    Location formats:');
  WriteLn('      file.pas:22        - Source file and line number');
  WriteLn('      0x401000           - Hex address');
  WriteLn('      MyFunction         - Function name');
  WriteLn('      MyGlobalInt        - Variable name');
  WriteLn('  condition <num> count=N - Set/change hit-count condition');
  WriteLn('  condition <num>  - Remove condition (make unconditional)');
  WriteLn('  enable <num>   - Enable a disabled breakpoint');
  WriteLn('  disable <num>  - Disable breakpoint without deleting');
  WriteLn('  delete <num>   - Remove breakpoint by number');
  WriteLn('  info breakpoints - List all breakpoints with conditions');
  WriteLn('  info registers - Show CPU register values');
  WriteLn('  locals         - List local variables in current function');
  WriteLn('  locals scoped  - Include variables from enclosing scopes');
  WriteLn('  globals (gl)   - List global (program-level) variables');
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
  WriteLn('  catch          - Enable break on exception raise (default: on)');
  WriteLn('  nocatch        - Disable break on exception raise');
  WriteLn('  return [value] - Force return from current function');
  WriteLn('  source <file>  - Execute commands from a script file');
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

procedure TCLIDebugger.PrintExceptionInfo;
var
  Exc: TExceptionInfo;
begin
  Exc := FEngine.LastException;
  if not Exc.IsValid then
    Exit;
  if Exc.Message <> '' then
    WriteLn('Exception: ', Exc.ClassName, ' — ''', Exc.Message, '''')
  else
    WriteLn('Exception: ', Exc.ClassName, ' — (no message)');
  if Exc.SourceFile <> '' then
    WriteLn('  raised at ', Exc.SourceFile, ':', Exc.SourceLine)
  else if Exc.RaiseAddr <> 0 then
    WriteLn('  raised at $', HexStr(Exc.RaiseAddr, 16));
end;

procedure TCLIDebugger.RunBreakpointCommands;
var
  Cmds: TStringArray;
  I: Integer;
begin
  if FEngine.GetState <> dsPaused then
    Exit;
  Cmds := FEngine.GetHitBreakpointCommands;
  for I := 0 to High(Cmds) do
  begin
    if FEngine.GetState <> dsPaused then
      Break;
    ProcessCommand(Cmds[I]);
  end;
end;

function TCLIDebugger.HandleListCommand(const Parts: TStringArray): TStringArray;
var
  LineInfo: TLineInfo;
  ColonPos: Integer;
  FileName: String;
  LineNum: Integer;
  CurrentAddr: QWord;
begin
  SetLength(Result, 0);
  if Length(Parts) > 1 then
  begin
    ColonPos := Pos(':', Parts[1]);
    if ColonPos > 0 then
    begin
      FileName := Copy(Parts[1], 1, ColonPos - 1);
      if not TryStrToInt(Copy(Parts[1], ColonPos + 1, Length(Parts[1])), LineNum) then
      begin
        SetLength(Result, 1);
        Result[0] := '[ERROR] Invalid line number: ' + Copy(Parts[1], ColonPos + 1, Length(Parts[1]));
        Exit;
      end;
    end
    else
    begin
      SetLength(Result, 1);
      Result[0] := '[ERROR] Usage: list [file.pas:line]';
      Exit;
    end;
  end
  else
  begin
    if FEngine.State <> dsPaused then
    begin
      SetLength(Result, 1);
      Result[0] := '[ERROR] Process is not paused (use: list file.pas:line)';
      Exit;
    end;

    CurrentAddr := FEngine.GetSelectedFrameRIP;
    if CurrentAddr = 0 then
    begin
      SetLength(Result, 1);
      Result[0] := '[ERROR] Cannot determine current address';
      Exit;
    end;

    if not FDebugInfoReader.FindLineByAddress(CurrentAddr, LineInfo) then
    begin
      SetLength(Result, 1);
      Result[0] := '[ERROR] No source information for current address';
      Exit;
    end;
    FileName := LineInfo.FileName;
    LineNum := LineInfo.LineNumber;
  end;

  Result := FEngine.GetSourceLines(FileName, LineNum);
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

  VarName := Copy(Expr, 1, BracketOpen - 1);
  if VarName = '' then Exit;

  DotDotPos := Pos('..', IndexStr);
  if DotDotPos = 0 then
  begin
    { Single index: VarName[N] → treat as VarName[N..N] }
    if not TryStrToInt64(Trim(IndexStr), LowIdx) then Exit;
    HighIdx := LowIdx;
  end
  else
  begin
    if not TryStrToInt64(Trim(Copy(IndexStr, 1, DotDotPos - 1)), LowIdx) then Exit;
    if not TryStrToInt64(Trim(Copy(IndexStr, DotDotPos + 2, Length(IndexStr))), HighIdx) then Exit;
  end;

  Result := True;
end;

{ Pull the next input line.  Prefers FInputLines (a loaded --source script) so
  that sub-blocks read from the same source as their surrounding commands; only
  when the buffer is exhausted does it fall back to stdin (interactive / piped).
  Returns False at end of input. }
function TCLIDebugger.NextInputLine(out ALine: String): Boolean;
begin
  if FInputPos <= High(FInputLines) then
  begin
    ALine := FInputLines[FInputPos];
    Inc(FInputPos);
    Result := True;
    Exit;
  end;
  if EOF then
  begin
    ALine := '';
    Result := False;
    Exit;
  end;
  ReadLn(ALine);
  Result := True;
end;

function TCLIDebugger.ExecuteScript(const Filename: String): Boolean;
var
  ScriptFile: TextFile;
  Line: String;
  SavedLines: TStringArray;
  SavedPos: Integer;
begin
  Result := True;
  if not FileExists(Filename) then
  begin
    WriteLn(StdErr, '[ERROR] Script file not found: ', Filename);
    Result := False;
    Exit;
  end;

  { Load the whole script into the input buffer so that 'commands N ... end'
    and other multi-line sub-blocks inside ProcessCommand read their lines
    from the script (via NextInputLine), not from stdin.  Save/restore any
    outer buffer so nested --source invocations compose. }
  SavedLines := FInputLines;
  SavedPos := FInputPos;
  SetLength(FInputLines, 0);
  FInputPos := 0;

  AssignFile(ScriptFile, Filename);
  Reset(ScriptFile);
  try
    while not EOF(ScriptFile) do
    begin
      ReadLn(ScriptFile, Line);
      SetLength(FInputLines, Length(FInputLines) + 1);
      FInputLines[High(FInputLines)] := Line;
    end;
  finally
    CloseFile(ScriptFile);
  end;

  try
    while NextInputLine(Line) do
    begin
      Line := Trim(Line);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if not FNonInteractive then
        WriteLn('(pdr) ', Line);
      if not ProcessCommand(Line) then
      begin
        Result := False;
        Exit;
      end;
    end;
  finally
    FInputLines := SavedLines;
    FInputPos := SavedPos;
  end;
end;

function TCLIDebugger.ProcessCommand(const CmdLine: String): Boolean;
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
  SliceResult: TVariableValueArray;
  SliceVarName: String;
  SliceLow, SliceHigh: Int64;
  Regs: TRegisters;
  LineInfo: TLineInfo;
  LineEntries: TLineInfoArray;
  CurrentAddr: QWord;
  FoundNextLine: Boolean;
  I: Integer;
  CmdList: TStringArray;
  Line: String;
begin
  Result := True;

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
        WriteLn(StdErr, 'Exiting...');
        FRunning := False;
        Result := False;
      end;

    'run', 'r':
      begin
        FEngine.Run;
        PrintExceptionInfo;
      end;

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
          WriteLn(StdErr, '[INFO] Usage: args <argument> [<argument> ...]');
          if Length(FCommandLineArgs) > 0 then
            WriteLn(StdErr, '[INFO] Current arguments: ', String.Join(' ', FCommandLineArgs))
          else
            WriteLn(StdErr, '[INFO] No arguments set');
        end;
      end;

    'attach':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: attach <pid>');
          Exit;
        end;

        if not TryStrToInt(Parts[1], PID) then
        begin
          WriteLn(StdErr, '[ERROR] Invalid PID: ', Parts[1]);
          Exit;
        end;

        FEngine.Attach(PID);
      end;

    'detach':
      FEngine.Detach;

    'continue', 'c':
      begin
        FEngine.Continue;
        PrintExceptionInfo;
        PrintDisplayList;
        RunBreakpointCommands;
      end;

    'next', 'n':
      begin
        FEngine.StepLine;
        PrintExceptionInfo;
        PrintDisplayList;
      end;

    'step', 's':
      begin
        FEngine.StepInto;
        PrintExceptionInfo;
        PrintDisplayList;
      end;

    'finish', 'fin':
      begin
        FEngine.StepOut;
        PrintExceptionInfo;
        PrintDisplayList;
      end;

    'until', 'u':
      begin
        if Length(Parts) >= 2 then
        begin
          BpHandle := FEngine.SetBreakpoint(Parts[1]);
          if BpHandle >= 0 then
          begin
            FEngine.SetTemporary(BpHandle);
            FEngine.Continue;
            PrintExceptionInfo;
            PrintDisplayList;
            RunBreakpointCommands;
          end;
        end
        else
        begin
          { No argument: continue until past current line }
          CurrentAddr := FEngine.GetSelectedFrameRIP;
          if (CurrentAddr <> 0) and
             FDebugInfoReader.FindLineByAddress(CurrentAddr, LineInfo) then
          begin
            { Find the next line after current in the same file }
            LineEntries := FDebugInfoReader.GetFileLineEntries(LineInfo.FileName);
            FoundNextLine := False;
            for I := 0 to High(LineEntries) do
            begin
              if LineEntries[I].LineNumber > LineInfo.LineNumber then
              begin
                BpHandle := FEngine.SetBreakpoint('0x' + IntToHex(LineEntries[I].Address, 1));
                if BpHandle >= 0 then
                begin
                  FEngine.SetTemporary(BpHandle);
                  FEngine.Continue;
                  PrintExceptionInfo;
                  PrintDisplayList;
                  RunBreakpointCommands;
                  FoundNextLine := True;
                end;
                Break;
              end;
            end;
            if not FoundNextLine then
              WriteLn(StdErr, '[ERROR] No subsequent line found');
          end
          else
            WriteLn(StdErr, '[ERROR] Cannot determine current line');
        end;
      end;

    'up':
      FEngine.FrameUp;

    'down':
      FEngine.FrameDown;

    'frame':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: frame <number>');
          Exit;
        end;
        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn(StdErr, '[ERROR] Invalid frame number: ', Parts[1]);
          Exit;
        end;
        FEngine.SelectFrame(BpNum);
      end;

    'print', 'p':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: print <expression>');
          Exit;
        end;

        { Reconstruct full expression: everything after the command word }
        I := Length(Parts[0]) + 1;
        while (I <= Length(CmdLine)) and (CmdLine[I] in [' ', #9]) do
          Inc(I);
        VarValue.Name := Copy(CmdLine, I, Length(CmdLine) - I + 1);

        { Check for array slice notation: VarName[N..M] }
        if TryParseSlice(VarValue.Name, SliceVarName, SliceLow, SliceHigh) then
        begin
          SliceResult := FEngine.EvaluateArraySlice(SliceVarName, SliceLow, SliceHigh);
          for I := 0 to High(SliceResult) do
          begin
            if SliceResult[I].IsValid then
              WriteLn(SliceResult[I].Name, ' = ', SliceResult[I].Value)
            else
              WriteLn(StdErr, '[ERROR] ', SliceResult[I].Name, ': ', SliceResult[I].Value);
          end;
        end
        else
        begin
          VarValue := FEngine.EvaluateExpression(VarValue.Name);

          if VarValue.IsValid then
            WriteLn(VarValue.Name, ' = ', VarValue.Value)
          else
            WriteLn(StdErr, '[ERROR] ', VarValue.Value);
        end;
      end;

    'tbreak', 'tb':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: tbreak <location>');
          Exit;
        end;
        BpHandle := FEngine.SetBreakpoint(Parts[1]);
        if BpHandle >= 0 then
          FEngine.SetTemporary(BpHandle);
      end;

    'break', 'b':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: break <location> [if <expr>]');
          WriteLn(StdErr, '[INFO] Location can be: hex address (0xNNNN), decimal address, or variable name');
          Exit;
        end;

        BpHandle := FEngine.SetBreakpoint(Parts[1]);

        { Check for 'if ...' condition }
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
              WriteLn(StdErr, '[ERROR] Invalid hit count: ', Copy(Parts[3], 7, Length(Parts[3])));
          end
          else
          begin
            { Expression condition: extract everything after 'if' from CmdLine }
            I := Pos(' if ', LowerCase(CmdLine));
            if I > 0 then
              FEngine.SetBreakpointExprCondition(BpHandle,
                Trim(Copy(CmdLine, I + 4, Length(CmdLine))));
          end;
        end;
      end;

    'enable':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: enable <breakpoint_number>');
          Exit;
        end;
        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn(StdErr, '[ERROR] Invalid breakpoint number: ', Parts[1]);
          Exit;
        end;
        FEngine.EnableBreakpoint(BpNum);
      end;

    'disable':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: disable <breakpoint_number>');
          Exit;
        end;
        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn(StdErr, '[ERROR] Invalid breakpoint number: ', Parts[1]);
          Exit;
        end;
        FEngine.DisableBreakpoint(BpNum);
      end;

    'delete', 'd':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: delete <breakpoint_number>');
          Exit;
        end;

        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn(StdErr, '[ERROR] Invalid breakpoint number: ', Parts[1]);
          Exit;
        end;

        FEngine.RemoveBreakpoint(BpNum);
        // Engine already prints success/error messages
      end;

    'condition', 'cond':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: condition <bp-num> [count=N | <expr>]');
          Exit;
        end;

        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn(StdErr, '[ERROR] Invalid breakpoint number: ', Parts[1]);
          Exit;
        end;

        if Length(Parts) >= 3 then
        begin
          if (Length(Parts[2]) > 6) and
             (LowerCase(Copy(Parts[2], 1, 6)) = 'count=') then
          begin
            if TryStrToInt(Copy(Parts[2], 7, Length(Parts[2])), Limit) and
               (Limit > 0) then
              FEngine.SetBreakpointCondition(BpNum, bctHitCount, Limit)
            else
              WriteLn(StdErr, '[ERROR] Invalid hit count: ', Copy(Parts[2], 7, Length(Parts[2])));
          end
          else
          begin
            { Expression condition: everything after bp-num }
            I := Pos(Parts[1], CmdLine);
            if I > 0 then
            begin
              I := I + Length(Parts[1]);
              FEngine.SetBreakpointExprCondition(BpNum,
                Trim(Copy(CmdLine, I, Length(CmdLine))));
            end;
          end;
        end
        else
        begin
          { Remove condition: condition N }
          FEngine.SetBreakpointCondition(BpNum, bctNone, 0);
        end;
      end;

    'commands':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: commands <bp-num>');
          Exit;
        end;

        if not TryStrToInt(Parts[1], BpNum) then
        begin
          WriteLn(StdErr, '[ERROR] Invalid breakpoint number: ', Parts[1]);
          Exit;
        end;

        { Read command lines until 'end'.  NextInputLine pulls from the active
          --source script when one is driving, so the block is collected from
          the same source as the 'commands' line itself; in interactive mode it
          falls back to stdin and the '  > ' sub-prompt guides the user. }
        SetLength(CmdList, 0);
        if FInputPos > High(FInputLines) then
          Write('  > ');
        while NextInputLine(Line) do
        begin
          Line := Trim(Line);
          if LowerCase(Line) = 'end' then
            Break;
          SetLength(CmdList, Length(CmdList) + 1);
          CmdList[High(CmdList)] := Line;
          if FInputPos > High(FInputLines) then
            Write('  > ');
        end;
        FEngine.SetBreakpointCommands(BpNum, CmdList);
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
            WriteLn(StdErr, '[INFO] No breakpoints set')
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
            WriteLn(StdErr, '[INFO] No display expressions set')
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
            WriteLn(StdErr, '[INFO] No watchpoints set')
          else
          begin
            WriteLn('[WATCHPOINTS]');
            for I := 0 to High(CallStack) do
              WriteLn('  ', CallStack[I]);
          end;
        end
        else if (Length(Parts) >= 2) and
                ((LowerCase(Parts[1]) = 'registers') or
                 (LowerCase(Parts[1]) = 'reg')) then
        begin
          if FEngine.State <> dsPaused then
            WriteLn(StdErr, '[ERROR] Process is not paused')
          else
          begin
            if FProcessController.GetRegisters(Regs) then
            begin
              {$IFDEF CPUX86_64}
              WriteLn('  RAX = 0x', IntToHex(Regs.RAX, 16), '    RBX = 0x', IntToHex(Regs.RBX, 16));
              WriteLn('  RCX = 0x', IntToHex(Regs.RCX, 16), '    RDX = 0x', IntToHex(Regs.RDX, 16));
              WriteLn('  RSI = 0x', IntToHex(Regs.RSI, 16), '    RDI = 0x', IntToHex(Regs.RDI, 16));
              WriteLn('  RBP = 0x', IntToHex(Regs.RBP, 16), '    RSP = 0x', IntToHex(Regs.RSP, 16));
              WriteLn('  R8  = 0x', IntToHex(Regs.R8, 16),  '    R9  = 0x', IntToHex(Regs.R9, 16));
              WriteLn('  R10 = 0x', IntToHex(Regs.R10, 16), '    R11 = 0x', IntToHex(Regs.R11, 16));
              WriteLn('  R12 = 0x', IntToHex(Regs.R12, 16), '    R13 = 0x', IntToHex(Regs.R13, 16));
              WriteLn('  R14 = 0x', IntToHex(Regs.R14, 16), '    R15 = 0x', IntToHex(Regs.R15, 16));
              WriteLn('  RIP = 0x', IntToHex(Regs.RIP, 16), '    RFLAGS = 0x', IntToHex(Regs.RFLAGS, 16));
              {$ENDIF}
              {$IFDEF CPUI386}
              WriteLn('  EAX = 0x', IntToHex(Regs.EAX, 8), '    EBX = 0x', IntToHex(Regs.EBX, 8));
              WriteLn('  ECX = 0x', IntToHex(Regs.ECX, 8), '    EDX = 0x', IntToHex(Regs.EDX, 8));
              WriteLn('  ESI = 0x', IntToHex(Regs.ESI, 8), '    EDI = 0x', IntToHex(Regs.EDI, 8));
              WriteLn('  EBP = 0x', IntToHex(Regs.EBP, 8), '    ESP = 0x', IntToHex(Regs.ESP, 8));
              WriteLn('  EIP = 0x', IntToHex(Regs.EIP, 8), '    EFLAGS = 0x', IntToHex(Regs.EFLAGS, 8));
              {$ENDIF}
            end
            else
              WriteLn(StdErr, '[ERROR] Failed to read registers');
          end;
        end
        else
          WriteLn(StdErr, '[ERROR] Usage: info breakpoints | info display | info watchpoints | info registers');
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
            WriteLn(StdErr, '[ERROR] Invalid limit: ', Parts[1]);
            WriteLn(StdErr, '[INFO] Usage: callstack [n] where n >= 0 (0 = no limit)');
            Exit;
          end;
        end;

        { Get call stack with optional limit }
        CallStack := FEngine.GetCallStack(Limit);

        if Length(CallStack) = 0 then
        begin
          WriteLn(StdErr, '[INFO] No call stack available');
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
        { 'locals scoped' includes enclosing scope variables (nested procedures) }
        if (Length(Parts) > 1) and (LowerCase(Parts[1]) = 'scoped') then
          LocalVars := FEngine.GetLocalVariablesWithParents
        else
          LocalVars := FEngine.GetLocalVariables;

        if Length(LocalVars) = 0 then
          WriteLn(StdErr, '[INFO] No local variables in current scope')
        else
          for I := 0 to High(LocalVars) do
          begin
            if LocalVars[I].IsValid then
              WriteLn(LocalVars[I].Name, ' = ', LocalVars[I].Value)
            else
              WriteLn(StdErr, '[WARN] ', LocalVars[I].Name, ': ', LocalVars[I].Value);
          end;
      end;

    'globals', 'gl':
      begin
        LocalVars := FEngine.GetGlobalVariables;
        if Length(LocalVars) = 0 then
          WriteLn(StdErr, '[INFO] No global variables found')
        else
          for I := 0 to High(LocalVars) do
          begin
            if LocalVars[I].IsValid then
              WriteLn(LocalVars[I].Name, ' = ', LocalVars[I].Value)
            else
              WriteLn(StdErr, '[WARN] ', LocalVars[I].Name, ': ', LocalVars[I].Value);
          end;
      end;

    'inspect', 'ins':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: inspect <variable>');
          Exit;
        end;

        CallStack := FEngine.GetInspectLines(Parts[1]);

        if Length(CallStack) = 0 then
          WriteLn(StdErr, '[INFO] No information available for: ', Parts[1])
        else
          for I := 0 to High(CallStack) do
            WriteLn(CallStack[I]);
      end;

    'set':
      begin
        { Format: set VarName = Value }
        if Length(Parts) < 4 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: set <variable> = <value>');
          Exit;
        end;

        if Parts[2] <> '=' then
        begin
          WriteLn(StdErr, '[ERROR] Usage: set <variable> = <value>');
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
          WriteLn(StdErr, '[ERROR] Usage: display <expression>');
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
          WriteLn(StdErr, '[ERROR] Usage: watch <variable>');
          Exit;
        end;
        FEngine.SetWatch(Parts[1], wtWrite);
      end;

    'rwatch', 'awatch':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: ', Cmd, ' <variable>');
          Exit;
        end;
        FEngine.SetWatch(Parts[1], wtReadWrite);
      end;

    'unwatch':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: unwatch <variable>');
          Exit;
        end;
        FEngine.RemoveWatch(Parts[1]);
      end;

    'catch':
      begin
        FEngine.CatchExceptions := True;
        WriteLn(StdErr, '[INFO] Break on exception enabled');
      end;

    'nocatch':
      begin
        FEngine.CatchExceptions := False;
        WriteLn(StdErr, '[INFO] Break on exception disabled');
      end;

    'verbose', 'v':
      begin
        if (Length(Parts) > 1) and
           ((LowerCase(Parts[1]) = 'off') or (LowerCase(Parts[1]) = 'false') or (Parts[1] = '0')) then
        begin
          gVerbose := False;
          WriteLn(StdErr, '[INFO] Verbose mode off');
        end
        else if (Length(Parts) > 1) and
                ((LowerCase(Parts[1]) = 'on') or (LowerCase(Parts[1]) = 'true') or (Parts[1] = '1')) then
        begin
          gVerbose := True;
          WriteLn(StdErr, '[INFO] Verbose mode on');
        end
        else
          WriteLn(StdErr, '[INFO] Verbose mode is ', BoolToStr(gVerbose, 'on', 'off'),
                  '. Use: verbose on|off');
      end;

    'list', 'l':
      begin
        CallStack := HandleListCommand(Parts);
        for I := 0 to High(CallStack) do
          WriteLn(CallStack[I]);
      end;

    'return':
      begin
        if Length(Parts) >= 2 then
        begin
          if TryStrToInt64(Parts[1], SliceLow) then
            FEngine.ForceReturn(SliceLow, True)
          else
            WriteLn(StdErr, '[ERROR] Invalid return value: ', Parts[1]);
        end
        else
          FEngine.ForceReturn(0, False);
      end;

    'source':
      begin
        if Length(Parts) < 2 then
        begin
          WriteLn(StdErr, '[ERROR] Usage: source <filename>');
          Exit;
        end;
        if not ExecuteScript(Parts[1]) then
          Result := False;
      end;

  else
    WriteLn(StdErr, '[ERROR] Unknown command: ', Cmd);
    WriteLn('Type "help" for available commands');
  end;
end;

procedure TCLIDebugger.Run(const BinaryPath: String; const Args: array of String;
  const ExCommands: array of String; const SourceFiles: array of String);
var
  CmdLine: String;
  I: Integer;
begin
  { Batch mode, or a --source script driving the session, is non-interactive:
    suppress banner and prompt so captured output is just command results. }
  FNonInteractive := FBatch or (Length(SourceFiles) > 0);

  if not (FQuiet or FNonInteractive) then
  begin
    WriteLn('PDR (Pascal Debug Reference) ', PDR_VERSION);
    WriteLn('Copyright (c) 2025-2026 Graeme Geldenhuys');
    WriteLn;
  end;

  // Store command-line arguments
  SetLength(FCommandLineArgs, Length(Args));
  if Length(Args) > 0 then
    Move(Args[0], FCommandLineArgs[0], Length(Args) * SizeOf(String));

  // Create platform-specific adapters
  FProcessController := TPlatformPtraceAdapter.Create;
  {$IFDEF UNIX}
  if c_isatty(0) = 0 then
    (FProcessController as TPlatformPtraceAdapter).RedirectChildIO := True;
  {$ENDIF}
  FDebugInfoReader := TOPDFReaderAdapter.Create;

  // Create architecture adapter with process controller
  {$IFDEF CPUX86_64}
  if gVerbose then
    WriteLn(StdErr, '[INFO] Detected architecture: x86_64');
  FArchAdapter := TArchX86_64Adapter.Create(FProcessController);
  {$ENDIF}
  {$IFDEF CPUI386}
  if gVerbose then
    WriteLn(StdErr, '[INFO] Detected architecture: i386');
  FArchAdapter := TArchX86Adapter.Create(FProcessController);
  {$ENDIF}
  {$IFDEF CPUAARCH64}
  if gVerbose then
    WriteLn(StdErr, '[INFO] Detected architecture: AArch64');
  FArchAdapter := TArchAArch64Adapter.Create(FProcessController);
  {$ENDIF}
  {$IFDEF CPUARM}
  if gVerbose then
    WriteLn(StdErr, '[INFO] Detected architecture: ARM');
  FArchAdapter := TArchARMAdapter.Create(FProcessController);
  {$ENDIF}

  // Create debugger engine
  FEngine := TDebuggerEngine.Create(FProcessController, FDebugInfoReader, FArchAdapter);

  // Load program
  if not FEngine.LoadProgram(BinaryPath) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to load program');
    Halt(1);
  end;

  // Set command-line arguments if provided at CLI
  if Length(FCommandLineArgs) > 0 then
  begin
    FEngine.SetCommandLineArgs(FCommandLineArgs);
    if not FQuiet then
      WriteLn(StdErr, '[INFO] Command-line arguments set: ', String.Join(' ', FCommandLineArgs));
  end;

  if not (FQuiet or FNonInteractive) then
    WriteLn;

  // Only auto-run if arguments were provided at CLI startup
  // Otherwise, let user set them via 'args' command before 'run'
  if Length(FCommandLineArgs) > 0 then
  begin
    if not FQuiet then
      WriteLn(StdErr, '[INFO] Starting program...');
    if not FEngine.Run then
    begin
      WriteLn(StdErr, '[ERROR] Failed to start program');
      Halt(1);
    end;
  end
  else
  begin
    if not FQuiet then
      WriteLn(StdErr, '[INFO] No arguments provided. Use "args" command to set them, then "run"');
  end;

  // Execute source files (--source)
  for I := 0 to High(SourceFiles) do
  begin
    if not ExecuteScript(SourceFiles[I]) then
    begin
      if FBatch then
        Exit;
    end;
  end;

  // Execute -ex commands
  for I := 0 to High(ExCommands) do
  begin
    if not FNonInteractive then
      WriteLn('(pdr) ', ExCommands[I]);
    if not ProcessCommand(ExCommands[I]) then
    begin
      if FBatch then
        Exit;
    end;
  end;

  // In batch mode, quit after executing commands
  if FBatch then
    Exit;

  if not (FQuiet or FNonInteractive) then
  begin
    WriteLn;
    WriteLn('Type "help" for available commands');
    WriteLn;
  end;

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
  I, BinaryArgIdx: Integer;
  Args: array of String;
  ExCommands: array of String;
  SourceFiles: array of String;
  Quiet, Batch: Boolean;
begin
  Quiet := False;
  Batch := False;

  { Parse options — consume flags until we hit the first non-flag argument (binary path) }
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '--help') or (ParamStr(I) = '-h') then
    begin
      I := ParamCount + 2;
      Break;
    end;

    if ParamStr(I) = '--help-commands' then
    begin
      PrintCommandHelp;
      Halt(0);
    end;

    if ParamStr(I) = '--version' then
    begin
      WriteLn('PDR (Pascal Debug Reference) ', PDR_VERSION);
      WriteLn('Built: ', PDR_BUILD_DATE);
      WriteLn('Copyright (c) 2025-2026 Graeme Geldenhuys');
      Halt(0);
    end;

    if (ParamStr(I) = '--verbose') or (ParamStr(I) = '-v') then
    begin
      gVerbose := True;
      Inc(I);
      Continue;
    end;

    if (ParamStr(I) = '--quiet') or (ParamStr(I) = '-q') then
    begin
      Quiet := True;
      Inc(I);
      Continue;
    end;

    if ParamStr(I) = '--batch' then
    begin
      Batch := True;
      Inc(I);
      Continue;
    end;

    if ParamStr(I) = '-ex' then
    begin
      if I + 1 <= ParamCount then
      begin
        SetLength(ExCommands, Length(ExCommands) + 1);
        ExCommands[High(ExCommands)] := ParamStr(I + 1);
        Inc(I, 2);
      end
      else
      begin
        WriteLn(StdErr, '[ERROR] -ex requires a command argument');
        Halt(1);
      end;
      Continue;
    end;

    if ParamStr(I) = '--source' then
    begin
      if I + 1 <= ParamCount then
      begin
        SetLength(SourceFiles, Length(SourceFiles) + 1);
        SourceFiles[High(SourceFiles)] := ParamStr(I + 1);
        Inc(I, 2);
      end
      else
      begin
        WriteLn(StdErr, '[ERROR] --source requires a filename argument');
        Halt(1);
      end;
      Continue;
    end;

    Break;
  end;

  { I now points at the binary path (or past ParamCount if no binary given) }
  if I > ParamCount then
  begin
    WriteLn('Usage: pdr [options] <binary> [<argument> ...]');
    WriteLn;
    WriteLn('Debug an Object Pascal program using OPDF debug information.');
    WriteLn;
    WriteLn('Options:');
    WriteLn('  --help, -h         - Show this help and exit');
    WriteLn('  --help-commands    - Show debugger REPL commands and exit');
    WriteLn('  --version          - Show version information and exit');
    WriteLn('  --verbose, -v      - Enable diagnostic output at startup');
    WriteLn('  --quiet, -q        - Suppress the startup banner');
    WriteLn('  --batch            - Execute -ex commands and quit');
    WriteLn('  -ex <command>      - Execute command (may be repeated)');
    WriteLn('  --source <file>    - Execute commands from file');
    WriteLn;
    WriteLn('Arguments:');
    WriteLn('  <binary>           - Path to the binary to debug');
    WriteLn('  <argument>         - Command-line arguments to pass to the program');
    WriteLn;
    WriteLn('Examples:');
    WriteLn('  pdr ./myprogram');
    WriteLn('  pdr --verbose ./myprogram');
    WriteLn('  pdr ./myprogram arg1 arg2 arg3');
    WriteLn('  pdr --batch -ex "break main.pas:10" -ex "run" -ex "print x" ./myprogram');
    WriteLn('  pdr --source debug_script.pdr ./myprogram');
    if I > ParamCount + 1 then
      Halt(0)
    else
      Halt(1);
  end;

  BinaryArgIdx := I;
  BinaryPath := ParamStr(BinaryArgIdx);

  if not FileExists(BinaryPath) then
  begin
    WriteLn(StdErr, '[ERROR] Binary file not found: ', BinaryPath);
    Halt(1);
  end;

  { Collect command-line arguments (all parameters after the binary path) }
  if ParamCount > BinaryArgIdx then
  begin
    SetLength(Args, ParamCount - BinaryArgIdx);
    for I := BinaryArgIdx + 1 to ParamCount do
      Args[I - BinaryArgIdx - 1] := ParamStr(I);
  end;

  CLI := TCLIDebugger.Create;
  try
    CLI.FQuiet := Quiet;
    CLI.FBatch := Batch;
    CLI.Run(BinaryPath, Args, ExCommands, SourceFiles);
  finally
    CLI.Free;
  end;
end.
