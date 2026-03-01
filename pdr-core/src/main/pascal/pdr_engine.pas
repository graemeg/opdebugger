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
  Classes, SysUtils, Math, pdr_ports, pdr_typesys, opdf_types, elf_reader;

type
  { Breakpoint condition type }
  TBreakpointConditionType = (bctNone, bctHitCount);

  { Breakpoint tracking record }
  TBreakpointEntry = record
    Handle: TBreakpointHandle;
    Address: QWord;
    Location: String;  // Original location string (for display)
    Active: Boolean;
    ConditionType: TBreakpointConditionType;
    HitCount: Integer;         // Target hit count (fire on Nth hit)
    CurrentHitCount: Integer;  // Running counter
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

    { Helper methods for breakpoint management }
    function ParseLocation(const Location: String; out Address: QWord): Boolean;
    function FindBreakpointByHandle(Handle: TBreakpointHandle): Integer;
    function FindBreakpointByAddress(Address: QWord): Integer;
    procedure HandleExceptionBreakpoint;
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
    function Pause: Boolean;

    { ICommandHandler - Breakpoints }
    function SetBreakpoint(const Location: String): TBreakpointHandle;
    function RemoveBreakpoint(Handle: TBreakpointHandle): Boolean;

    { Conditional breakpoint support }
    function SetBreakpointCondition(Handle: TBreakpointHandle;
      CondType: TBreakpointConditionType; Count: Integer): Boolean;
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
    function GetInspectLines(const Expr: String): TStringArray;
    function EvaluateArraySlice(const VarName: String;
                                LowIndex, HighIndex: Int64): TVariableValueArray;
    function SetVariable(const VarName, Value: String): Boolean;
    function GetCallStack(Limit: Integer = 0): TStringArray;

    { ICommandHandler - State query }
    function GetState: TDebuggerState;

    { Properties }
    property State: TDebuggerState read FState;
    property BinaryPath: String read FBinaryPath;
    property AttachedPID: Integer read FAttachedPID;
    property CatchExceptions: Boolean read FCatchExceptions write FCatchExceptions;
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
begin
  Result := False;

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

  { Set internal breakpoint on fpc_raiseexception for exception catching }
  FRaiseBreakpointAddr := TELFSectionReader.FindSymbolAddress(FBinaryPath, 'FPC_RAISEEXCEPTION');
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

  if FState <> dsPaused then
  begin
    WriteLn('[ERROR] Process is not paused');
    Exit;
  end;

  if gVerbose then WriteLn('[INFO] Continuing process...');

  repeat
    if not FProcessController.Continue then
    begin
      WriteLn('[ERROR] Failed to continue process');
      Exit;
    end;

    { Check if process exited }
    if FProcessController.GetCurrentAddress = 0 then
    begin
      if gVerbose then WriteLn('[INFO] Process stopped and ready for commands');
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

      if gVerbose then WriteLn('[INFO] Process stopped and ready for commands');
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
      if (Idx >= 0) and (FBreakpoints[Idx].ConditionType = bctHitCount) then
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
    end;
  until ConditionMet;

  if gVerbose then WriteLn('[INFO] Process stopped and ready for commands');
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

function TDebuggerEngine.Pause: Boolean;
begin
  Result := False;
  WriteLn('[WARNING] Pause not implemented yet');
  // TODO: Send SIGSTOP to process
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

  { Display exception info }
  if ExcMessage <> '' then
    WriteLn('Exception: ', ExcClassName, ' — ''', ExcMessage, '''')
  else
    WriteLn('Exception: ', ExcClassName, ' — (no message)');

  { Show raise location if available }
  if (RaiseAddr <> 0) and FDebugInfoReader.FindLineByAddress(RaiseAddr, LineInfo) then
    WriteLn('  raised at ', LineInfo.FileName, ':', LineInfo.LineNumber)
  else if RaiseAddr <> 0 then
    WriteLn('  raised at $', HexStr(RaiseAddr, 16));
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

function TDebuggerEngine.GetBreakpointList: TStringArray;
var
  I: Integer;
  S: String;
begin
  SetLength(Result, 0);
  for I := 0 to High(FBreakpoints) do
  begin
    S := Format('#%-3d 0x%016X  %-30s %s', [
      FBreakpoints[I].Handle,
      FBreakpoints[I].Address,
      FBreakpoints[I].Location,
      BoolToStr(FBreakpoints[I].Active, 'active', 'inactive')
    ]);

    if FBreakpoints[I].ConditionType = bctHitCount then
      S := S + Format('   count=%d (hits: %d)', [
        FBreakpoints[I].HitCount,
        FBreakpoints[I].CurrentHitCount
      ]);

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
var
  RIP: QWord;
  Locals: TVariableInfoArray;
  I: Integer;
begin
  SetLength(Result, 0);

  if FState = dsIdle then
    Exit;

  RIP := FProcessController.GetLastBreakpointAddress;
  if RIP = 0 then
    RIP := FProcessController.GetCurrentAddress;
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

  RIP := FProcessController.GetLastBreakpointAddress;
  if RIP = 0 then
    RIP := FProcessController.GetCurrentAddress;
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

function TDebuggerEngine.GetInspectLines(const Expr: String): TStringArray;

  procedure AddLine(const S: String);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

var
  RIP: QWord;
  VarInfo: TVariableInfo;
  TypeInfo: TTypeInfo;
  ParentTypeInfo: TTypeInfo;
  ParentTypeID: TTypeID;
  ParentChain: String;
  FieldValue: TVariableValue;
  FieldTypeInfo: TTypeInfo;
  I, J: Integer;
  BackingField: String;
  SingleValue: TVariableValue;
begin
  SetLength(Result, 0);

  if FState = dsIdle then
  begin
    AddLine('[INSPECT] Error: not attached to process');
    Exit;
  end;

  RIP := FProcessController.GetLastBreakpointAddress;
  if RIP = 0 then
    RIP := FProcessController.GetCurrentAddress;

  { Find the variable }
  if not FDebugInfoReader.FindVariableWithScope(Expr, RIP, VarInfo) then
  begin
    AddLine('[INSPECT] Error: variable not found: ' + Expr);
    Exit;
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
    RBP := FProcessController.GetLastBreakpointRBP;
    if RBP = 0 then RBP := FProcessController.GetFrameBasePointer;
    BaseAddr := RBP + VarInfo.LocationData;
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
    Addr := RBP + VarInfo.LocationData;
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
  RetAddr: QWord;
  FrameCount: Integer;
  FuncInfo: TFunctionInfo;
  LineInfo: TLineInfo;
  FrameStr: String;
  FrameBuffer: array[0..15] of QWord;
  BytesRead: Cardinal;
  I: Integer;
begin
  SetLength(Result, 0);
  FrameCount := 0;

  { Get current registers }
  if not FProcessController.GetRegisters(Regs) then
  begin
    if gVerbose then WriteLn('[DEBUG] Failed to get registers for callstack');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  { Start with current RBP }
  FramePtr := Regs.RBP;
  RetAddr := Regs.RIP;

  { Walk the stack frames }
  while (FramePtr <> 0) and ((Limit = 0) or (FrameCount < Limit)) do
  begin
    { Find function by return address }
    if FDebugInfoReader.FindFunctionByAddress(RetAddr, FuncInfo) then
    begin
      { Try to get line information }
      if FDebugInfoReader.FindLineByAddress(RetAddr, LineInfo) then
      begin
        FrameStr := Format('#%d %s at %s:%d (0x%016X)',
          [FrameCount, FuncInfo.Name, ExtractFileName(LineInfo.FileName),
           LineInfo.LineNumber, RetAddr]);
      end
      else
      begin
        FrameStr := Format('#%d %s (0x%016X)', [FrameCount, FuncInfo.Name, RetAddr]);
      end;
    end
    else
    begin
      FrameStr := Format('#%d <unknown> (0x%016X)', [FrameCount, RetAddr]);
    end;

    SetLength(Result, FrameCount + 1);
    Result[FrameCount] := FrameStr;
    Inc(FrameCount);

    { Read the next frame pointer and return address }
    { On x86_64: [RBP] = old RBP, [RBP+8] = return address }
    if not FProcessController.ReadMemory(FramePtr, 16, FrameBuffer) then
      Break;

    { Next frame's base pointer }
    FramePtr := FrameBuffer[0];
    { Return address for next frame }
    RetAddr := FrameBuffer[1];
  end;
  {$ENDIF}

  {$IFDEF CPUI386}
  { Start with current EBP }
  FramePtr := Regs.EBP;
  RetAddr := Regs.EIP;

  { Walk the stack frames (same logic as x86_64, but with 32-bit values) }
  while (FramePtr <> 0) and ((Limit = 0) or (FrameCount < Limit)) do
  begin
    { Find function by return address }
    if FDebugInfoReader.FindFunctionByAddress(RetAddr, FuncInfo) then
    begin
      { Try to get line information }
      if FDebugInfoReader.FindLineByAddress(RetAddr, LineInfo) then
      begin
        FrameStr := Format('#%d %s at %s:%d (0x%08X)',
          [FrameCount, FuncInfo.Name, ExtractFileName(LineInfo.FileName),
           LineInfo.LineNumber, RetAddr]);
      end
      else
      begin
        FrameStr := Format('#%d %s (0x%08X)', [FrameCount, FuncInfo.Name, RetAddr]);
      end;
    end
    else
    begin
      FrameStr := Format('#%d <unknown> (0x%08X)', [FrameCount, RetAddr]);
    end;

    SetLength(Result, FrameCount + 1);
    Result[FrameCount] := FrameStr;
    Inc(FrameCount);

    { Read the next frame pointer and return address (32-bit) }
    { On i386: [EBP] = old EBP, [EBP+4] = return address }
    if not FProcessController.ReadMemory(FramePtr, 8, FrameBuffer) then
      Break;

    { Next frame's base pointer }
    FramePtr := Cardinal(FrameBuffer[0]);
    { Return address for next frame }
    RetAddr := Cardinal(FrameBuffer[1]);
  end;
  {$ENDIF}
end;

{ State query }

function TDebuggerEngine.GetState: TDebuggerState;
begin
  Result := FState;
end;

end.
