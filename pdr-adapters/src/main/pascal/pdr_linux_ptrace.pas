{
  PDR Debugger - Linux Ptrace Adapter

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Platform-specific process control implementation for Linux using ptrace.
}
unit pdr_linux_ptrace;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, BaseUnix, Unix, pdr_ports;

type
  { Breakpoint information }
  TBreakpointInfo = record
    Address: QWord;
    OriginalData: cLong;  // Original instruction data
    Active: Boolean;
  end;

  { Linux ptrace implementation of IProcessController }
  TLinuxPtraceAdapter = class(TInterfacedObject, IProcessController)
  private
    FPID: Integer;
    FAttached: Boolean;
    FBreakpoints: array of TBreakpointInfo;
    FLastBreakpointAddr: QWord;  // Address of last breakpoint hit (before handling)
    FCommandLineArgs: array of String;  // Command-line arguments for the program

    { Breakpoint management helpers }
    function FindBreakpoint(Address: QWord): Integer;
    function GetOriginalData(Address: QWord): cLong;
    function HandleBreakpointHit: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { IProcessController implementation }
    function Launch(const BinaryPath: String): Boolean;
    function Attach(PID: Integer): Boolean;
    function Detach: Boolean;
    function Continue: Boolean;
    function Step: Boolean;
    function ReadMemory(Address: QWord; Size: Cardinal; out Buffer): Boolean;
    function WriteMemory(Address: QWord; Size: Cardinal; const Buffer): Boolean;
    function GetRegisters(out Regs: TRegisters): Boolean;
    function SetRegisters(const Regs: TRegisters): Boolean;
    function SetBreakpoint(Address: QWord): Boolean;
    function RemoveBreakpoint(Address: QWord): Boolean;
    function GetCurrentAddress: QWord;
    function GetFrameBasePointer: QWord;

    { Get the address of the last breakpoint that was hit (before handling) }
    function GetLastBreakpointAddress: QWord;

    { Set command-line arguments for program }
    function SetCommandLineArgs(const Args: array of String): Boolean;

    property PID: Integer read FPID;
    property IsAttached: Boolean read FAttached;
  end;

implementation

const
  { ptrace request codes }
  PTRACE_TRACEME    = 0;
  PTRACE_PEEKTEXT   = 1;
  PTRACE_PEEKDATA   = 2;
  PTRACE_PEEKUSER   = 3;
  PTRACE_POKETEXT   = 4;
  PTRACE_POKEDATA   = 5;
  PTRACE_POKEUSER   = 6;
  PTRACE_CONT       = 7;
  PTRACE_KILL       = 8;
  PTRACE_SINGLESTEP = 9;
  PTRACE_GETREGS    = 12;
  PTRACE_SETREGS    = 13;
  PTRACE_ATTACH     = 16;
  PTRACE_DETACH     = 17;
  PTRACE_SYSCALL    = 24;
  PTRACE_SETOPTIONS = $4200;
  PTRACE_GETEVENTMSG = $4201;
  PTRACE_GETSIGINFO = $4202;
  PTRACE_SETSIGINFO = $4203;

  { Signal numbers }
  SIGTRAP = 5;

{ External ptrace function }
function ptrace(request: cInt; pid: TPid; addr: Pointer; data: Pointer): cLong; cdecl; external 'c' name 'ptrace';

{ TLinuxPtraceAdapter }

constructor TLinuxPtraceAdapter.Create;
begin
  inherited Create;
  FPID := -1;
  FAttached := False;
  FLastBreakpointAddr := 0;
end;

destructor TLinuxPtraceAdapter.Destroy;
begin
  if FAttached then
    Detach;
  inherited Destroy;
end;

function TLinuxPtraceAdapter.Launch(const BinaryPath: String): Boolean;
var
  ChildPID: TPid;
  Status: cInt;
  Args: array of PChar;
  I: Integer;
begin
  Result := False;

  if FAttached then
  begin
    WriteLn('[ERROR] Already attached to PID ', FPID);
    Exit;
  end;

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Exit;
  end;

  WriteLn('[INFO] Launching program: ', BinaryPath);

  // Fork a child process
  ChildPID := FpFork;

  if ChildPID = -1 then
  begin
    WriteLn('[ERROR] Failed to fork: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if ChildPID = 0 then
  begin
    // Child process - enable tracing and exec the target program
    if ptrace(PTRACE_TRACEME, 0, nil, nil) = -1 then
    begin
      WriteLn('[ERROR] Child: Failed to enable tracing');
      fpExit(1);
    end;

    // Prepare arguments - include program name and any command-line arguments
    SetLength(Args, Length(FCommandLineArgs) + 2);  // +1 for program name, +1 for nil terminator
    Args[0] := PChar(BinaryPath);
    for I := 0 to High(FCommandLineArgs) do
      Args[I + 1] := PChar(FCommandLineArgs[I]);
    Args[Length(Args) - 1] := nil;  // Null-terminate the array

    // Execute the target program
    FpExecV(PChar(BinaryPath), @Args[0]);

    // If execv returns, it failed
    WriteLn('[ERROR] Child: Failed to exec: ', SysErrorMessage(fpgeterrno));
    fpExit(1);
  end
  else
  begin
    // Parent process - wait for child to stop at exec
    WriteLn('[INFO] Child process created with PID ', ChildPID);

    if FpWaitPid(ChildPID, @Status, 0) = -1 then
    begin
      WriteLn('[ERROR] Failed to wait for child process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    // Check if child stopped due to SIGTRAP (from ptrace)
    if not WIFSTOPPED(Status) then
    begin
      WriteLn('[ERROR] Child process did not stop as expected');
      Exit;
    end;

    FPID := ChildPID;
    FAttached := True;

    WriteLn('[INFO] Child process stopped at entry point');
    WriteLn('[INFO] Debugger has control (process is paused)');
    Result := True;
  end;
end;

function TLinuxPtraceAdapter.Attach(PID: Integer): Boolean;
var
  Status: cInt;
begin
  Result := False;

  if FAttached then
  begin
    WriteLn('[ERROR] Already attached to PID ', FPID);
    Exit;
  end;

  FPID := PID;

  // Attach to the process
  if ptrace(PTRACE_ATTACH, FPID, nil, nil) = -1 then
  begin
    WriteLn('[ERROR] Failed to attach to process ', PID, ': ', SysErrorMessage(fpgeterrno));
    FPID := -1;
    Exit;
  end;

  // Wait for the process to stop
  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
    ptrace(PTRACE_DETACH, FPID, nil, nil);
    FPID := -1;
    Exit;
  end;

  FAttached := True;
  WriteLn('[INFO] Successfully attached to PID ', FPID);
  Result := True;
end;

function TLinuxPtraceAdapter.Detach: Boolean;
var
  I: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[WARN] Not attached to any process');
    Exit(True);
  end;

  // Remove all breakpoints before detaching
  if Length(FBreakpoints) > 0 then
  begin
    WriteLn('[INFO] Removing all breakpoints before detach');
    for I := 0 to High(FBreakpoints) do
    begin
      if FBreakpoints[I].Active then
        RemoveBreakpoint(FBreakpoints[I].Address);
    end;
    SetLength(FBreakpoints, 0);
  end;

  if ptrace(PTRACE_DETACH, FPID, nil, nil) = -1 then
  begin
    WriteLn('[ERROR] Failed to detach from process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  WriteLn('[INFO] Detached from PID ', FPID);
  FAttached := False;
  FPID := -1;
  Result := True;
end;

function TLinuxPtraceAdapter.Continue: Boolean;
var
  Status: cInt;
  WaitResult: TPid;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  if ptrace(PTRACE_CONT, FPID, nil, nil) = -1 then
  begin
    WriteLn('[ERROR] Failed to continue process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Wait for process to stop (breakpoint, signal, or exit)
  WaitResult := FpWaitPid(FPID, @Status, 0);
  if WaitResult = -1 then
  begin
    WriteLn('[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Check why the process stopped
  if WIFSTOPPED(Status) then
  begin
    if WSTOPSIG(Status) = SIGTRAP then
    begin
      // Breakpoint hit - handle it properly
      if not HandleBreakpointHit then
      begin
        WriteLn('[ERROR] Failed to handle breakpoint');
        Exit;
      end;
    end
    else
    begin
      WriteLn('[INFO] Process stopped (signal: ', WSTOPSIG(Status), ')');
    end;
    Result := True;
  end
  else if WIFEXITED(Status) then
  begin
    WriteLn('[INFO] Process exited with code ', WEXITSTATUS(Status));
    FAttached := False;
    FPID := -1;
    Result := True;
  end
  else if WIFSIGNALED(Status) then
  begin
    WriteLn('[INFO] Process terminated by signal ', WTERMSIG(Status));
    FAttached := False;
    FPID := -1;
    Result := True;
  end;
end;

function TLinuxPtraceAdapter.Step: Boolean;
var
  Status: cInt;
  WaitResult: TPid;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  if ptrace(PTRACE_SINGLESTEP, FPID, nil, nil) = -1 then
  begin
    WriteLn('[ERROR] Failed to single step: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Wait for step to complete
  WaitResult := FpWaitPid(FPID, @Status, 0);
  if WaitResult = -1 then
  begin
    WriteLn('[ERROR] Failed to wait for step: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Check step result
  if WIFSTOPPED(Status) then
  begin
    WriteLn('[INFO] Step complete');
    Result := True;
  end
  else if WIFEXITED(Status) then
  begin
    WriteLn('[INFO] Process exited during step with code ', WEXITSTATUS(Status));
    FAttached := False;
    FPID := -1;
    Result := True;
  end
  else if WIFSIGNALED(Status) then
  begin
    WriteLn('[INFO] Process terminated during step by signal ', WTERMSIG(Status));
    FAttached := False;
    FPID := -1;
    Result := True;
  end;
end;

function TLinuxPtraceAdapter.ReadMemory(Address: QWord; Size: Cardinal; out Buffer): Boolean;
var
  P: PByte;
  I: Cardinal;
  Data: cLong;
  BytesToCopy: Cardinal;
  Offset: Cardinal;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  P := @Buffer;
  Offset := 0;

  // ptrace reads word-sized chunks (8 bytes on x86_64, 4 bytes on i386)
  while Offset < Size do
  begin
    // Read a word from the process memory
    Data := ptrace(PTRACE_PEEKDATA, FPID, Pointer(PtrUInt(Address + Offset)), nil);

    if (Data = -1) and (fpgeterrno <> 0) then
    begin
      WriteLn('[ERROR] Failed to read memory at $', IntToHex(Address + Offset, 16),
              ': ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    // Determine how many bytes to copy from this word
    BytesToCopy := SizeOf(cLong);
    if Offset + BytesToCopy > Size then
      BytesToCopy := Size - Offset;

    // Copy the data
    Move(Data, P[Offset], BytesToCopy);
    Inc(Offset, SizeOf(cLong));
  end;

  Result := True;
end;

function TLinuxPtraceAdapter.WriteMemory(Address: QWord; Size: Cardinal; const Buffer): Boolean;
var
  P: PByte;
  I: Cardinal;
  Data: cLong;
  Offset: Cardinal;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  P := @Buffer;
  Offset := 0;

  // ptrace writes word-sized chunks
  while Offset < Size do
  begin
    // For partial writes at the end, we need to read-modify-write
    if Offset + SizeOf(cLong) > Size then
    begin
      // Read existing data
      Data := ptrace(PTRACE_PEEKDATA, FPID, Pointer(PtrUInt(Address + Offset)), nil);
      if (Data = -1) and (fpgeterrno <> 0) then
      begin
        WriteLn('[ERROR] Failed to read memory for partial write: ', SysErrorMessage(fpgeterrno));
        Exit;
      end;

      // Modify only the bytes we want to change
      Move(P[Offset], Data, Size - Offset);
    end
    else
    begin
      // Full word write
      Move(P[Offset], Data, SizeOf(cLong));
    end;

    // Write the word
    if ptrace(PTRACE_POKEDATA, FPID, Pointer(PtrUInt(Address + Offset)), Pointer(Data)) = -1 then
    begin
      WriteLn('[ERROR] Failed to write memory at $', IntToHex(Address + Offset, 16),
              ': ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    Inc(Offset, SizeOf(cLong));
  end;

  Result := True;
end;

function TLinuxPtraceAdapter.GetRegisters(out Regs: TRegisters): Boolean;
{$IFDEF CPUX86_64}
type
  user_regs_struct = record
    r15: QWord;
    r14: QWord;
    r13: QWord;
    r12: QWord;
    rbp: QWord;
    rbx: QWord;
    r11: QWord;
    r10: QWord;
    r9: QWord;
    r8: QWord;
    rax: QWord;
    rcx: QWord;
    rdx: QWord;
    rsi: QWord;
    rdi: QWord;
    orig_rax: QWord;
    rip: QWord;
    cs: QWord;
    eflags: QWord;
    rsp: QWord;
    ss: QWord;
    fs_base: QWord;
    gs_base: QWord;
    ds: QWord;
    es: QWord;
    fs: QWord;
    gs: QWord;
  end;
var
  KernelRegs: user_regs_struct;
{$ENDIF}
{$IFDEF CPUI386}
type
  user_regs_struct = record
    ebx: Cardinal;
    ecx: Cardinal;
    edx: Cardinal;
    esi: Cardinal;
    edi: Cardinal;
    ebp: Cardinal;
    eax: Cardinal;
    xds: Cardinal;
    xes: Cardinal;
    xfs: Cardinal;
    xgs: Cardinal;
    orig_eax: Cardinal;
    eip: Cardinal;
    xcs: Cardinal;
    eflags: Cardinal;
    esp: Cardinal;
    xss: Cardinal;
  end;
var
  KernelRegs: user_regs_struct;
{$ENDIF}
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  FillChar(KernelRegs, SizeOf(KernelRegs), 0);

  if ptrace(PTRACE_GETREGS, FPID, nil, @KernelRegs) = -1 then
  begin
    WriteLn('[ERROR] Failed to get registers: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  {$IFDEF CPUX86_64}
  Regs.RAX := KernelRegs.rax;
  Regs.RBX := KernelRegs.rbx;
  Regs.RCX := KernelRegs.rcx;
  Regs.RDX := KernelRegs.rdx;
  Regs.RSI := KernelRegs.rsi;
  Regs.RDI := KernelRegs.rdi;
  Regs.RBP := KernelRegs.rbp;
  Regs.RSP := KernelRegs.rsp;
  Regs.R8 := KernelRegs.r8;
  Regs.R9 := KernelRegs.r9;
  Regs.R10 := KernelRegs.r10;
  Regs.R11 := KernelRegs.r11;
  Regs.R12 := KernelRegs.r12;
  Regs.R13 := KernelRegs.r13;
  Regs.R14 := KernelRegs.r14;
  Regs.R15 := KernelRegs.r15;
  Regs.RIP := KernelRegs.rip;
  Regs.RFLAGS := KernelRegs.eflags;
  {$ENDIF}

  {$IFDEF CPUI386}
  Regs.EAX := KernelRegs.eax;
  Regs.EBX := KernelRegs.ebx;
  Regs.ECX := KernelRegs.ecx;
  Regs.EDX := KernelRegs.edx;
  Regs.ESI := KernelRegs.esi;
  Regs.EDI := KernelRegs.edi;
  Regs.EBP := KernelRegs.ebp;
  Regs.ESP := KernelRegs.esp;
  Regs.EIP := KernelRegs.eip;
  Regs.EFLAGS := KernelRegs.eflags;
  {$ENDIF}

  Result := True;
end;

function TLinuxPtraceAdapter.SetRegisters(const Regs: TRegisters): Boolean;
{$IFDEF CPUX86_64}
type
  user_regs_struct = record
    r15: QWord;
    r14: QWord;
    r13: QWord;
    r12: QWord;
    rbp: QWord;
    rbx: QWord;
    r11: QWord;
    r10: QWord;
    r9: QWord;
    r8: QWord;
    rax: QWord;
    rcx: QWord;
    rdx: QWord;
    rsi: QWord;
    rdi: QWord;
    orig_rax: QWord;
    rip: QWord;
    cs: QWord;
    eflags: QWord;
    rsp: QWord;
    ss: QWord;
    fs_base: QWord;
    gs_base: QWord;
    ds: QWord;
    es: QWord;
    fs: QWord;
    gs: QWord;
  end;
var
  KernelRegs: user_regs_struct;
{$ENDIF}
{$IFDEF CPUI386}
type
  user_regs_struct = record
    ebx: Cardinal;
    ecx: Cardinal;
    edx: Cardinal;
    esi: Cardinal;
    edi: Cardinal;
    ebp: Cardinal;
    eax: Cardinal;
    xds: Cardinal;
    xes: Cardinal;
    xfs: Cardinal;
    xgs: Cardinal;
    orig_eax: Cardinal;
    eip: Cardinal;
    xcs: Cardinal;
    eflags: Cardinal;
    esp: Cardinal;
    xss: Cardinal;
  end;
var
  KernelRegs: user_regs_struct;
{$ENDIF}
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  // First get current registers
  FillChar(KernelRegs, SizeOf(KernelRegs), 0);

  if ptrace(PTRACE_GETREGS, FPID, nil, @KernelRegs) = -1 then
  begin
    WriteLn('[ERROR] Failed to get current registers: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Update with new values
  {$IFDEF CPUX86_64}
  KernelRegs.rax := Regs.RAX;
  KernelRegs.rbx := Regs.RBX;
  KernelRegs.rcx := Regs.RCX;
  KernelRegs.rdx := Regs.RDX;
  KernelRegs.rsi := Regs.RSI;
  KernelRegs.rdi := Regs.RDI;
  KernelRegs.rbp := Regs.RBP;
  KernelRegs.rsp := Regs.RSP;
  KernelRegs.r8 := Regs.R8;
  KernelRegs.r9 := Regs.R9;
  KernelRegs.r10 := Regs.R10;
  KernelRegs.r11 := Regs.R11;
  KernelRegs.r12 := Regs.R12;
  KernelRegs.r13 := Regs.R13;
  KernelRegs.r14 := Regs.R14;
  KernelRegs.r15 := Regs.R15;
  KernelRegs.rip := Regs.RIP;
  KernelRegs.eflags := Regs.RFLAGS;
  {$ENDIF}

  {$IFDEF CPUI386}
  KernelRegs.eax := Regs.EAX;
  KernelRegs.ebx := Regs.EBX;
  KernelRegs.ecx := Regs.ECX;
  KernelRegs.edx := Regs.EDX;
  KernelRegs.esi := Regs.ESI;
  KernelRegs.edi := Regs.EDI;
  KernelRegs.ebp := Regs.EBP;
  KernelRegs.esp := Regs.ESP;
  KernelRegs.eip := Regs.EIP;
  KernelRegs.eflags := Regs.EFLAGS;
  {$ENDIF}

  // Set the registers
  if ptrace(PTRACE_SETREGS, FPID, nil, @KernelRegs) = -1 then
  begin
    WriteLn('[ERROR] Failed to set registers: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  Result := True;
end;

{ Breakpoint management helpers }

function TLinuxPtraceAdapter.HandleBreakpointHit: Boolean;
var
  Regs: TRegisters;
  BreakpointAddr: QWord;
  Idx: Integer;
  Status: cInt;
begin
  Result := False;

  // Get current registers to find RIP
  if not GetRegisters(Regs) then
  begin
    WriteLn('[ERROR] Failed to get registers after breakpoint');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  // RIP points to the byte AFTER the INT3, so subtract 1
  BreakpointAddr := Regs.RIP - 1;
  {$ENDIF}
  {$IFDEF CPUI386}
  BreakpointAddr := Regs.EIP - 1;
  {$ENDIF}

  // Store the breakpoint address for StepLine to use
  FLastBreakpointAddr := BreakpointAddr;

  // Find the breakpoint at this address
  Idx := FindBreakpoint(BreakpointAddr);
  if Idx < 0 then
  begin
    WriteLn('[WARN] Breakpoint hit at unknown address: 0x', IntToHex(BreakpointAddr, 16));
    Exit(True);  // Still return success
  end;

  WriteLn('[INFO] Hit breakpoint at 0x', IntToHex(BreakpointAddr, 16));

  // Step 1: Back up RIP to point to the original instruction
  {$IFDEF CPUX86_64}
  Regs.RIP := BreakpointAddr;
  {$ENDIF}
  {$IFDEF CPUI386}
  Regs.EIP := BreakpointAddr;
  {$ENDIF}

  if not SetRegisters(Regs) then
  begin
    WriteLn('[ERROR] Failed to restore instruction pointer');
    Exit;
  end;

  // Step 2: Restore the original instruction (remove INT3)
  if ptrace(PTRACE_POKEDATA, FPID, Pointer(PtrUInt(BreakpointAddr)),
            Pointer(FBreakpoints[Idx].OriginalData)) = -1 then
  begin
    WriteLn('[ERROR] Failed to restore original instruction');
    Exit;
  end;

  // Step 3: Single-step over the original instruction
  if ptrace(PTRACE_SINGLESTEP, FPID, nil, nil) = -1 then
  begin
    WriteLn('[ERROR] Failed to single-step over restored instruction');
    Exit;
  end;

  // Wait for single-step to complete
  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to wait for single-step');
    Exit;
  end;

  // Step 4: Re-insert the breakpoint (put INT3 back)
  // Create modified data with INT3
  if ptrace(PTRACE_PEEKDATA, FPID, Pointer(PtrUInt(BreakpointAddr)), nil) = -1 then
  begin
    WriteLn('[ERROR] Failed to read memory for breakpoint re-insertion');
    Exit;
  end;

  // Write INT3 back
  if ptrace(PTRACE_POKEDATA, FPID, Pointer(PtrUInt(BreakpointAddr)),
            Pointer(FBreakpoints[Idx].OriginalData and $FFFFFFFFFFFFFF00 or $CC)) = -1 then
  begin
    WriteLn('[ERROR] Failed to re-insert breakpoint');
    Exit;
  end;

  Result := True;
end;

function TLinuxPtraceAdapter.FindBreakpoint(Address: QWord): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FBreakpoints) do
  begin
    if FBreakpoints[I].Address = Address then
      Exit(I);
  end;
end;

function TLinuxPtraceAdapter.GetOriginalData(Address: QWord): cLong;
var
  Idx: Integer;
begin
  Result := 0;
  Idx := FindBreakpoint(Address);
  if Idx >= 0 then
    Result := FBreakpoints[Idx].OriginalData;
end;

function TLinuxPtraceAdapter.SetBreakpoint(Address: QWord): Boolean;
var
  Data: cLong;
  ModifiedData: cLong;
  Trap: Byte;
  Idx: Integer;
  BpInfo: TBreakpointInfo;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  // Check if breakpoint already exists
  Idx := FindBreakpoint(Address);
  if Idx >= 0 then
  begin
    if FBreakpoints[Idx].Active then
    begin
      WriteLn('[WARN] Breakpoint already set at $', IntToHex(Address, 16));
      Exit(True);
    end
    else
    begin
      // Reactivate existing breakpoint - write INT3 back to memory
      Trap := $CC;
      ModifiedData := FBreakpoints[Idx].OriginalData;
      Move(Trap, ModifiedData, 1);

      if ptrace(PTRACE_POKEDATA, FPID, Pointer(PtrUInt(Address)), Pointer(ModifiedData)) = -1 then
      begin
        WriteLn('[ERROR] Failed to reactivate breakpoint: ', SysErrorMessage(fpgeterrno));
        Exit(False);
      end;

      FBreakpoints[Idx].Active := True;
      WriteLn('[INFO] Reactivated breakpoint at $', IntToHex(Address, 16));
      Exit(True);
    end;
  end;

  // Read current instruction
  Data := ptrace(PTRACE_PEEKDATA, FPID, Pointer(PtrUInt(Address)), nil);
  if (Data = -1) and (fpgeterrno <> 0) then
  begin
    WriteLn('[ERROR] Failed to read memory for breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Save original instruction
  BpInfo.Address := Address;
  BpInfo.OriginalData := Data;
  BpInfo.Active := True;

  // Create modified data with INT3 (0xCC on x86/x86_64)
  ModifiedData := Data;
  Trap := $CC;
  Move(Trap, ModifiedData, 1);

  // Write breakpoint
  if ptrace(PTRACE_POKEDATA, FPID, Pointer(PtrUInt(Address)), Pointer(ModifiedData)) = -1 then
  begin
    WriteLn('[ERROR] Failed to set breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Store breakpoint info
  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := BpInfo;

  WriteLn('[INFO] Breakpoint set at $', IntToHex(Address, 16));
  Result := True;
end;

function TLinuxPtraceAdapter.RemoveBreakpoint(Address: QWord): Boolean;
var
  Idx: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  // Find breakpoint
  Idx := FindBreakpoint(Address);
  if Idx < 0 then
  begin
    WriteLn('[ERROR] No breakpoint found at $', IntToHex(Address, 16));
    Exit;
  end;

  if not FBreakpoints[Idx].Active then
  begin
    WriteLn('[WARN] Breakpoint at $', IntToHex(Address, 16), ' already removed');
    Exit(True);
  end;

  // Restore original instruction
  if ptrace(PTRACE_POKEDATA, FPID, Pointer(PtrUInt(Address)),
            Pointer(FBreakpoints[Idx].OriginalData)) = -1 then
  begin
    WriteLn('[ERROR] Failed to remove breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Mark as inactive (keep in list for potential reactivation)
  FBreakpoints[Idx].Active := False;

  WriteLn('[INFO] Breakpoint removed from $', IntToHex(Address, 16));
  Result := True;
end;

function TLinuxPtraceAdapter.GetCurrentAddress: QWord;
var
  Regs: TRegisters;
begin
  Result := 0;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  if not GetRegisters(Regs) then
    Exit;

  {$IFDEF CPUX86_64}
  Result := Regs.RIP;
  {$ENDIF}
  {$IFDEF CPUI386}
  Result := Regs.EIP;
  {$ENDIF}
end;

function TLinuxPtraceAdapter.GetFrameBasePointer: QWord;
var
  Regs: TRegisters;
begin
  Result := 0;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  if not GetRegisters(Regs) then
    Exit;

  {$IFDEF CPUX86_64}
  Result := Regs.RBP;
  {$ENDIF}
  {$IFDEF CPUI386}
  Result := Regs.EBP;
  {$ENDIF}
end;

function TLinuxPtraceAdapter.GetLastBreakpointAddress: QWord;
begin
  Result := FLastBreakpointAddr;
end;

function TLinuxPtraceAdapter.SetCommandLineArgs(const Args: array of String): Boolean;
var
  I: Integer;
begin
  { Store the command-line arguments }
  SetLength(FCommandLineArgs, Length(Args));
  for I := 0 to High(Args) do
    FCommandLineArgs[I] := Args[I];

  if Length(Args) > 0 then
    WriteLn('[INFO] Set command-line arguments: ', String.Join(' ', Args));

  Result := True;
end;

end.
