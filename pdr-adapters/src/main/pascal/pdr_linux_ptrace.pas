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
  { Linux ptrace implementation of IProcessController }
  TLinuxPtraceAdapter = class(TInterfacedObject, IProcessController)
  private
    FPID: Integer;
    FAttached: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { IProcessController implementation }
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

{ External ptrace function }
function ptrace(request: cInt; pid: TPid; addr: Pointer; data: Pointer): cLong; cdecl; external 'c' name 'ptrace';

{ TLinuxPtraceAdapter }

constructor TLinuxPtraceAdapter.Create;
begin
  inherited Create;
  FPID := -1;
  FAttached := False;
end;

destructor TLinuxPtraceAdapter.Destroy;
begin
  if FAttached then
    Detach;
  inherited Destroy;
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
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[WARN] Not attached to any process');
    Exit(True);
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

  Result := True;
end;

function TLinuxPtraceAdapter.Step: Boolean;
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

  Result := True;
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

function TLinuxPtraceAdapter.SetBreakpoint(Address: QWord): Boolean;
var
  Data: cLong;
  Trap: Byte;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  // Read current instruction
  Data := ptrace(PTRACE_PEEKDATA, FPID, Pointer(PtrUInt(Address)), nil);
  if (Data = -1) and (fpgeterrno <> 0) then
  begin
    WriteLn('[ERROR] Failed to read memory for breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  // Replace first byte with INT3 (0xCC on x86/x86_64)
  Trap := $CC;
  Move(Trap, Data, 1);

  // Write back
  if ptrace(PTRACE_POKEDATA, FPID, Pointer(PtrUInt(Address)), Pointer(Data)) = -1 then
  begin
    WriteLn('[ERROR] Failed to set breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  WriteLn('[INFO] Breakpoint set at $', IntToHex(Address, 16));
  Result := True;
end;

function TLinuxPtraceAdapter.RemoveBreakpoint(Address: QWord): Boolean;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  // TODO: Implement breakpoint removal (need to save original instruction)
  WriteLn('[WARN] Breakpoint removal not yet implemented');
  Result := True;
end;

end.
