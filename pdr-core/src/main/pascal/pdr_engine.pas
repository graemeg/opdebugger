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
  Classes, SysUtils, pdr_ports, pdr_typesys, ogopdf;

type
  { Breakpoint tracking record }
  TBreakpointEntry = record
    Handle: TBreakpointHandle;
    Address: QWord;
    Location: String;  // Original location string (for display)
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

    { Helper methods for breakpoint management }
    function ParseLocation(const Location: String; out Address: QWord): Boolean;
    function FindBreakpointByHandle(Handle: TBreakpointHandle): Integer;
    function FindBreakpointByAddress(Address: QWord): Integer;
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
    function StepLine: Boolean;
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
  FNextHandle := 1;  // Start handle numbering at 1
  SetLength(FBreakpoints, 0);

  // Create type system and register evaluators
  FTypeSystem := TTypeSystem.Create(FProcessController, FDebugInfoReader);
  FTypeSystem.RegisterEvaluator(TPrimitiveEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TShortStringEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TAnsiStringEvaluator.Create);
  FTypeSystem.RegisterEvaluator(TUnicodeStringEvaluator.Create);
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
  WriteLn('[INFO] Program started and paused at entry point');
  WriteLn('[INFO] You can now set breakpoints and use "continue" to start execution');
  Result := True;
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

  // Check if process exited (FAttachedPID would be -1 if exited)
  // Note: We need a better way to detect this, but for now check the message
  // The ptrace adapter sets FAttached=False and FPID=-1 on exit

  // For now, assume process is still paused (at breakpoint or after step)
  // TODO: Add a method to query process state from adapter
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

  WriteLn('[INFO] Stepping...');

  if not FProcessController.Step then
  begin
    WriteLn('[ERROR] Failed to step');
    Exit;
  end;

  WriteLn('[INFO] Step complete');
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

  WriteLn('[DEBUG] Current address: 0x', IntToHex(CurrentAddr, 16));

  // Find current source line
  if not FDebugInfoReader.FindLineByAddress(CurrentAddr, CurrentLine) then
  begin
    WriteLn('[ERROR] No source line found for current address 0x', IntToHex(CurrentAddr, 16));
    WriteLn('[INFO] Use "step" for instruction-level stepping');
    Exit;
  end;

  WriteLn('[INFO] Current line: ', CurrentLine.FileName, ':', CurrentLine.LineNumber,
          ' (address: 0x', IntToHex(CurrentLine.Address, 16), ')');

  // Get all line entries for this file
  LineEntries := FDebugInfoReader.GetFileLineEntries(CurrentLine.FileName);
  if Length(LineEntries) = 0 then
  begin
    WriteLn('[ERROR] No line information available for ', CurrentLine.FileName);
    Exit;
  end;

  // Find all addresses for lines AFTER the current line
  // We need to find the actual next executable line
  SetLength(TempBreakpoints, 0);
  for I := 0 to High(LineEntries) do
  begin
    // Only set breakpoints on lines strictly after current line
    // and before or equal to the current line + some reasonable limit (e.g., 100 lines)
    if (LineEntries[I].LineNumber > CurrentLine.LineNumber) and
       (LineEntries[I].LineNumber <= CurrentLine.LineNumber + 100) then
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
        WriteLn('[DEBUG] Set temp breakpoint at line ', LineEntries[I].LineNumber,
                ' (0x', IntToHex(LineEntries[I].Address, 16), ')');
      end;
    end;
  end;

  if Length(TempBreakpoints) = 0 then
  begin
    WriteLn('[ERROR] No subsequent lines found (might be at end of program)');
    WriteLn('[INFO] Current line ', CurrentLine.LineNumber, ' appears to be the last line with debug info');
    Exit;
  end;

  WriteLn('[INFO] Stepping to next line...');

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
        WriteLn('[INFO] Resolved ', FileName, ':', LineNum, ' to address 0x', IntToHex(Address, 8));
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
      WriteLn('[INFO] Breakpoint already set at ', Location);
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
        WriteLn('[INFO] Breakpoint #', Result, ' reactivated at 0x', IntToHex(Address, 16));
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

  // Add to tracking array
  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := Entry;

  Result := FNextHandle;
  Inc(FNextHandle);

  WriteLn('[INFO] Breakpoint #', Result, ' set at 0x', IntToHex(Address, 16), ' (', Location, ')');
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
    WriteLn('[INFO] Breakpoint #', Handle, ' already removed');
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

  WriteLn('[INFO] Breakpoint #', Handle, ' removed from 0x',
          IntToHex(FBreakpoints[Idx].Address, 16));
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
