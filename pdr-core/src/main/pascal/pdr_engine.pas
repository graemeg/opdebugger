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
  Classes, SysUtils, Math, pdr_ports, pdr_typesys, pdr_expr, pdr_expr_eval,
  opdf_types, elf_reader;

type
  { Breakpoint condition type }
  TBreakpointConditionType = (bctNone, bctHitCount, bctExpression);

  { Breakpoint tracking record }
  TBreakpointEntry = record
    Handle: TBreakpointHandle;
    Address: QWord;
    Location: String;  // Original location string (for display)
    Active: Boolean;
    Enabled: Boolean;
    Temporary: Boolean;
    ConditionType: TBreakpointConditionType;
    HitCount: Integer;         // Target hit count (fire on Nth hit)
    CurrentHitCount: Integer;  // Running counter
    ConditionExpr: String;     // Expression for bctExpression conditions
    Commands: array of String; // Commands to execute when breakpoint fires
  end;

  { Watchpoint tracking record }
  TWatchpointEntry = record
    Slot: Integer;         // Hardware slot 0-3
    VarName: String;
    Address: QWord;
    Size: Cardinal;
    OldValue: String;      // Last known formatted value
    Active: Boolean;
  end;

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
    FBreakpoints: array of TBreakpointEntry;
    FNextHandle: TBreakpointHandle;
    FDisplayList: array of String;   // Expressions for auto-display
    FWatchpoints: array of TWatchpointEntry;
    FRaiseBreakpointAddr: QWord;     // Address of fpc_raiseexception (0 = not set)
    FCatchExceptions: Boolean;        // Break on raise (default: True)
    FLastException: TExceptionInfo;  // Cleared on each Run/Continue/Step; set in HandleExceptionBreakpoint
    FSourceCache: TStringList;       // File cache: Name=filepath, Objects[]=TStringList of lines
    FSelectedFrameIndex: Integer;
    FFrameRBPs: array of QWord;
    FFrameRIPs: array of QWord;
    FFrameCacheValid: Boolean;

    { Helper methods for breakpoint management }
    function ParseLocation(const Location: String; out Address: QWord): Boolean;
    function FindBreakpointByHandle(Handle: TBreakpointHandle): Integer;
    function FindBreakpointByAddress(Address: QWord): Integer;
    procedure HandleExceptionBreakpoint;
    function LoadSourceFile(const FileName: String): TStringList;
    procedure BuildFrameCache;
    procedure ResetSelectedFrame;
    procedure ApplyFrameOverrides;
    function EvaluateConditionExpr(const Expr: String): Boolean;
  public
    constructor Create(AProcessController: IProcessController;
                      ADebugInfoReader: IDebugInfoReader;
                      AArchAdapter: IArchAdapter);
    destructor Destroy; override;

    { ICommandHandler - Session management }
    function LoadProgram(const BinaryPath: String): Boolean;
    function SetCommandLineArgs(const Args: array of String): Boolean;
    function Attach(PID: Integer): Boolean;
    function Detach: Boolean;

    { ICommandHandler - Execution control }
    function Run: Boolean;
    function Continue: Boolean;
    function Step: Boolean;
    function StepLine: Boolean;
    function StepInto: Boolean;
    function StepOver: Boolean;
    function StepOut: Boolean;
    function Pause: Boolean;
    function ForceReturn(ReturnValue: Int64; HasValue: Boolean): Boolean;

    { ICommandHandler - Breakpoints }
    function SetBreakpoint(const Location: String): TBreakpointHandle;
    function RemoveBreakpoint(Handle: TBreakpointHandle): Boolean;

    { Conditional breakpoint support }
    function SetBreakpointCondition(Handle: TBreakpointHandle;
      CondType: TBreakpointConditionType; Count: Integer): Boolean;
    function SetBreakpointExprCondition(Handle: TBreakpointHandle;
      const Expr: String): Boolean;
    procedure SetBreakpointCommands(Handle: TBreakpointHandle;
      const Cmds: array of String);
    function GetHitBreakpointCommands: TStringArray;
    function EnableBreakpoint(Handle: TBreakpointHandle): Boolean;
    function DisableBreakpoint(Handle: TBreakpointHandle): Boolean;
    procedure SetTemporary(Handle: TBreakpointHandle);
    function GetBreakpointList: TStringArray;

    { Display list (auto-print on every stop) }
    function AddDisplay(const Expr: String): Boolean;
    procedure RemoveDisplay(const Expr: String);
    procedure ClearDisplay;
    function GetDisplayList: TStringArray;
    function EvaluateDisplayList: TVariableValueArray;

    { Hardware watchpoints }
    function SetWatch(const VarName: String; WatchType: TWatchpointType): Boolean;
    function RemoveWatch(const VarName: String): Boolean;
    function GetWatchpointList: TStringArray;

    { ICommandHandler - Inspection }
    function EvaluateExpression(const Expr: String): TVariableValue;
    function GetLocalVariables: TVariableValueArray;
    function GetLocalVariablesWithParents: TVariableValueArray;
    function GetGlobalVariables: TVariableValueArray;
    function GetInspectLines(const Expr: String): TStringArray;
    function EvaluateArraySlice(const VarName: String;
                                LowIndex, HighIndex: Int64): TVariableValueArray;
    function SetVariable(const VarName, Value: String): Boolean;
    function GetCallStack(Limit: Integer = 0): TStringArray;

    { Source listing }
    function GetSourceLines(const FileName: String; Line: Integer;
      Before: Integer = 5; After: Integer = 10): TStringArray;

    { Frame navigation }
    function SelectFrame(Index: Integer): Boolean;
    function FrameUp: Boolean;
    function FrameDown: Boolean;
    function GetSelectedFrameRIP: QWord;

    { ICommandHandler - State query }
    function GetState: TDebuggerState;

    { Properties }
    property State: TDebuggerState read FState;
    property SelectedFrameIndex: Integer read FSelectedFrameIndex;
    property BinaryPath: String read FBinaryPath;
    property AttachedPID: Integer read FAttachedPID;
    property CatchExceptions: Boolean read FCatchExceptions write FCatchExceptions;
    { Exception info from the last HandleExceptionBreakpoint call.
      IsValid=False if the last stop was not an exception. Cleared at Run/Continue/Step. }
    property LastException: TExceptionInfo read FLastException;
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
  FNextHandle := 1;  // Start handle numbering at 1
  SetLength(FBreakpoints, 0);
  FRaiseBreakpointAddr := 0;
  FCatchExceptions := True;
  FSourceCache := TStringList.Create;
  FSourceCache.OwnsObjects := True;
  FSourceCache.Sorted := True;
  FSourceCache.Duplicates := dupIgnore;
  FSelectedFrameIndex := 0;
  FFrameCacheValid := False;

  // Create type system and register evaluators
  FTypeSystem := TTypeSystem.Create(FProcessController, FDebugInfoReader);
  FTypeSystem.RegisterEvaluator(TPrimitiveEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TFloatEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TShortStringEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TAnsiStringEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TUnicodeStringEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TClassEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TStaticArrayEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TDynamicArrayEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TPointerEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TRecordEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TEnumEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TSetEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TInterfaceEvaluator.Create);
end;

destructor TDebuggerEngine.Destroy;
begin
  if FState <> dsIdle then
    Detach;

  FSourceCache.Free;
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

function TDebuggerEngine.SetCommandLineArgs(const Args: array of String): Boolean;
begin
  Result := FProcessController.SetCommandLineArgs(Args);
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

  if gVerbose then
    WriteLn('[INFO] Detaching from process ', FAttachedPID, '...');

  if not FProcessController.Detach then
  begin
    WriteLn('[ERROR] Failed to detach from process');
    Exit;
  end;

  FAttachedPID := -1;
  FState := dsIdle;

  if gVerbose then
    WriteLn('[INFO] Detached successfully');
  Result := True;
end;

{ Execution control }

function TDebuggerEngine.Run: Boolean;
var
  LoadBase: QWord;
  Slide: QWord;
begin
  Result := False;
  FLastException.IsValid := False;
  ResetSelectedFrame;
  Slide := 0;

  if FState <> dsIdle then
  begin
    WriteLn('[ERROR] Process already running or attached');
    Exit;
  end;

  if FBinaryPath = '' then
  begin
    WriteLn('[ERROR] No binary loaded. Use LoadProgram first');
    Exit;
  end;

  WriteLn('[INFO] Running program: ', FBinaryPath);

  // Launch the program under debugger control
  if not FProcessController.Launch(FBinaryPath) then
  begin
    WriteLn('[ERROR] Failed to launch program');
    Exit;
  end;

  FState := dsPaused;

  { Compute ASLR/PIE slide for position-independent executables.
    ET_DYN (type=3) indicates a PIE binary whose link-time addresses
    are relative; all OPDF addresses are adjusted by the runtime load base. }
  if TELFSectionReader.GetELFType(FBinaryPath) = 3 then
  begin
    LoadBase := FProcessController.GetLoadBase(FBinaryPath);
    if LoadBase <> 0 then
    begin
      Slide := LoadBase;
      FDebugInfoReader.SetSlide(Slide);
      if gVerbose then
        WriteLn('[DEBUG] PIE binary detected — slide set to $', HexStr(Slide, 16));
    end
    else
    begin
      if gVerbose then
        WriteLn('[DEBUG] PIE binary detected but could not determine load base');
    end;
  end
  else
  begin
    if gVerbose then
      WriteLn('[DEBUG] Non-PIE binary — no slide needed');
  end;

  { Set internal breakpoint on fpc_raiseexception for exception catching.
    The symbol address from the ELF symtab is a link-time address; for PIE
    binaries it needs the same ASLR slide applied. }
  FRaiseBreakpointAddr := TELFSectionReader.FindSymbolAddress(FBinaryPath, 'FPC_RAISEEXCEPTION');
  if FRaiseBreakpointAddr <> 0 then
  begin
    FRaiseBreakpointAddr := FRaiseBreakpointAddr + Slide;
  end;
  if FRaiseBreakpointAddr <> 0 then
  begin
    if FProcessController.SetBreakpoint(FRaiseBreakpointAddr) then
    begin
      if gVerbose then
        WriteLn('[DEBUG] Exception breakpoint set at $', HexStr(FRaiseBreakpointAddr, 16));
    end
    else
      FRaiseBreakpointAddr := 0;
  end
  else
  begin
    if gVerbose then
      WriteLn('[DEBUG] fpc_raiseexception not found in symbol table — exception catching disabled');
  end;

  WriteLn('[INFO] Program started and paused at entry point');
  WriteLn('[INFO] You can now set breakpoints and use "continue" to start execution');
  Result := True;
end;

function TDebuggerEngine.Continue: Boolean;
var
  BpAddr: QWord;
  Idx: Integer;
  ConditionMet: Boolean;
  WatchSlot: Integer;
  NewValue: TVariableValue;
begin
  Result := False;
  FLastException.IsValid := False;
  ResetSelectedFrame;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  if gVerbose then
    WriteLn('[INFO] Continuing process...');

  repeat
    if not FProcessController.Continue then
    begin
      WriteLn('[ERROR] Failed to continue process');
      Exit;
    end;

    { Check if process exited }
    if FProcessController.GetCurrentAddress = 0 then
    begin
      if gVerbose then
        WriteLn('[INFO] Process terminated');
      FState := dsTerminated;
      Result := True;
      Exit;
    end;

    { Check if a hardware watchpoint fired }
    WatchSlot := FProcessController.GetFiredWatchpoint;
    if WatchSlot >= 0 then
    begin
      { Find matching watchpoint entry }
      for Idx := 0 to High(FWatchpoints) do
        if FWatchpoints[Idx].Active and (FWatchpoints[Idx].Slot = WatchSlot) then
        begin
          NewValue := EvaluateExpression(FWatchpoints[Idx].VarName);
          WriteLn('[INFO] Watchpoint hit: ', FWatchpoints[Idx].VarName);
          WriteLn('  Old value: ', FWatchpoints[Idx].VarName, ' = ', FWatchpoints[Idx].OldValue);
          if NewValue.IsValid then
          begin
            WriteLn('  New value: ', FWatchpoints[Idx].VarName, ' = ', NewValue.Value);
            FWatchpoints[Idx].OldValue := NewValue.Value;
          end
          else
            WriteLn('  New value: ', FWatchpoints[Idx].VarName, ' = <error>');
          Break;
        end;

      if gVerbose then
        WriteLn('[INFO] Process stopped and ready for commands');
      Result := True;
      Exit;
    end;

    { Check if we hit the internal exception breakpoint }
    ConditionMet := True;
    BpAddr := FProcessController.GetLastBreakpointAddress;
    if (FRaiseBreakpointAddr <> 0) and (BpAddr = FRaiseBreakpointAddr) then
    begin
      if FCatchExceptions then
      begin
        HandleExceptionBreakpoint;
        Result := True;
        Exit;
      end
      else
      begin
        { Exception catching disabled — silently resume }
        if gVerbose then
          WriteLn('[DEBUG] Exception raised but catching disabled — continuing');
        ConditionMet := False;
      end;
    end;

    { Check if we hit a conditional breakpoint }
    if ConditionMet and (BpAddr <> 0) then
    begin
      Idx := FindBreakpointByAddress(BpAddr);
      if Idx >= 0 then
      begin
        case FBreakpoints[Idx].ConditionType of
          bctHitCount:
          begin
            Inc(FBreakpoints[Idx].CurrentHitCount);
            if FBreakpoints[Idx].CurrentHitCount <> FBreakpoints[Idx].HitCount then
            begin
              ConditionMet := False;
              if gVerbose then
                WriteLn('[DEBUG] Breakpoint #', FBreakpoints[Idx].Handle,
                        ' hit count: ', FBreakpoints[Idx].CurrentHitCount,
                        '/', FBreakpoints[Idx].HitCount, ' - continuing');
            end
            else
            begin
              if gVerbose then
                WriteLn('[DEBUG] Breakpoint #', FBreakpoints[Idx].Handle,
                        ' hit count reached: ', FBreakpoints[Idx].CurrentHitCount);
            end;
          end;
          bctExpression:
          begin
            Inc(FBreakpoints[Idx].CurrentHitCount);
            ConditionMet := EvaluateConditionExpr(FBreakpoints[Idx].ConditionExpr);
            if not ConditionMet then
            begin
              if gVerbose then
                WriteLn('[DEBUG] Breakpoint #', FBreakpoints[Idx].Handle,
                        ' condition false (hits: ', FBreakpoints[Idx].CurrentHitCount,
                        ') - continuing');
            end
            else
            begin
              if gVerbose then
                WriteLn('[DEBUG] Breakpoint #', FBreakpoints[Idx].Handle,
                        ' condition true (hits: ', FBreakpoints[Idx].CurrentHitCount, ')');
            end;
          end;
        end;
      end;
    end;
  until ConditionMet;

  { Auto-remove temporary breakpoints after they fire }
  if BpAddr <> 0 then
  begin
    Idx := FindBreakpointByAddress(BpAddr);
    if (Idx >= 0) and FBreakpoints[Idx].Temporary then
      RemoveBreakpoint(FBreakpoints[Idx].Handle);
  end;

  if gVerbose then
    WriteLn('[INFO] Process stopped and ready for commands');
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

  if gVerbose then WriteLn('[INFO] Stepping...');

  if not FProcessController.Step then
  begin
    WriteLn('[ERROR] Failed to step');
    Exit;
  end;

  if gVerbose then WriteLn('[INFO] Step complete');
  Result := True;
end;

function TDebuggerEngine.StepLine: Boolean;
var
  CurrentAddr: QWord;
  CurrentLine: TLineInfo;
  NextLineNum: Cardinal;
  LineEntries: TLineInfoArray;
  I: Integer;
  TempBreakpoints: array of TBreakpointHandle;
  BreakpointHit: Boolean;
  CurrentScope: TFunctionInfo;
  HasScope: Boolean;
  InScope: Boolean;
begin
  Result := False;
  FLastException.IsValid := False;
  ResetSelectedFrame;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  // Get current address
  // Use last breakpoint address if available (we just handled a breakpoint and RIP moved)
  // Otherwise use current RIP
  CurrentAddr := FProcessController.GetLastBreakpointAddress;
  if CurrentAddr = 0 then
    CurrentAddr := FProcessController.GetCurrentAddress;

  if CurrentAddr = 0 then
  begin
    WriteLn('[ERROR] Failed to get current address');
    Exit;
  end;

  if gVerbose then WriteLn('[DEBUG] Current address: 0x', IntToHex(CurrentAddr, 16));

  // Find current source line
  if not FDebugInfoReader.FindLineByAddress(CurrentAddr, CurrentLine) then
  begin
    WriteLn('[ERROR] No source line found for current address 0x', IntToHex(CurrentAddr, 16));
    if gVerbose then WriteLn('[INFO] Use "step" for instruction-level stepping');
    Exit;
  end;

  if gVerbose then
    WriteLn('[INFO] Current line: ', CurrentLine.FileName, ':', CurrentLine.LineNumber,
            ' (address: 0x', IntToHex(CurrentLine.Address, 16), ')');

  // Get all line entries for this file
  LineEntries := FDebugInfoReader.GetFileLineEntries(CurrentLine.FileName);
  if Length(LineEntries) = 0 then
  begin
    WriteLn('[ERROR] No line information available for ', CurrentLine.FileName);
    Exit;
  end;

  // Determine the current function scope to restrict step-over to the current function.
  // This ensures that lines inside called functions are not mistakenly used as step targets.
  HasScope := FDebugInfoReader.FindFunctionByAddress(CurrentAddr, CurrentScope);
  if gVerbose then
  begin
    if HasScope then
      WriteLn('[INFO] Step-over scope: ', CurrentScope.Name,
              ' [0x', IntToHex(CurrentScope.LowPC, 1), '..0x', IntToHex(CurrentScope.HighPC, 1), ')')
    else
      WriteLn('[INFO] Step-over scope: unknown, falling back to line-range limit');
  end;

  // Find all addresses for lines AFTER the current line and within the current function scope.
  // NOTE: We must NOT use bare 'Continue;' in this loop because FPC resolves it
  // to TDebuggerEngine.Continue (the method) rather than the loop-control keyword.
  if gVerbose then
    WriteLn('[DEBUG] StepLine: scanning ', Length(LineEntries), ' entries, currentLine=', CurrentLine.LineNumber);
  SetLength(TempBreakpoints, 0);
  for I := 0 to High(LineEntries) do
  begin
    if gVerbose then
      WriteLn('[DEBUG] entry[', I, ']: line=', LineEntries[I].LineNumber, ' addr=0x', IntToHex(LineEntries[I].Address, 1));

    // Only consider lines AFTER the current line
    if LineEntries[I].LineNumber > CurrentLine.LineNumber then
    begin
      // Determine if this entry is within scope
      InScope := True;
      if HasScope then
      begin
        if (LineEntries[I].Address < CurrentScope.LowPC) or
           (LineEntries[I].Address >= CurrentScope.HighPC) then
          InScope := False;
      end
      else
      begin
        // Fallback: limit to 100 source lines when no scope info is available
        if LineEntries[I].LineNumber > CurrentLine.LineNumber + 100 then
          InScope := False;
      end;

      if InScope then
      begin
        // Set temporary breakpoint at this address
        SetLength(TempBreakpoints, Length(TempBreakpoints) + 1);
        TempBreakpoints[High(TempBreakpoints)] := SetBreakpoint('0x' + IntToHex(LineEntries[I].Address, 1));
        if TempBreakpoints[High(TempBreakpoints)] = -1 then
        begin
          WriteLn('[WARN] Failed to set temporary breakpoint at 0x', IntToHex(LineEntries[I].Address, 16));
        end
        else
        begin
          if gVerbose then
            WriteLn('[DEBUG] Set temp breakpoint at line ', LineEntries[I].LineNumber,
                    ' (0x', IntToHex(LineEntries[I].Address, 16), ')');
        end;
      end;
    end;
  end;

  if Length(TempBreakpoints) = 0 then
  begin
    WriteLn('[ERROR] No subsequent lines found (might be at end of program)');
    WriteLn('[INFO] Current line ', CurrentLine.LineNumber, ' appears to be the last line with debug info');
    Exit;
  end;

  if gVerbose then WriteLn('[INFO] Stepping to next line...');

  // Continue until we hit one of the temporary breakpoints
  if not FProcessController.Continue then
  begin
    WriteLn('[ERROR] Failed to continue');
    // Clean up temporary breakpoints only if still attached
    if FState = dsPaused then
    begin
      for I := 0 to High(TempBreakpoints) do
        if TempBreakpoints[I] <> -1 then
          RemoveBreakpoint(TempBreakpoints[I]);
    end;
    Exit;
  end;

  // Check if process exited during continue
  if FProcessController.GetCurrentAddress = 0 then
  begin
    WriteLn('[INFO] Process terminated during step');
    FState := dsTerminated;
    // Don't try to clean up breakpoints - process is dead
    Exit(True);
  end;

  // Get new address to see which line we're on
  // Use last breakpoint address (temp breakpoint we just hit) instead of current RIP
  CurrentAddr := FProcessController.GetLastBreakpointAddress;
  if CurrentAddr = 0 then
    CurrentAddr := FProcessController.GetCurrentAddress;

  if FDebugInfoReader.FindLineByAddress(CurrentAddr, CurrentLine) then
  begin
    WriteLn('[INFO] Stepped to line: ', CurrentLine.FileName, ':', CurrentLine.LineNumber);
  end;

  // Remove all temporary breakpoints
  for I := 0 to High(TempBreakpoints) do
    if TempBreakpoints[I] <> -1 then
      RemoveBreakpoint(TempBreakpoints[I]);

  Result := True;
end;

function TDebuggerEngine.StepInto: Boolean;
var
  StartAddr: QWord;
  StartLine: TLineInfo;
  CurrentAddr: QWord;
  CurrentLine: TLineInfo;
  MaxSteps: Integer;
begin
  Result := False;
  FLastException.IsValid := False;
  ResetSelectedFrame;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  // Use last breakpoint address as the source anchor — RIP may have advanced
  // during breakpoint handling (single-step to re-execute original instruction).
  StartAddr := FProcessController.GetLastBreakpointAddress;
  if StartAddr = 0 then
    StartAddr := FProcessController.GetCurrentAddress;

  if StartAddr = 0 then
  begin
    WriteLn('[ERROR] Failed to get current address');
    Exit;
  end;

  // Resolve the starting source line
  if not FDebugInfoReader.FindLineByAddress(StartAddr, StartLine) then
  begin
    // No line info at this address — fall back to a raw instruction step
    if gVerbose then
      WriteLn('[INFO] StepInto: no source line, falling back to instruction step');
    Result := FProcessController.Step;
    Exit;
  end;

  if gVerbose then
    WriteLn('[INFO] StepInto from: ', StartLine.FileName, ':', StartLine.LineNumber);

  // Single-step instructions until the source line changes.
  // A change means we either entered a called function or advanced to the next line.
  MaxSteps := 10000;
  repeat
    if not FProcessController.Step then
    begin
      WriteLn('[ERROR] Failed to single-step');
      Exit;
    end;

    // Detect process exit during stepping
    CurrentAddr := FProcessController.GetCurrentAddress;
    if CurrentAddr = 0 then
    begin
      WriteLn('[INFO] Process terminated during step');
      FState := dsTerminated;
      Exit(True);
    end;

    // Check whether the source line has changed
    if FDebugInfoReader.FindLineByAddress(CurrentAddr, CurrentLine) then
    begin
      if (CurrentLine.LineNumber <> StartLine.LineNumber) or
         (CurrentLine.FileName <> StartLine.FileName) then
      begin
        WriteLn('[INFO] Stepped to line: ', CurrentLine.FileName, ':', CurrentLine.LineNumber);
        Result := True;
        Exit;
      end;
    end;

    Dec(MaxSteps);
  until MaxSteps <= 0;

  WriteLn('[WARN] StepInto: reached instruction limit without a source-line change');
  Result := True;
end;

function TDebuggerEngine.StepOver: Boolean;
begin
  { StepOver is an alias for StepLine (step to next source line, skipping over calls) }
  Result := StepLine;
end;

function TDebuggerEngine.StepOut: Boolean;
var
  Regs: TRegisters;
  ReturnAddr: QWord;
  TempBp: TBreakpointHandle;
  CurrentAddr: QWord;
  CurrentLine: TLineInfo;
  FuncInfo: TFunctionInfo;
  AtEntry: Boolean;
begin
  Result := False;
  FLastException.IsValid := False;
  ResetSelectedFrame;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  if not FProcessController.GetRegisters(Regs) then
  begin
    WriteLn('[ERROR] Failed to read registers');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  AtEntry := False;
  if FDebugInfoReader.FindFunctionByAddress(Regs.RIP, FuncInfo) then
    AtEntry := (Regs.RIP = FuncInfo.LowPC);

  if AtEntry then
  begin
    if not FProcessController.ReadMemory(Regs.RSP, 8, ReturnAddr) then
    begin
      WriteLn('[ERROR] Failed to read return address from stack');
      Exit;
    end;
  end
  else
  begin
    if not FProcessController.ReadMemory(Regs.RBP + 8, 8, ReturnAddr) then
    begin
      WriteLn('[ERROR] Failed to read return address from stack');
      Exit;
    end;
  end;
  {$ENDIF}
  {$IFDEF CPUI386}
  AtEntry := False;
  if FDebugInfoReader.FindFunctionByAddress(Regs.EIP, FuncInfo) then
    AtEntry := (Regs.EIP = FuncInfo.LowPC);

  if AtEntry then
  begin
    if not FProcessController.ReadMemory(Regs.ESP, 4, ReturnAddr) then
    begin
      WriteLn('[ERROR] Failed to read return address from stack');
      Exit;
    end;
  end
  else
  begin
    if not FProcessController.ReadMemory(Regs.EBP + 4, 4, ReturnAddr) then
    begin
      WriteLn('[ERROR] Failed to read return address from stack');
      Exit;
    end;
  end;
  {$ENDIF}

  if gVerbose then
    WriteLn('[DEBUG] StepOut: return address = 0x', IntToHex(ReturnAddr, 1));

  TempBp := SetBreakpoint('0x' + IntToHex(ReturnAddr, 1));
  if TempBp = -1 then
  begin
    WriteLn('[ERROR] Failed to set breakpoint at return address');
    Exit;
  end;

  if not FProcessController.Continue then
  begin
    WriteLn('[ERROR] Failed to continue');
    if FState = dsPaused then
      RemoveBreakpoint(TempBp);
    Exit;
  end;

  if FProcessController.GetCurrentAddress = 0 then
  begin
    WriteLn('[INFO] Process terminated during step-out');
    FState := dsTerminated;
    Result := True;
    Exit;
  end;

  CurrentAddr := FProcessController.GetLastBreakpointAddress;
  if CurrentAddr = 0 then
    CurrentAddr := FProcessController.GetCurrentAddress;

  if FDebugInfoReader.FindLineByAddress(CurrentAddr, CurrentLine) then
    WriteLn('[INFO] Stepped to line: ', CurrentLine.FileName, ':', CurrentLine.LineNumber)
  else
    WriteLn('[INFO] Stepped out to: 0x', IntToHex(CurrentAddr, 1));

  RemoveBreakpoint(TempBp);
  Result := True;
end;

function TDebuggerEngine.Pause: Boolean;
begin
  Result := False;
  if FState <> dsRunning then
  begin
    WriteLn('[ERROR] Process is not running');
    Exit;
  end;
  Result := FProcessController.SendInterrupt;
end;

function TDebuggerEngine.ForceReturn(ReturnValue: Int64; HasValue: Boolean): Boolean;
var
  Regs: TRegisters;
  SavedRBP, ReturnAddr: QWord;
  CurrentLine: TLineInfo;
begin
  Result := False;
  FLastException.IsValid := False;
  ResetSelectedFrame;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  if not FProcessController.GetRegisters(Regs) then
  begin
    WriteLn('[ERROR] Failed to read registers');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  if not FProcessController.ReadMemory(Regs.RBP, 8, SavedRBP) then
  begin
    WriteLn('[ERROR] Failed to read saved RBP from stack');
    Exit;
  end;

  if not FProcessController.ReadMemory(Regs.RBP + 8, 8, ReturnAddr) then
  begin
    WriteLn('[ERROR] Failed to read return address from stack');
    Exit;
  end;

  Regs.RSP := Regs.RBP + 16;
  Regs.RBP := SavedRBP;
  Regs.RIP := ReturnAddr;

  if HasValue then
    Regs.RAX := QWord(ReturnValue);
  {$ENDIF}
  {$IFDEF CPUI386}
  if not FProcessController.ReadMemory(Regs.EBP, 4, SavedRBP) then
  begin
    WriteLn('[ERROR] Failed to read saved EBP from stack');
    Exit;
  end;

  if not FProcessController.ReadMemory(Regs.EBP + 4, 4, ReturnAddr) then
  begin
    WriteLn('[ERROR] Failed to read return address from stack');
    Exit;
  end;

  Regs.ESP := Regs.EBP + 8;
  Regs.EBP := Cardinal(SavedRBP);
  Regs.EIP := Cardinal(ReturnAddr);

  if HasValue then
    Regs.EAX := Cardinal(ReturnValue);
  {$ENDIF}

  if not FProcessController.SetRegisters(Regs) then
  begin
    WriteLn('[ERROR] Failed to set registers');
    Exit;
  end;

  if gVerbose then
    WriteLn('[DEBUG] ForceReturn: RIP=0x', IntToHex(ReturnAddr, 1),
            ' RBP=0x', IntToHex(SavedRBP, 1));

  if FDebugInfoReader.FindLineByAddress(ReturnAddr, CurrentLine) then
    WriteLn('[INFO] Returned to: ', CurrentLine.FileName, ':', CurrentLine.LineNumber)
  else
    WriteLn('[INFO] Returned to: 0x', IntToHex(ReturnAddr, 1));

  Result := True;
end;

{ Breakpoint helper methods }

function TDebuggerEngine.ParseLocation(const Location: String; out Address: QWord): Boolean;
var
  VarInfo: TVariableInfo;
  ErrorCode: Integer;
  ColonPos: Integer;
  FileName: String;
  LineNum: Cardinal;
  TempLineNum: LongInt;
begin
  Result := False;

  // Try parsing as file:line (e.g., "test.pas:22")
  // Check if there's a colon and it's not at position 2 (which would be a drive letter on Windows)
  ColonPos := Pos(':', Location);
  if (ColonPos > 0) and (ColonPos <> 2) then
  begin
    FileName := Copy(Location, 1, ColonPos - 1);
    if TryStrToInt(Copy(Location, ColonPos + 1, Length(Location)), TempLineNum) then
    begin
      LineNum := TempLineNum;
      if FDebugInfoReader.FindAddressByLine(FileName, LineNum, Address) then
      begin
        Result := True;
        if gVerbose then WriteLn('[INFO] Resolved ', FileName, ':', LineNum, ' to address 0x', IntToHex(Address, 8));
        Exit;
      end
      else
      begin
        WriteLn('[ERROR] No code found at ', FileName, ':', LineNum);
        WriteLn('[INFO] Make sure the binary was compiled with -g and OPDF file has line information');
        Exit;
      end;
    end;
  end;

  // Try parsing as hexadecimal address (e.g., "0x401000" or "$401000")
  if (Pos('0x', LowerCase(Location)) = 1) or (Pos('$', Location) = 1) then
  begin
    Val(Location, Address, ErrorCode);
    if ErrorCode = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;

  // Try parsing as decimal address
  Val(Location, Address, ErrorCode);
  if ErrorCode = 0 then
  begin
    Result := True;
    Exit;
  end;

  // Try finding as variable name (breakpoint on variable address)
  // This allows setting breakpoints on global variables
  if FDebugInfoReader.FindVariable(Location, VarInfo) then
  begin
    Address := VarInfo.Address;
    Result := True;
    Exit;
  end;

  // Could not parse location
  WriteLn('[ERROR] Could not resolve location: ', Location);
  WriteLn('[INFO] Location can be: file:line, hex address (0xNNNN), decimal address, or variable name');
end;

function TDebuggerEngine.FindBreakpointByHandle(Handle: TBreakpointHandle): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FBreakpoints) do
  begin
    if FBreakpoints[I].Handle = Handle then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

function TDebuggerEngine.FindBreakpointByAddress(Address: QWord): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FBreakpoints) do
  begin
    if FBreakpoints[I].Address = Address then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

{ Exception handling }

procedure TDebuggerEngine.HandleExceptionBreakpoint;
const
  VMT_CLASSNAME_OFFSET = 24;  // vmtClassName on x86_64
  FMESSAGE_OFFSET_MONITOR = 16;  // FMessage offset with _MonitorData
  FMESSAGE_OFFSET_NO_MONITOR = 8;  // FMessage offset without _MonitorData
var
  Regs: TRegisters;
  ObjPtr, RaiseAddr: QWord;
  VMTPtr, ClassNamePtr, FMsgPtr: QWord;
  Buf: array[0..7] of Byte;
  NameLen: Byte;
  NameBuf: array[0..255] of Byte;
  ExcClassName, ExcMessage: String;
  FMsgOffset: Integer;
  HeaderBuf: array[0..7] of Byte;
  MsgLen: LongInt;
  MsgBuf: array of Byte;
  I: Integer;
  LineInfo: TLineInfo;
  InstSize: QWord;
begin
  { Read registers to get exception object (RDI) and raise address (RSI) }
  if not FProcessController.GetRegisters(Regs) then
  begin
    WriteLn('[INFO] Exception raised (could not read registers)');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  ObjPtr := Regs.RDI;
  RaiseAddr := Regs.RSI;
  {$ELSE}
  { On i386, parameters are on the stack — not implemented yet }
  WriteLn('[INFO] Exception raised (i386 parameter reading not implemented)');
  Exit;
  {$ENDIF}

  if ObjPtr = 0 then
  begin
    WriteLn('[INFO] Exception raised (nil object)');
    Exit;
  end;

  { Read VMT pointer from object }
  ExcClassName := '<unknown>';
  FillChar(Buf, SizeOf(Buf), 0);
  if FProcessController.ReadMemory(ObjPtr, 8, Buf) then
  begin
    VMTPtr := PQWord(@Buf)^;
    if VMTPtr <> 0 then
    begin
      { Read class name pointer from VMT + 24 }
      FillChar(Buf, SizeOf(Buf), 0);
      if FProcessController.ReadMemory(VMTPtr + VMT_CLASSNAME_OFFSET, 8, Buf) then
      begin
        ClassNamePtr := PQWord(@Buf)^;
        if ClassNamePtr <> 0 then
        begin
          { Read ShortString: length byte + characters }
          NameLen := 0;
          if FProcessController.ReadMemory(ClassNamePtr, 1, NameLen) and (NameLen > 0) then
          begin
            FillChar(NameBuf, SizeOf(NameBuf), 0);
            if FProcessController.ReadMemory(ClassNamePtr + 1, NameLen, NameBuf) then
            begin
              SetLength(ExcClassName, NameLen);
              for I := 0 to NameLen - 1 do
                ExcClassName[I + 1] := Chr(NameBuf[I]);
            end;
          end;
        end;
      end;

      { Determine FMessage offset by checking instance size }
      FMsgOffset := FMESSAGE_OFFSET_MONITOR;  // Default: with _MonitorData
      FillChar(Buf, SizeOf(Buf), 0);
      if FProcessController.ReadMemory(VMTPtr, 8, Buf) then
      begin
        InstSize := PQWord(@Buf)^;
        { If this class's instance size < 32, assume no monitor data }
        if InstSize < 32 then
          FMsgOffset := FMESSAGE_OFFSET_NO_MONITOR;
      end;
    end;
  end;

  { Read FMessage (AnsiString) }
  ExcMessage := '';
  FillChar(Buf, SizeOf(Buf), 0);
  if FProcessController.ReadMemory(ObjPtr + QWord(FMsgOffset), 8, Buf) then
  begin
    FMsgPtr := PQWord(@Buf)^;
    if FMsgPtr <> 0 then
    begin
      { Read AnsiString length at Ptr - 8 }
      FillChar(HeaderBuf, SizeOf(HeaderBuf), 0);
      if FProcessController.ReadMemory(FMsgPtr - 8, 8, HeaderBuf) then
      begin
        MsgLen := PLongInt(@HeaderBuf)^;
        if (MsgLen > 0) and (MsgLen <= 65536) then
        begin
          SetLength(MsgBuf, MsgLen);
          if FProcessController.ReadMemory(FMsgPtr, MsgLen, MsgBuf[0]) then
          begin
            SetLength(ExcMessage, MsgLen);
            for I := 0 to MsgLen - 1 do
              ExcMessage[I + 1] := Chr(MsgBuf[I]);
          end;
        end
        else if (MsgLen < 0) or (MsgLen > 65536) then
        begin
          { Sanity check failed — try alternate offset }
          if FMsgOffset = FMESSAGE_OFFSET_MONITOR then
            FMsgOffset := FMESSAGE_OFFSET_NO_MONITOR
          else
            FMsgOffset := FMESSAGE_OFFSET_MONITOR;
          FillChar(Buf, SizeOf(Buf), 0);
          if FProcessController.ReadMemory(ObjPtr + QWord(FMsgOffset), 8, Buf) then
          begin
            FMsgPtr := PQWord(@Buf)^;
            if FMsgPtr <> 0 then
            begin
              FillChar(HeaderBuf, SizeOf(HeaderBuf), 0);
              if FProcessController.ReadMemory(FMsgPtr - 8, 8, HeaderBuf) then
              begin
                MsgLen := PLongInt(@HeaderBuf)^;
                if (MsgLen > 0) and (MsgLen <= 65536) then
                begin
                  SetLength(MsgBuf, MsgLen);
                  if FProcessController.ReadMemory(FMsgPtr, MsgLen, MsgBuf[0]) then
                  begin
                    SetLength(ExcMessage, MsgLen);
                    for I := 0 to MsgLen - 1 do
                      ExcMessage[I + 1] := Chr(MsgBuf[I]);
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;
  end;

  { Store exception info for IDE / caller to retrieve via LastException }
  FLastException.IsValid   := True;
  FLastException.ClassName := ExcClassName;
  FLastException.Message   := ExcMessage;
  FLastException.RaiseAddr := RaiseAddr;
  if (RaiseAddr <> 0) and FDebugInfoReader.FindLineByAddress(RaiseAddr, LineInfo) then
  begin
    FLastException.SourceFile := LineInfo.FileName;
    FLastException.SourceLine := Integer(LineInfo.LineNumber);
  end
  else
  begin
    FLastException.SourceFile := '';
    FLastException.SourceLine := 0;
  end;

end;

{ Breakpoints }

function TDebuggerEngine.SetBreakpoint(const Location: String): TBreakpointHandle;
var
  Address: QWord;
  Idx: Integer;
  Entry: TBreakpointEntry;
begin
  Result := -1;

  if FState = dsIdle then
  begin
    WriteLn('[ERROR] Not attached to a process');
    Exit;
  end;

  // Parse location to get address
  if not ParseLocation(Location, Address) then
    Exit;

  // Check if breakpoint already exists at this address
  Idx := FindBreakpointByAddress(Address);
  if Idx >= 0 then
  begin
    if FBreakpoints[Idx].Active then
    begin
      if gVerbose then WriteLn('[INFO] Breakpoint already set at ', Location);
      Result := FBreakpoints[Idx].Handle;
      Exit;
    end
    else
    begin
      // Reactivate existing breakpoint
      if FProcessController.SetBreakpoint(Address) then
      begin
        FBreakpoints[Idx].Active := True;
        FBreakpoints[Idx].Enabled := True;
        Result := FBreakpoints[Idx].Handle;
        if gVerbose then WriteLn('[INFO] Breakpoint #', Result, ' reactivated at 0x', IntToHex(Address, 16));
      end;
      Exit;
    end;
  end;

  // Set new breakpoint
  if not FProcessController.SetBreakpoint(Address) then
  begin
    WriteLn('[ERROR] Failed to set breakpoint at 0x', IntToHex(Address, 16));
    Exit;
  end;

  // Create breakpoint entry
  Entry.Handle := FNextHandle;
  Entry.Address := Address;
  Entry.Location := Location;
  Entry.Active := True;
  Entry.Enabled := True;
  Entry.Temporary := False;
  Entry.ConditionType := bctNone;
  Entry.HitCount := 0;
  Entry.CurrentHitCount := 0;

  // Add to tracking array
  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := Entry;

  Result := FNextHandle;
  Inc(FNextHandle);

  if gVerbose then WriteLn('[INFO] Breakpoint #', Result, ' set at 0x', IntToHex(Address, 16), ' (', Location, ')');
end;

function TDebuggerEngine.RemoveBreakpoint(Handle: TBreakpointHandle): Boolean;
var
  Idx: Integer;
begin
  Result := False;

  if FState = dsIdle then
  begin
    WriteLn('[ERROR] Not attached to a process');
    Exit;
  end;

  // Find breakpoint by handle
  Idx := FindBreakpointByHandle(Handle);
  if Idx < 0 then
  begin
    WriteLn('[ERROR] Breakpoint #', Handle, ' not found');
    Exit;
  end;

  // Check if already inactive
  if not FBreakpoints[Idx].Active then
  begin
    if gVerbose then WriteLn('[INFO] Breakpoint #', Handle, ' already removed');
    Result := True;
    Exit;
  end;

  // Remove breakpoint from process
  if not FProcessController.RemoveBreakpoint(FBreakpoints[Idx].Address) then
  begin
    WriteLn('[ERROR] Failed to remove breakpoint #', Handle);
    Exit;
  end;

  // Mark as inactive (keep for potential reactivation)
  FBreakpoints[Idx].Active := False;
  Result := True;

  if gVerbose then
    WriteLn('[INFO] Breakpoint #', Handle, ' removed from 0x',
            IntToHex(FBreakpoints[Idx].Address, 16));
end;

{ Conditional breakpoint support }

function TDebuggerEngine.SetBreakpointCondition(Handle: TBreakpointHandle;
  CondType: TBreakpointConditionType; Count: Integer): Boolean;
var
  Idx: Integer;
begin
  Result := False;

  Idx := FindBreakpointByHandle(Handle);
  if Idx < 0 then
  begin
    WriteLn('[ERROR] Breakpoint #', Handle, ' not found');
    Exit;
  end;

  FBreakpoints[Idx].ConditionType := CondType;
  FBreakpoints[Idx].HitCount := Count;
  FBreakpoints[Idx].CurrentHitCount := 0;

  if CondType = bctHitCount then
    WriteLn('[INFO] Breakpoint #', Handle, ' condition set: count=', Count)
  else
    WriteLn('[INFO] Breakpoint #', Handle, ' condition removed');

  Result := True;
end;

function TDebuggerEngine.SetBreakpointExprCondition(Handle: TBreakpointHandle;
  const Expr: String): Boolean;
var
  Idx: Integer;
  Parser: TExprParser;
  AST: TExprNode;
begin
  Result := False;

  Idx := FindBreakpointByHandle(Handle);
  if Idx < 0 then
  begin
    WriteLn('[ERROR] Breakpoint #', Handle, ' not found');
    Exit;
  end;

  Parser := TExprParser.Create(Expr);
  try
    try
      AST := Parser.Parse;
      AST.Free;
    except
      on E: EExprParseError do
      begin
        WriteLn('[ERROR] Invalid condition expression: ', E.Message);
        Exit;
      end;
    end;
  finally
    Parser.Free;
  end;

  FBreakpoints[Idx].ConditionType := bctExpression;
  FBreakpoints[Idx].ConditionExpr := Expr;
  FBreakpoints[Idx].CurrentHitCount := 0;
  WriteLn('[INFO] Breakpoint #', Handle, ' condition set: if ', Expr);
  Result := True;
end;

procedure TDebuggerEngine.SetBreakpointCommands(Handle: TBreakpointHandle;
  const Cmds: array of String);
var
  Idx, I: Integer;
begin
  Idx := FindBreakpointByHandle(Handle);
  if Idx < 0 then
  begin
    WriteLn('[ERROR] Breakpoint #', Handle, ' not found');
    Exit;
  end;

  SetLength(FBreakpoints[Idx].Commands, Length(Cmds));
  for I := 0 to High(Cmds) do
    FBreakpoints[Idx].Commands[I] := Cmds[I];

  if Length(Cmds) = 0 then
    WriteLn('[INFO] Breakpoint #', Handle, ' commands cleared')
  else
    WriteLn('[INFO] Breakpoint #', Handle, ': ', Length(Cmds), ' command(s) attached');
end;

function TDebuggerEngine.GetHitBreakpointCommands: TStringArray;
var
  BpAddr: QWord;
  Idx: Integer;
begin
  SetLength(Result, 0);
  BpAddr := FProcessController.GetLastBreakpointAddress;
  if BpAddr = 0 then
    Exit;
  Idx := FindBreakpointByAddress(BpAddr);
  if (Idx >= 0) and (Length(FBreakpoints[Idx].Commands) > 0) then
    Result := Copy(FBreakpoints[Idx].Commands);
end;

function TDebuggerEngine.EnableBreakpoint(Handle: TBreakpointHandle): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  Idx := FindBreakpointByHandle(Handle);
  if Idx < 0 then
  begin
    WriteLn('[ERROR] Breakpoint #', Handle, ' not found');
    Exit;
  end;

  if FBreakpoints[Idx].Enabled then
  begin
    WriteLn('[INFO] Breakpoint #', Handle, ' already enabled');
    Result := True;
    Exit;
  end;

  if FBreakpoints[Idx].Active then
  begin
    if not FProcessController.SetBreakpoint(FBreakpoints[Idx].Address) then
    begin
      WriteLn('[ERROR] Failed to re-insert breakpoint at 0x',
              IntToHex(FBreakpoints[Idx].Address, 16));
      Exit;
    end;
  end;

  FBreakpoints[Idx].Enabled := True;
  WriteLn('[INFO] Breakpoint #', Handle, ' enabled');
  Result := True;
end;

function TDebuggerEngine.DisableBreakpoint(Handle: TBreakpointHandle): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  Idx := FindBreakpointByHandle(Handle);
  if Idx < 0 then
  begin
    WriteLn('[ERROR] Breakpoint #', Handle, ' not found');
    Exit;
  end;

  if not FBreakpoints[Idx].Enabled then
  begin
    WriteLn('[INFO] Breakpoint #', Handle, ' already disabled');
    Result := True;
    Exit;
  end;

  if FBreakpoints[Idx].Active then
    FProcessController.RemoveBreakpoint(FBreakpoints[Idx].Address);

  FBreakpoints[Idx].Enabled := False;
  WriteLn('[INFO] Breakpoint #', Handle, ' disabled');
  Result := True;
end;

procedure TDebuggerEngine.SetTemporary(Handle: TBreakpointHandle);
var
  Idx: Integer;
begin
  Idx := FindBreakpointByHandle(Handle);
  if Idx >= 0 then
    FBreakpoints[Idx].Temporary := True;
end;

function TDebuggerEngine.GetBreakpointList: TStringArray;
var
  I: Integer;
  S: String;
begin
  SetLength(Result, 0);
  for I := 0 to High(FBreakpoints) do
  begin
    if not FBreakpoints[I].Enabled then
      S := Format('#%-3d 0x%016X  %-30s disabled', [
        FBreakpoints[I].Handle,
        FBreakpoints[I].Address,
        FBreakpoints[I].Location])
    else
      S := Format('#%-3d 0x%016X  %-30s %s', [
        FBreakpoints[I].Handle,
        FBreakpoints[I].Address,
        FBreakpoints[I].Location,
        BoolToStr(FBreakpoints[I].Active, 'active', 'inactive')
      ]);

    if FBreakpoints[I].Temporary then
      S := S + '   (temporary)';

    case FBreakpoints[I].ConditionType of
      bctHitCount:
        S := S + Format('   count=%d (hits: %d)', [
          FBreakpoints[I].HitCount,
          FBreakpoints[I].CurrentHitCount
        ]);
      bctExpression:
        S := S + Format('   if %s (hits: %d)', [
          FBreakpoints[I].ConditionExpr,
          FBreakpoints[I].CurrentHitCount
        ]);
    end;

    if Length(FBreakpoints[I].Commands) > 0 then
      S := S + Format('   [%d cmd(s)]', [Length(FBreakpoints[I].Commands)]);

    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;
end;

{ Display list (auto-print on every stop) }

function TDebuggerEngine.AddDisplay(const Expr: String): Boolean;
var
  I: Integer;
begin
  { Check if already in list (case-insensitive) }
  for I := 0 to High(FDisplayList) do
    if LowerCase(FDisplayList[I]) = LowerCase(Expr) then
    begin
      WriteLn('[INFO] Already displaying: ', Expr);
      Result := False;
      Exit;
    end;

  SetLength(FDisplayList, Length(FDisplayList) + 1);
  FDisplayList[High(FDisplayList)] := Expr;
  WriteLn('[INFO] Display added: ', Expr);
  Result := True;
end;

procedure TDebuggerEngine.RemoveDisplay(const Expr: String);
var
  I, J: Integer;
begin
  for I := 0 to High(FDisplayList) do
    if LowerCase(FDisplayList[I]) = LowerCase(Expr) then
    begin
      for J := I to High(FDisplayList) - 1 do
        FDisplayList[J] := FDisplayList[J + 1];
      SetLength(FDisplayList, Length(FDisplayList) - 1);
      WriteLn('[INFO] Display removed: ', Expr);
      Exit;
    end;

  WriteLn('[ERROR] Not in display list: ', Expr);
end;

procedure TDebuggerEngine.ClearDisplay;
begin
  SetLength(FDisplayList, 0);
  WriteLn('[INFO] All display entries removed');
end;

function TDebuggerEngine.GetDisplayList: TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(FDisplayList));
  for I := 0 to High(FDisplayList) do
    Result[I] := FDisplayList[I];
end;

function TDebuggerEngine.EvaluateDisplayList: TVariableValueArray;
var
  I: Integer;
  Val: TVariableValue;
begin
  SetLength(Result, Length(FDisplayList));
  for I := 0 to High(FDisplayList) do
  begin
    Val := EvaluateExpression(FDisplayList[I]);
    if not Val.IsValid then
    begin
      Val.Name := FDisplayList[I];
      Val.Value := '(out of scope)';
      Val.IsValid := True;
    end;
    Result[I] := Val;
  end;
end;

{ Hardware watchpoints }

function TDebuggerEngine.SetWatch(const VarName: String; WatchType: TWatchpointType): Boolean;
var
  RIP, Addr, RBP: QWord;
  VarInfo: TVariableInfo;
  TypeInfo: TTypeInfo;
  Slot: Integer;
  Entry: TWatchpointEntry;
  WatchSize: Byte;
  CurVal: TVariableValue;
begin
  Result := False;

  if FState = dsIdle then
  begin
    WriteLn('[ERROR] Not attached to process');
    Exit;
  end;

  RIP := FProcessController.GetLastBreakpointAddress;
  if RIP = 0 then RIP := FProcessController.GetCurrentAddress;

  if not FDebugInfoReader.FindVariableWithScope(VarName, RIP, VarInfo) then
  begin
    WriteLn('[ERROR] Variable not found: ', VarName);
    Exit;
  end;

  if not FDebugInfoReader.FindType(VarInfo.TypeID, TypeInfo) then
  begin
    WriteLn('[ERROR] Type not found for: ', VarName);
    Exit;
  end;

  { Compute actual address }
  if VarInfo.LocationExpr = 1 then
  begin
    RBP := FProcessController.GetLastBreakpointRBP;
    if RBP = 0 then RBP := FProcessController.GetFrameBasePointer;
    Addr := RBP + QWord(Int64(VarInfo.LocationData));
  end
  else if VarInfo.LocationExpr = 4 then
  begin
    RBP := FProcessController.GetTLSBase;
    if RBP <> 0 then
      Addr := RBP + QWord(Int64(VarInfo.LocationData))
    else
      Addr := 0;
  end
  else
    Addr := VarInfo.Address;

  if Addr = 0 then
  begin
    WriteLn('[ERROR] Cannot determine address for: ', VarName);
    Exit;
  end;

  { Determine watch size — hardware supports 1, 2, 4, 8 }
  if TypeInfo.Size <= 1 then
    WatchSize := 1
  else if TypeInfo.Size <= 2 then
    WatchSize := 2
  else if TypeInfo.Size <= 4 then
    WatchSize := 4
  else if TypeInfo.Size <= 8 then
    WatchSize := 8
  else
  begin
    WriteLn('[ERROR] Variable too large for hardware watchpoint (', TypeInfo.Size, ' bytes, max 8)');
    Exit;
  end;

  { Read current value as OldValue }
  CurVal := EvaluateExpression(VarName);

  { Set hardware watchpoint }
  Slot := FProcessController.SetWatchpoint(Addr, WatchSize, WatchType);
  if Slot < 0 then
  begin
    WriteLn('[ERROR] Cannot set watchpoint (all 4 hardware slots in use)');
    Exit;
  end;

  { Store entry }
  Entry.Slot := Slot;
  Entry.VarName := VarName;
  Entry.Address := Addr;
  Entry.Size := WatchSize;
  if CurVal.IsValid then
    Entry.OldValue := CurVal.Value
  else
    Entry.OldValue := '<unknown>';
  Entry.Active := True;

  SetLength(FWatchpoints, Length(FWatchpoints) + 1);
  FWatchpoints[High(FWatchpoints)] := Entry;

  WriteLn('[INFO] Watchpoint set on ', VarName, ' at $', HexStr(Addr, 16), ' (slot ', Slot, ')');
  Result := True;
end;

function TDebuggerEngine.RemoveWatch(const VarName: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FWatchpoints) do
    if FWatchpoints[I].Active and (FWatchpoints[I].VarName = VarName) then
    begin
      FProcessController.ClearWatchpoint(FWatchpoints[I].Slot);
      FWatchpoints[I].Active := False;
      WriteLn('[INFO] Watchpoint removed: ', VarName);
      Result := True;
      Exit;
    end;
  if not Result then
    WriteLn('[ERROR] No watchpoint on variable: ', VarName);
end;

function TDebuggerEngine.GetWatchpointList: TStringArray;
var
  I, Count: Integer;
begin
  Count := 0;
  for I := 0 to High(FWatchpoints) do
    if FWatchpoints[I].Active then
      Inc(Count);

  SetLength(Result, Count);
  Count := 0;
  for I := 0 to High(FWatchpoints) do
    if FWatchpoints[I].Active then
    begin
      Result[Count] := 'Slot ' + IntToStr(FWatchpoints[I].Slot) + ': ' +
        FWatchpoints[I].VarName + ' at $' + HexStr(FWatchpoints[I].Address, 16);
      Inc(Count);
    end;
end;

{ Inspection }

function TDebuggerEngine.EvaluateExpression(const Expr: String): TVariableValue;
var
  Parser: TExprParser;
  AST: TExprNode;
  Evaluator: TExprEvaluator;
  ExprVal: TExprValue;
begin
  Result.Name := Expr;
  Result.IsValid := False;

  if FState = dsIdle then
  begin
    Result.Value := '<error: not attached to process>';
    Result.TypeName := '<unknown>';
    Exit;
  end;

  Parser := TExprParser.Create(Expr);
  try
    try
      AST := Parser.Parse;
    except
      on E: EExprParseError do
      begin
        Result.Value := E.Message;
        Exit;
      end;
    end;

    try
      if (AST.Kind = enkIdent) and (Pos('.', Expr) = 0) then
      begin
        Result := FTypeSystem.EvaluateVariable(Expr);
        Exit;
      end;

      Evaluator := TExprEvaluator.Create(FTypeSystem, FDebugInfoReader,
        @EvaluateArraySlice);
      try
        try
          ExprVal := Evaluator.Evaluate(AST);
          Result.Name := Expr;
          Result.Value := Evaluator.FormatValue(ExprVal);
          Result.TypeName := ExprVal.TypeName;
          Result.IsValid := True;
        except
          on E: EExprEvalError do
          begin
            Result.Value := E.Message;
            Exit;
          end;
        end;
      finally
        Evaluator.Free;
      end;
    finally
      AST.Free;
    end;
  finally
    Parser.Free;
  end;
end;

function TDebuggerEngine.GetLocalVariables: TVariableValueArray;
var
  RIP: QWord;
  Locals: TVariableInfoArray;
  I: Integer;
begin
  SetLength(Result, 0);

  if FState = dsIdle then
    Exit;

  if FTypeSystem.OverrideRIP <> 0 then
    RIP := FTypeSystem.OverrideRIP
  else
  begin
    RIP := FProcessController.GetLastBreakpointAddress;
    if RIP = 0 then
      RIP := FProcessController.GetCurrentAddress;
  end;
  if RIP = 0 then
    Exit;

  Locals := FDebugInfoReader.GetScopeLocals(RIP);
  SetLength(Result, Length(Locals));
  for I := 0 to High(Locals) do
  begin
    try
      Result[I] := FTypeSystem.EvaluateVariableInfo(Locals[I]);
    except
      on E: Exception do
      begin
        Result[I].Name := Locals[I].Name;
        Result[I].Value := '<error: ' + E.Message + '>';
        Result[I].TypeName := '';
        Result[I].IsValid := False;
      end;
    end;
  end;
end;

function TDebuggerEngine.GetLocalVariablesWithParents: TVariableValueArray;
var
  RIP: QWord;
  Locals: TVariableInfoArray;
  I: Integer;
begin
  SetLength(Result, 0);

  if FState = dsIdle then
    Exit;

  if FTypeSystem.OverrideRIP <> 0 then
    RIP := FTypeSystem.OverrideRIP
  else
  begin
    RIP := FProcessController.GetLastBreakpointAddress;
    if RIP = 0 then
      RIP := FProcessController.GetCurrentAddress;
  end;
  if RIP = 0 then
    Exit;

  Locals := FDebugInfoReader.GetScopeLocalsWithParents(RIP);
  SetLength(Result, Length(Locals));
  for I := 0 to High(Locals) do
  begin
    try
      Result[I] := FTypeSystem.EvaluateVariableInfo(Locals[I]);
    except
      on E: Exception do
      begin
        Result[I].Name := Locals[I].Name;
        Result[I].Value := '<error: ' + E.Message + '>';
        Result[I].TypeName := '';
        Result[I].IsValid := False;
      end;
    end;
  end;
end;

function TDebuggerEngine.GetGlobalVariables: TVariableValueArray;
var
  Names: TStringArray;
  I: Integer;
  Val: TVariableValue;
begin
  SetLength(Result, 0);

  if FState = dsIdle then
    Exit;

  Names := FDebugInfoReader.GetGlobalVariables;
  for I := 0 to High(Names) do
  begin
    try
      Val := EvaluateExpression(Names[I]);
      if Val.IsValid then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Val;
      end;
    except
      { Skip globals that fail to evaluate }
    end;
  end;
end;

function TDebuggerEngine.GetInspectLines(const Expr: String): TStringArray;

  procedure AddLine(const S: String);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

var
  RIP: QWord;
  VarInfo: TVariableInfo;
  SelfVarInfo: TVariableInfo;
  SelfTypeInfo: TTypeInfo;
  SelfAddr: QWord;
  InstancePtr: QWord;
  PtrBuf: array[0..7] of Byte;
  RBP: QWord;
  TypeInfo: TTypeInfo;
  ParentTypeInfo: TTypeInfo;
  ParentTypeID: TTypeID;
  ParentChain: String;
  FieldValue: TVariableValue;
  FieldTypeInfo: TTypeInfo;
  I, J: Integer;
  BackingField: String;
  SingleValue: TVariableValue;
  FoundField: Boolean;
begin
  SetLength(Result, 0);

  if FState = dsIdle then
  begin
    AddLine('[INSPECT] Error: not attached to process');
    Exit;
  end;

  if FTypeSystem.OverrideRIP <> 0 then
    RIP := FTypeSystem.OverrideRIP
  else
  begin
    RIP := FProcessController.GetLastBreakpointAddress;
    if RIP = 0 then
      RIP := FProcessController.GetCurrentAddress;
  end;

  { Find the variable }
  if not FDebugInfoReader.FindVariableWithScope(Expr, RIP, VarInfo) then
  begin
    { Try implicit Self field resolution — when inside a method,
      resolve bare field names via the Self instance pointer }
    FoundField := False;
    if (RIP <> 0) and FDebugInfoReader.FindVariableWithScope('Self', RIP, SelfVarInfo) then
    begin
      if FDebugInfoReader.FindType(SelfVarInfo.TypeID, SelfTypeInfo) and
         (SelfTypeInfo.Category = tcClass) and (SelfTypeInfo.ClassInfo <> nil) then
      begin
        { Resolve Self's stack address to get instance pointer }
        if FTypeSystem.OverrideRBP <> 0 then
          RBP := FTypeSystem.OverrideRBP
        else
        begin
          RBP := FProcessController.GetLastBreakpointRBP;
          if RBP = 0 then
            RBP := FProcessController.GetFrameBasePointer;
        end;
        if RBP <> 0 then
        begin
          SelfAddr := RBP + SelfVarInfo.LocationData;
          FillChar(PtrBuf, SizeOf(PtrBuf), 0);
          if FProcessController.ReadMemory(SelfAddr, 8, PtrBuf) then
          begin
            InstancePtr := PQWord(@PtrBuf)^;
            { Search class fields for a match }
            for I := 0 to High(SelfTypeInfo.ClassInfo^.Fields) do
            begin
              if CompareText(SelfTypeInfo.ClassInfo^.Fields[I].Name, Expr) = 0 then
              begin
                VarInfo.Name := Expr;
                VarInfo.TypeID := SelfTypeInfo.ClassInfo^.Fields[I].TypeID;
                VarInfo.Address := InstancePtr + SelfTypeInfo.ClassInfo^.Fields[I].Offset;
                VarInfo.LocationExpr := 0;
                VarInfo.LocationData := 0;
                FoundField := True;
                Break;
              end;
            end;
          end;
        end;
      end;
    end;

    if not FoundField then
    begin
      AddLine('[INSPECT] Error: variable not found: ' + Expr);
      Exit;
    end;
  end;

  { Find its type }
  if not FDebugInfoReader.FindType(VarInfo.TypeID, TypeInfo) then
  begin
    AddLine('[INSPECT] Error: type not found for: ' + Expr);
    Exit;
  end;

  case TypeInfo.Category of

    tcRecord:
    begin
      AddLine('[INSPECT] ' + Expr + ': ' + TypeInfo.Name +
              ' (record, ' + IntToStr(TypeInfo.Size) + ' bytes)');
      if (TypeInfo.RecordInfo <> nil) and (Length(TypeInfo.RecordInfo^.Fields) > 0) then
      begin
        AddLine('[INSPECT] fields (' +
                IntToStr(Length(TypeInfo.RecordInfo^.Fields)) + '):');
        for I := 0 to High(TypeInfo.RecordInfo^.Fields) do
        begin
          FieldValue := EvaluateExpression(Expr + '.' + TypeInfo.RecordInfo^.Fields[I].Name);
          if FDebugInfoReader.FindType(TypeInfo.RecordInfo^.Fields[I].TypeID, FieldTypeInfo) then
            BackingField := '     [' + FieldTypeInfo.Name + ', offset +' +
                            IntToStr(TypeInfo.RecordInfo^.Fields[I].Offset) + ']'
          else
            BackingField := '';
          if FieldValue.IsValid then
            AddLine(TypeInfo.RecordInfo^.Fields[I].Name + ' = ' + FieldValue.Value + BackingField)
          else
            AddLine(TypeInfo.RecordInfo^.Fields[I].Name + ' = <error>' + BackingField);
        end;
      end;
    end;

    tcClass:
    begin
      if TypeInfo.ClassInfo <> nil then
      begin
        { Build parent chain }
        ParentChain := TypeInfo.Name;
        ParentTypeID := TypeInfo.ClassInfo^.ParentTypeID;
        while ParentTypeID <> 0 do
        begin
          if FDebugInfoReader.FindType(ParentTypeID, ParentTypeInfo) then
          begin
            ParentChain := ParentChain + ' -> ' + ParentTypeInfo.Name;
            if ParentTypeInfo.ClassInfo <> nil then
              ParentTypeID := ParentTypeInfo.ClassInfo^.ParentTypeID
            else
              ParentTypeID := 0;
          end
          else
            ParentTypeID := 0;
        end;

        AddLine('[INSPECT] ' + Expr + ': ' + TypeInfo.Name +
                ' (class, ' + IntToStr(TypeInfo.ClassInfo^.InstanceSize) + ' bytes)');
        if ParentChain <> TypeInfo.Name then
          AddLine('[INSPECT] parent chain: ' + ParentChain);

        if Length(TypeInfo.ClassInfo^.ClassVars) > 0 then
        begin
          AddLine('[INSPECT] class vars (' +
                  IntToStr(Length(TypeInfo.ClassInfo^.ClassVars)) + '):');
          for I := 0 to High(TypeInfo.ClassInfo^.ClassVars) do
          begin
            FieldValue := EvaluateExpression(TypeInfo.Name + '.' + TypeInfo.ClassInfo^.ClassVars[I].Name);
            if FDebugInfoReader.FindType(TypeInfo.ClassInfo^.ClassVars[I].TypeID, FieldTypeInfo) then
              BackingField := '     [' + FieldTypeInfo.Name + ', class var]'
            else
              BackingField := '     [class var]';
            if FieldValue.IsValid then
              AddLine(TypeInfo.ClassInfo^.ClassVars[I].Name + ' = ' + FieldValue.Value + BackingField)
            else
              AddLine(TypeInfo.ClassInfo^.ClassVars[I].Name + ' = <error>' + BackingField);
          end;
        end;

        if Length(TypeInfo.ClassInfo^.ClassConsts) > 0 then
        begin
          AddLine('[INSPECT] class consts (' +
                  IntToStr(Length(TypeInfo.ClassInfo^.ClassConsts)) + '):');
          for I := 0 to High(TypeInfo.ClassInfo^.ClassConsts) do
          begin
            if FDebugInfoReader.FindType(TypeInfo.ClassInfo^.ClassConsts[I].TypeID, FieldTypeInfo) then
              BackingField := '     [' + FieldTypeInfo.Name + ', class const]'
            else
              BackingField := '     [class const]';
            AddLine(TypeInfo.ClassInfo^.ClassConsts[I].Name + ' = ' +
                    FormatClassConst(TypeInfo.ClassInfo^.ClassConsts[I]) +
                    BackingField);
          end;
        end;

        if Length(TypeInfo.ClassInfo^.Fields) > 0 then
        begin
          AddLine('[INSPECT] fields (' +
                  IntToStr(Length(TypeInfo.ClassInfo^.Fields)) + '):');
          for I := 0 to High(TypeInfo.ClassInfo^.Fields) do
          begin
            FieldValue := EvaluateExpression(Expr + '.' + TypeInfo.ClassInfo^.Fields[I].Name);
            if FDebugInfoReader.FindType(TypeInfo.ClassInfo^.Fields[I].TypeID, FieldTypeInfo) then
              BackingField := '     [' + FieldTypeInfo.Name + ', offset +' +
                              IntToStr(TypeInfo.ClassInfo^.Fields[I].Offset) + ']'
            else
              BackingField := '';
            if FieldValue.IsValid then
              AddLine(TypeInfo.ClassInfo^.Fields[I].Name + ' = ' + FieldValue.Value + BackingField)
            else
              AddLine(TypeInfo.ClassInfo^.Fields[I].Name + ' = <error>' + BackingField);
          end;
        end;

        if Length(TypeInfo.ClassInfo^.Properties) > 0 then
        begin
          AddLine('[INSPECT] properties (' +
                  IntToStr(Length(TypeInfo.ClassInfo^.Properties)) + '):');
          for I := 0 to High(TypeInfo.ClassInfo^.Properties) do
          begin
            if TypeInfo.ClassInfo^.Properties[I].ReadKind = pakField then
            begin
              { Find backing field name by matching offset }
              BackingField := '';
              for J := 0 to High(TypeInfo.ClassInfo^.Fields) do
                if TypeInfo.ClassInfo^.Fields[J].Offset = TypeInfo.ClassInfo^.Properties[I].ReadOffset then
                begin
                  BackingField := TypeInfo.ClassInfo^.Fields[J].Name;
                  Break;
                end;
              FieldValue := EvaluateExpression(
                Expr + '.' + TypeInfo.ClassInfo^.Properties[I].Name);
              if BackingField <> '' then
                BackingField := '     [read ' + BackingField + ']'
              else
                BackingField := '     [read field]';
              if FieldValue.IsValid then
                AddLine(TypeInfo.ClassInfo^.Properties[I].Name + ' = ' + FieldValue.Value + BackingField)
              else
                AddLine(TypeInfo.ClassInfo^.Properties[I].Name + ' = <error>' + BackingField);
            end
            else if TypeInfo.ClassInfo^.Properties[I].ReadKind = pakMethod then
            begin
              { Show getter name without calling — use "print Obj.Prop" to evaluate }
              if TypeInfo.ClassInfo^.Properties[I].ReadMethodName <> '' then
                AddLine(TypeInfo.ClassInfo^.Properties[I].Name +
                  ' = <getter: ' + TypeInfo.ClassInfo^.Properties[I].ReadMethodName +
                  '>     [use ''print ' + Expr + '.' +
                  TypeInfo.ClassInfo^.Properties[I].Name + ''' to evaluate]')
              else
                AddLine(TypeInfo.ClassInfo^.Properties[I].Name + ' = <getter>');
            end
            else
            begin
              AddLine(TypeInfo.ClassInfo^.Properties[I].Name + ' = <write-only>');
            end;
          end;
        end;

        if Length(TypeInfo.ClassInfo^.Methods) > 0 then
        begin
          AddLine('[INSPECT] methods (' +
                  IntToStr(Length(TypeInfo.ClassInfo^.Methods)) + '):');
          for I := 0 to High(TypeInfo.ClassInfo^.Methods) do
            AddLine('[INSPECT]   ' + TypeInfo.ClassInfo^.Methods[I]);
        end;
      end
      else
      begin
        SingleValue := EvaluateExpression(Expr);
        if SingleValue.IsValid then
          AddLine(SingleValue.Name + ' = ' + SingleValue.Value);
      end;
    end;

    tcInterface:
    begin
      if TypeInfo.InterfaceInfo <> nil then
      begin
        AddLine('[INSPECT] ' + Expr + ': ' + TypeInfo.Name + ' (interface)');

        { Show parent interface if any }
        if TypeInfo.InterfaceInfo^.ParentTypeID <> 0 then
        begin
          if FDebugInfoReader.FindType(TypeInfo.InterfaceInfo^.ParentTypeID, ParentTypeInfo) then
            AddLine('[INSPECT] parent: ' + ParentTypeInfo.Name)
          else
            AddLine('[INSPECT] parent TypeID: ' + IntToStr(TypeInfo.InterfaceInfo^.ParentTypeID));
        end;

        { Show current pointer value }
        SingleValue := EvaluateExpression(Expr);
        if SingleValue.IsValid then
          AddLine('[INSPECT] value: ' + SingleValue.Value);

        { Show method list — format matches class method-backed properties }
        if Length(TypeInfo.InterfaceInfo^.Methods) > 0 then
        begin
          AddLine('[INSPECT] methods (' +
                  IntToStr(Length(TypeInfo.InterfaceInfo^.Methods)) + '):');
          for I := 0 to High(TypeInfo.InterfaceInfo^.Methods) do
            AddLine(TypeInfo.InterfaceInfo^.Methods[I] + ' = <method>');
        end;
      end
      else
      begin
        { Fallback: no interface info loaded }
        SingleValue := EvaluateExpression(Expr);
        if SingleValue.IsValid then
          AddLine(SingleValue.Name + ' = ' + SingleValue.Value);
      end;
    end;

  else
    begin
      { For primitives, floats, strings, enums, sets, pointers, arrays: same as print }
      SingleValue := EvaluateExpression(Expr);
      if SingleValue.IsValid then
        AddLine(SingleValue.Name + ' = ' + SingleValue.Value)
      else
        AddLine('[INSPECT] ' + SingleValue.Value);
    end;
  end;
end;

function TDebuggerEngine.EvaluateArraySlice(const VarName: String;
                                             LowIndex, HighIndex: Int64): TVariableValueArray;
var
  RIP: QWord;
  VarInfo: TVariableInfo;
  TypeInfo: TTypeInfo;
  ElemTypeInfo: TTypeInfo;
  ElemSize: Cardinal;
  LowerBound, UpperBound: Int64;
  BaseAddr: QWord;
  RBP: QWord;
  I: Int64;
  ElemInfo: TVariableInfo;
  ElemValue: TVariableValue;
begin
  SetLength(Result, 0);
  if FState = dsIdle then Exit;

  if FTypeSystem.OverrideRIP <> 0 then
    RIP := FTypeSystem.OverrideRIP
  else
  begin
    RIP := FProcessController.GetLastBreakpointAddress;
    if RIP = 0 then RIP := FProcessController.GetCurrentAddress;
  end;

  if not FDebugInfoReader.FindVariableWithScope(VarName, RIP, VarInfo) then
  begin
    WriteLn('[ERROR] Variable not found: ', VarName);
    Exit;
  end;

  if not FDebugInfoReader.FindType(VarInfo.TypeID, TypeInfo) then
  begin
    WriteLn('[ERROR] Type not found for: ', VarName);
    Exit;
  end;

  if TypeInfo.Category <> tcArray then
  begin
    WriteLn('[ERROR] Variable is not an array: ', VarName);
    Exit;
  end;

  if not FDebugInfoReader.FindType(TypeInfo.ElementTypeID, ElemTypeInfo) then
  begin
    WriteLn('[ERROR] Element type not found');
    Exit;
  end;

  ElemSize := ElemTypeInfo.Size;
  if ElemSize = 0 then ElemSize := 1;

  if Length(TypeInfo.Bounds) = 0 then
  begin
    WriteLn('[ERROR] Array has no bounds info');
    Exit;
  end;

  LowerBound := TypeInfo.Bounds[0].LowerBound;
  UpperBound := TypeInfo.Bounds[0].UpperBound;

  { Compute actual base address }
  if VarInfo.LocationExpr = 1 then
  begin
    if FTypeSystem.OverrideRBP <> 0 then
      RBP := FTypeSystem.OverrideRBP
    else
    begin
      RBP := FProcessController.GetLastBreakpointRBP;
      if RBP = 0 then RBP := FProcessController.GetFrameBasePointer;
    end;
    BaseAddr := RBP + VarInfo.LocationData;
  end
  else if VarInfo.LocationExpr = 4 then
  begin
    RBP := FProcessController.GetTLSBase;
    if RBP <> 0 then
      BaseAddr := RBP + QWord(Int64(VarInfo.LocationData))
    else
      BaseAddr := 0;
  end
  else
    BaseAddr := VarInfo.Address;

  { Clamp slice indices to actual bounds with warnings }
  if LowIndex < LowerBound then
  begin
    WriteLn('[WARN] Low index clamped from ', LowIndex, ' to ', LowerBound);
    LowIndex := LowerBound;
  end;
  if HighIndex > UpperBound then
  begin
    WriteLn('[WARN] High index clamped from ', HighIndex, ' to ', UpperBound);
    HighIndex := UpperBound;
  end;

  if LowIndex > HighIndex then Exit;

  SetLength(Result, HighIndex - LowIndex + 1);
  for I := LowIndex to HighIndex do
  begin
    ElemInfo.Name    := VarName + '[' + IntToStr(I) + ']';
    ElemInfo.TypeID  := TypeInfo.ElementTypeID;
    ElemInfo.Address := BaseAddr + QWord(I - LowerBound) * ElemSize;
    ElemInfo.LocationExpr := 0;
    ElemInfo.LocationData := 0;

    ElemValue      := FTypeSystem.EvaluateVariableInfo(ElemInfo);
    ElemValue.Name := VarName + '[' + IntToStr(I) + ']';
    Result[I - LowIndex] := ElemValue;
  end;
end;

function TDebuggerEngine.SetVariable(const VarName, Value: String): Boolean;
var
  RIP, Addr: QWord;
  VarInfo: TVariableInfo;
  TypeInfo: TTypeInfo;
  IntVal: Int64;
  OrdVal: Int64;
  Buffer: array[0..7] of Byte;
  RBP: QWord;
  I: Integer;
begin
  Result := False;

  if FState = dsIdle then
  begin
    WriteLn('[ERROR] Not attached to process');
    Exit;
  end;

  if FTypeSystem.OverrideRIP <> 0 then
    RIP := FTypeSystem.OverrideRIP
  else
  begin
    RIP := FProcessController.GetLastBreakpointAddress;
    if RIP = 0 then RIP := FProcessController.GetCurrentAddress;
  end;

  if not FDebugInfoReader.FindVariableWithScope(VarName, RIP, VarInfo) then
  begin
    WriteLn('[ERROR] Variable not found: ', VarName);
    Exit;
  end;

  if not FDebugInfoReader.FindType(VarInfo.TypeID, TypeInfo) then
  begin
    WriteLn('[ERROR] Type not found for: ', VarName);
    Exit;
  end;

  { Compute actual address }
  if VarInfo.LocationExpr = 1 then
  begin
    if FTypeSystem.OverrideRBP <> 0 then
      RBP := FTypeSystem.OverrideRBP
    else
    begin
      RBP := FProcessController.GetLastBreakpointRBP;
      if RBP = 0 then RBP := FProcessController.GetFrameBasePointer;
    end;
    Addr := RBP + VarInfo.LocationData;
  end
  else if VarInfo.LocationExpr = 4 then
  begin
    RBP := FProcessController.GetTLSBase;
    if RBP <> 0 then
      Addr := RBP + QWord(Int64(VarInfo.LocationData))
    else
      Addr := 0;
  end
  else
    Addr := VarInfo.Address;

  if Addr = 0 then
  begin
    WriteLn('[ERROR] Cannot determine address for: ', VarName);
    Exit;
  end;

  FillChar(Buffer, SizeOf(Buffer), 0);

  case TypeInfo.Category of

    tcPrimitive:
    begin
      { Boolean literals }
      if (LowerCase(Value) = 'true') or (Value = '1') then
        Buffer[0] := 1
      else if (LowerCase(Value) = 'false') or (Value = '0') then
        Buffer[0] := 0
      { Hex literals: $NNNN or 0xNNNN }
      else if (Length(Value) > 1) and (Value[1] = '$') then
      begin
        IntVal := StrToInt64Def(Value, 0);
        Move(IntVal, Buffer[0], Min(TypeInfo.Size, SizeOf(IntVal)));
      end
      else if (Length(Value) > 2) and (Copy(Value, 1, 2) = '0x') then
      begin
        IntVal := StrToInt64Def('$' + Copy(Value, 3, MaxInt), 0);
        Move(IntVal, Buffer[0], Min(TypeInfo.Size, SizeOf(IntVal)));
      end
      { Decimal literals (signed or unsigned) }
      else if TryStrToInt64(Value, IntVal) then
        Move(IntVal, Buffer[0], Min(TypeInfo.Size, SizeOf(IntVal)))
      else
      begin
        WriteLn('[ERROR] Cannot parse value for primitive type: ', Value);
        Exit;
      end;

      Result := FProcessController.WriteMemory(Addr, TypeInfo.Size, Buffer);
    end;

    tcEnum:
    begin
      { Try enum member name first }
      OrdVal := -1;
      for I := 0 to High(TypeInfo.EnumMembers) do
        if LowerCase(TypeInfo.EnumMembers[I].Name) = LowerCase(Value) then
        begin
          OrdVal := TypeInfo.EnumMembers[I].Value;
          Break;
        end;

      { Fall back to ordinal }
      if (OrdVal = -1) and not TryStrToInt64(Value, OrdVal) then
      begin
        WriteLn('[ERROR] Unknown enum member or invalid ordinal: ', Value);
        Exit;
      end;

      Move(OrdVal, Buffer[0], Min(TypeInfo.Size, SizeOf(OrdVal)));
      Result := FProcessController.WriteMemory(Addr, TypeInfo.Size, Buffer);
    end;

  else
    WriteLn('[ERROR] set: type not supported for assignment: ', TypeInfo.Name);
    Exit;
  end;

  if Result then
    WriteLn('[INFO] ', VarName, ' set to ', Value)
  else
    WriteLn('[ERROR] Failed to write to address $', IntToHex(Addr, 16));
end;

function TDebuggerEngine.GetCallStack(Limit: Integer = 0): TStringArray;
var
  Regs: TRegisters;
  FramePtr: QWord;
  StackPtr: QWord;
  RetAddr: QWord;
  FrameCount: Integer;
  FuncInfo: TFunctionInfo;
  LineInfo: TLineInfo;
  FrameStr: String;
  FrameBuffer: array[0..15] of QWord;
  UnwindEntry: TUnwindEntry;
  CFA: QWord;
  TempVal: QWord;
  PtrSize: Byte;
  ReadBuf: array[0..7] of Byte;
begin
  SetLength(Result, 0);
  FrameCount := 0;
  PtrSize := FDebugInfoReader.GetPointerSize;

  { Get current registers }
  if not FProcessController.GetRegisters(Regs) then
  begin
    if gVerbose then WriteLn('[DEBUG] Failed to get registers for callstack');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  FramePtr := Regs.RBP;
  StackPtr := Regs.RSP;
  RetAddr := Regs.RIP;

  while ((FramePtr <> 0) or (StackPtr <> 0)) and
        ((Limit = 0) or (FrameCount < Limit)) do
  begin
    if FDebugInfoReader.FindFunctionByAddress(RetAddr, FuncInfo) then
    begin
      if FDebugInfoReader.FindLineByAddress(RetAddr, LineInfo) then
        FrameStr := Format('#%d %s at %s:%d (0x%016X)',
          [FrameCount, FuncInfo.Name, ExtractFileName(LineInfo.FileName),
           LineInfo.LineNumber, RetAddr])
      else
        FrameStr := Format('#%d %s (0x%016X)', [FrameCount, FuncInfo.Name, RetAddr]);
    end
    else
      FrameStr := Format('#%d <unknown> (0x%016X)', [FrameCount, RetAddr]);

    SetLength(Result, FrameCount + 1);
    Result[FrameCount] := FrameStr;
    Inc(FrameCount);

    { Try unwind info first, fall back to frame-pointer walking }
    if FDebugInfoReader.FindUnwindEntry(RetAddr, UnwindEntry) then
    begin
      if UnwindEntry.CFARegister = 1 then
        CFA := StackPtr + QWord(Int64(UnwindEntry.CFAOffset))
      else
        CFA := FramePtr + QWord(Int64(UnwindEntry.CFAOffset));

      FillChar(ReadBuf, SizeOf(ReadBuf), 0);
      if not FProcessController.ReadMemory(
           CFA + QWord(Int64(UnwindEntry.RetAddrOffset)), PtrSize, ReadBuf) then
        Break;
      RetAddr := PQWord(@ReadBuf)^;

      FillChar(ReadBuf, SizeOf(ReadBuf), 0);
      if not FProcessController.ReadMemory(
           CFA + QWord(Int64(UnwindEntry.SavedBPOffset)), PtrSize, ReadBuf) then
        Break;
      FramePtr := PQWord(@ReadBuf)^;

      StackPtr := CFA;
    end
    else
    begin
      { Classic frame-pointer walking: [RBP] = old RBP, [RBP+8] = return address }
      if FramePtr = 0 then
        Break;
      if not FProcessController.ReadMemory(FramePtr, 16, FrameBuffer) then
        Break;
      FramePtr := FrameBuffer[0];
      RetAddr := FrameBuffer[1];
      StackPtr := 0;
    end;
  end;
  {$ENDIF}

  {$IFDEF CPUI386}
  FramePtr := Regs.EBP;
  StackPtr := Regs.ESP;
  RetAddr := Regs.EIP;

  while ((FramePtr <> 0) or (StackPtr <> 0)) and
        ((Limit = 0) or (FrameCount < Limit)) do
  begin
    if FDebugInfoReader.FindFunctionByAddress(RetAddr, FuncInfo) then
    begin
      if FDebugInfoReader.FindLineByAddress(RetAddr, LineInfo) then
        FrameStr := Format('#%d %s at %s:%d (0x%08X)',
          [FrameCount, FuncInfo.Name, ExtractFileName(LineInfo.FileName),
           LineInfo.LineNumber, RetAddr])
      else
        FrameStr := Format('#%d %s (0x%08X)', [FrameCount, FuncInfo.Name, RetAddr]);
    end
    else
      FrameStr := Format('#%d <unknown> (0x%08X)', [FrameCount, RetAddr]);

    SetLength(Result, FrameCount + 1);
    Result[FrameCount] := FrameStr;
    Inc(FrameCount);

    if FDebugInfoReader.FindUnwindEntry(RetAddr, UnwindEntry) then
    begin
      if UnwindEntry.CFARegister = 1 then
        CFA := StackPtr + QWord(Int64(UnwindEntry.CFAOffset))
      else
        CFA := FramePtr + QWord(Int64(UnwindEntry.CFAOffset));

      FillChar(ReadBuf, SizeOf(ReadBuf), 0);
      if not FProcessController.ReadMemory(
           CFA + QWord(Int64(UnwindEntry.RetAddrOffset)), PtrSize, ReadBuf) then
        Break;
      RetAddr := Cardinal(PDWord(@ReadBuf)^);

      FillChar(ReadBuf, SizeOf(ReadBuf), 0);
      if not FProcessController.ReadMemory(
           CFA + QWord(Int64(UnwindEntry.SavedBPOffset)), PtrSize, ReadBuf) then
        Break;
      FramePtr := Cardinal(PDWord(@ReadBuf)^);

      StackPtr := CFA;
    end
    else
    begin
      if FramePtr = 0 then
        Break;
      if not FProcessController.ReadMemory(FramePtr, 8, FrameBuffer) then
        Break;
      FramePtr := Cardinal(FrameBuffer[0]);
      RetAddr := Cardinal(FrameBuffer[1]);
      StackPtr := 0;
    end;
  end;
  {$ENDIF}
end;

{ Source listing }

function TDebuggerEngine.LoadSourceFile(const FileName: String): TStringList;
var
  Idx: Integer;
  Lines: TStringList;
begin
  Idx := FSourceCache.IndexOf(FileName);
  if Idx >= 0 then
  begin
    Result := TStringList(FSourceCache.Objects[Idx]);
    Exit;
  end;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
  except
    on E: Exception do
    begin
      Lines.Free;
      Result := nil;
      Exit;
    end;
  end;
  FSourceCache.AddObject(FileName, Lines);
  Result := Lines;
end;

function TDebuggerEngine.GetSourceLines(const FileName: String; Line: Integer;
  Before: Integer = 5; After: Integer = 10): TStringArray;
var
  Lines: TStringList;
  StartLine, EndLine, I: Integer;
  LineNum: Integer;
  Marker: String;
begin
  SetLength(Result, 0);
  Lines := LoadSourceFile(FileName);
  if Lines = nil then
  begin
    SetLength(Result, 1);
    Result[0] := '[ERROR] Cannot read source file: ' + FileName;
    Exit;
  end;

  if (Line < 1) or (Line > Lines.Count) then
  begin
    SetLength(Result, 1);
    Result[0] := '[ERROR] Line ' + IntToStr(Line) + ' out of range (file has '
               + IntToStr(Lines.Count) + ' lines)';
    Exit;
  end;

  StartLine := Line - Before;
  if StartLine < 1 then
    StartLine := 1;
  EndLine := Line + After;
  if EndLine > Lines.Count then
    EndLine := Lines.Count;

  SetLength(Result, EndLine - StartLine + 1);
  for I := StartLine to EndLine do
  begin
    LineNum := I;
    if LineNum = Line then
      Marker := '=>'
    else
      Marker := '  ';
    if Lines[LineNum - 1] = '' then
      Result[I - StartLine] := Format('%s %4d', [Marker, LineNum])
    else
      Result[I - StartLine] := Format('%s %4d  %s', [Marker, LineNum, Lines[LineNum - 1]]);
  end;
end;

{ Frame navigation }

procedure TDebuggerEngine.BuildFrameCache;
var
  Regs: TRegisters;
  FramePtr, RetAddr: QWord;
  FrameBuffer: array[0..15] of QWord;
  Count: Integer;
begin
  if FFrameCacheValid then
    Exit;

  SetLength(FFrameRBPs, 0);
  SetLength(FFrameRIPs, 0);
  Count := 0;

  if not FProcessController.GetRegisters(Regs) then
    Exit;

  {$IFDEF CPUX86_64}
  FramePtr := FProcessController.GetLastBreakpointRBP;
  if FramePtr = 0 then
    FramePtr := Regs.RBP;
  RetAddr := FProcessController.GetLastBreakpointAddress;
  if RetAddr = 0 then
    RetAddr := Regs.RIP;

  while (FramePtr <> 0) and (Count < 256) do
  begin
    SetLength(FFrameRBPs, Count + 1);
    SetLength(FFrameRIPs, Count + 1);
    FFrameRBPs[Count] := FramePtr;
    FFrameRIPs[Count] := RetAddr;
    Inc(Count);

    if not FProcessController.ReadMemory(FramePtr, 16, FrameBuffer) then
      Break;
    FramePtr := FrameBuffer[0];
    RetAddr := FrameBuffer[1];
  end;
  {$ENDIF}

  {$IFDEF CPUI386}
  FramePtr := FProcessController.GetLastBreakpointRBP;
  if FramePtr = 0 then
    FramePtr := Regs.EBP;
  RetAddr := FProcessController.GetLastBreakpointAddress;
  if RetAddr = 0 then
    RetAddr := Regs.EIP;

  while (FramePtr <> 0) and (Count < 256) do
  begin
    SetLength(FFrameRBPs, Count + 1);
    SetLength(FFrameRIPs, Count + 1);
    FFrameRBPs[Count] := FramePtr;
    FFrameRIPs[Count] := RetAddr;
    Inc(Count);

    if not FProcessController.ReadMemory(FramePtr, 8, FrameBuffer) then
      Break;
    FramePtr := Cardinal(FrameBuffer[0]);
    RetAddr := Cardinal(FrameBuffer[1]);
  end;
  {$ENDIF}

  FFrameCacheValid := True;
end;

procedure TDebuggerEngine.ResetSelectedFrame;
begin
  FSelectedFrameIndex := 0;
  FFrameCacheValid := False;
  FTypeSystem.OverrideRBP := 0;
  FTypeSystem.OverrideRIP := 0;
end;

function TDebuggerEngine.EvaluateConditionExpr(const Expr: String): Boolean;
var
  Val: TVariableValue;
  LVal: String;
begin
  Val := EvaluateExpression(Expr);
  if not Val.IsValid then
  begin
    WriteLn('[WARNING] Condition evaluation failed: ', Val.Value, ' — stopping');
    Result := True;
    Exit;
  end;
  LVal := LowerCase(Trim(Val.Value));
  Result := (LVal <> '0') and (LVal <> 'false') and (LVal <> 'nil') and (LVal <> '');
end;

procedure TDebuggerEngine.ApplyFrameOverrides;
begin
  if FSelectedFrameIndex = 0 then
  begin
    FTypeSystem.OverrideRBP := 0;
    FTypeSystem.OverrideRIP := 0;
  end
  else
  begin
    FTypeSystem.OverrideRBP := FFrameRBPs[FSelectedFrameIndex];
    FTypeSystem.OverrideRIP := FFrameRIPs[FSelectedFrameIndex];
  end;
end;

function TDebuggerEngine.SelectFrame(Index: Integer): Boolean;
var
  FuncInfo: TFunctionInfo;
  LineInfo: TLineInfo;
begin
  Result := False;

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  BuildFrameCache;

  if (Index < 0) or (Index >= Length(FFrameRBPs)) then
  begin
    WriteLn('[ERROR] Frame ', Index, ' out of range (', Length(FFrameRBPs), ' frames available)');
    Exit;
  end;

  FSelectedFrameIndex := Index;
  ApplyFrameOverrides;

  if FDebugInfoReader.FindFunctionByAddress(FFrameRIPs[Index], FuncInfo) then
  begin
    if FDebugInfoReader.FindLineByAddress(FFrameRIPs[Index], LineInfo) then
      WriteLn('#', Index, '  ', FuncInfo.Name, ' at ',
              ExtractFileName(LineInfo.FileName), ':', LineInfo.LineNumber)
    else
      WriteLn('#', Index, '  ', FuncInfo.Name);
  end
  else
    WriteLn('#', Index, '  <unknown> (0x', IntToHex(FFrameRIPs[Index], 1), ')');

  Result := True;
end;

function TDebuggerEngine.FrameUp: Boolean;
begin
  BuildFrameCache;
  if FSelectedFrameIndex + 1 >= Length(FFrameRBPs) then
  begin
    WriteLn('[ERROR] Already at outermost frame');
    Result := False;
    Exit;
  end;
  Result := SelectFrame(FSelectedFrameIndex + 1);
end;

function TDebuggerEngine.FrameDown: Boolean;
begin
  if FSelectedFrameIndex <= 0 then
  begin
    WriteLn('[ERROR] Already at innermost frame');
    Result := False;
    Exit;
  end;
  Result := SelectFrame(FSelectedFrameIndex - 1);
end;

function TDebuggerEngine.GetSelectedFrameRIP: QWord;
var
  Regs: TRegisters;
begin
  if FTypeSystem.OverrideRIP <> 0 then
  begin
    Result := FTypeSystem.OverrideRIP;
    Exit;
  end;
  Result := FProcessController.GetLastBreakpointAddress;
  if Result = 0 then
    Result := FProcessController.GetCurrentAddress;
end;

{ State query }

function TDebuggerEngine.GetState: TDebuggerState;
begin
  Result := FState;
end;

end.
