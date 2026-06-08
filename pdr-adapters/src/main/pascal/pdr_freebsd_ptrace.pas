{
  PDR Debugger - FreeBSD Ptrace Adapter

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Platform-specific process control implementation for FreeBSD using ptrace.

  NOTE: This implementation is currently UNTESTED. It has been written based
  on FreeBSD kernel documentation and header files. Issues will be addressed
  once Blaise supports FreeBSD as a compilation target.
}
unit pdr_freebsd_ptrace;

{$mode objfpc}{$H+}

interface

{$IFDEF FREEBSD}

uses
  SysUtils, BaseUnix, Unix, pdr_ports;

type
  TBreakpointInfo = record
    Address: QWord;
    OriginalData: cLong;
    Active: Boolean;
  end;

  TWatchSlotInfo = record
    Address: QWord;
    Size: Byte;
    Active: Boolean;
  end;

  TFreeBSDPtraceAdapter = class(TInterfacedObject, IProcessController)
  private
    FPID: Integer;
    FAttached: Boolean;
    FBreakpoints: array of TBreakpointInfo;
    FLastBreakpointAddr: QWord;
    FLastBreakpointRBP: QWord;
    FCommandLineArgs: array of String;
    FWatchSlots: array[0..3] of TWatchSlotInfo;
    FLastFiredWatchpoint: Integer;
    FPendingSignal: Integer;

    function IsStopSignal(Sig: Integer): Boolean;
    function SignalName(Sig: Integer): String;
    function FindBreakpoint(Address: QWord): Integer;
    function HandleBreakpointHit: Boolean;
    function ReadDebugRegister(RegIndex: Integer): QWord;
    function WriteDebugRegister(RegIndex: Integer; Value: QWord): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

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
    function GetLastBreakpointAddress: QWord;
    function GetLastBreakpointRBP: QWord;
    function SetCommandLineArgs(const Args: array of String): Boolean;
    function SetWatchpoint(Address: QWord; Size: Byte;
      WatchType: TWatchpointType): Integer;
    function ClearWatchpoint(Slot: Integer): Boolean;
    function GetFiredWatchpoint: Integer;
    function InjectCall(MethodAddr, SelfPtr: QWord;
      ManagedReturn: Boolean; out RetValue: QWord): Boolean;
    function SendInterrupt: Boolean;
    function GetLoadBase(const BinaryPath: String): QWord;

    property PID: Integer read FPID;
    property IsAttached: Boolean read FAttached;
  end;

{$ENDIF}

implementation

{$IFDEF FREEBSD}

const
  { FreeBSD ptrace request codes (from sys/ptrace.h) }
  PT_TRACE_ME   = 0;
  PT_READ_I     = 1;
  PT_READ_D     = 2;
  PT_WRITE_I    = 4;
  PT_WRITE_D    = 5;
  PT_CONTINUE   = 7;
  PT_KILL       = 8;
  PT_STEP       = 9;
  PT_ATTACH     = 10;
  PT_DETACH     = 11;
  PT_IO         = 12;
  PT_GETREGS    = 33;
  PT_SETREGS    = 34;
  PT_GETDBREGS  = 37;
  PT_SETDBREGS  = 38;

  { Signal numbers (FreeBSD — same as POSIX) }
  SIGHUP    = 1;
  SIGINT    = 2;
  SIGQUIT   = 3;
  SIGILL    = 4;
  SIGTRAP   = 5;
  SIGABRT   = 6;
  SIGBUS    = 10;
  SIGFPE    = 8;
  SIGKILL   = 9;
  SIGSEGV   = 11;
  SIGPIPE   = 13;
  SIGALRM   = 14;
  SIGTERM   = 15;
  SIGSTOP   = 17;
  SIGTSTP   = 18;

type
  { FreeBSD register structure for x86_64 (from machine/reg.h) }
  {$IFDEF CPUX86_64}
  TFreeBSDRegs = packed record
    r_r15: QWord;
    r_r14: QWord;
    r_r13: QWord;
    r_r12: QWord;
    r_r11: QWord;
    r_r10: QWord;
    r_r9: QWord;
    r_r8: QWord;
    r_rdi: QWord;
    r_rsi: QWord;
    r_rbp: QWord;
    r_rbx: QWord;
    r_rdx: QWord;
    r_rcx: QWord;
    r_rax: QWord;
    r_trapno: Cardinal;
    r_fs: Word;
    r_gs: Word;
    r_err: Cardinal;
    r_es: Word;
    r_ds: Word;
    r_rip: QWord;
    r_cs: QWord;
    r_rflags: QWord;
    r_rsp: QWord;
    r_ss: QWord;
  end;

  TFreeBSDDBregs = packed record
    dr: array[0..15] of QWord;
  end;
  {$ENDIF}
  {$IFDEF CPUI386}
  TFreeBSDRegs = packed record
    r_fs: Cardinal;
    r_es: Cardinal;
    r_ds: Cardinal;
    r_edi: Cardinal;
    r_esi: Cardinal;
    r_ebp: Cardinal;
    r_isp: Cardinal;
    r_ebx: Cardinal;
    r_edx: Cardinal;
    r_ecx: Cardinal;
    r_eax: Cardinal;
    r_trapno: Cardinal;
    r_err: Cardinal;
    r_eip: Cardinal;
    r_cs: Cardinal;
    r_eflags: Cardinal;
    r_esp: Cardinal;
    r_ss: Cardinal;
  end;

  TFreeBSDDBregs = packed record
    dr: array[0..7] of Cardinal;
  end;
  {$ENDIF}

function ptrace(request: cInt; pid: TPid; addr: Pointer; data: cInt): cLong;
  cdecl; external 'c' name 'ptrace';

function c_setpgid(pid: TPid; pgid: TPid): cInt;
  cdecl; external 'c' name 'setpgid';

var
  gWaitingPID: TPid = -1;
  gUserInterrupted: Boolean = False;

procedure HandleSIGINT(Sig: cInt); cdecl;
begin
  if gWaitingPID > 0 then
    FpKill(gWaitingPID, SIGSTOP);
  gUserInterrupted := True;
end;

{ TFreeBSDPtraceAdapter }

constructor TFreeBSDPtraceAdapter.Create;
var
  I: Integer;
  SigAct, OldAct: SigActionRec;
begin
  inherited Create;
  FPID := -1;
  FAttached := False;
  FLastBreakpointAddr := 0;
  FLastFiredWatchpoint := -1;
  FPendingSignal := 0;
  for I := 0 to 3 do
    FWatchSlots[I].Active := False;

  FillChar(SigAct, SizeOf(SigAct), 0);
  SigAct.sa_handler := SigActionHandler(@HandleSIGINT);
  SigAct.sa_flags := SA_RESTART;
  FpSigAction(SIGINT, @SigAct, @OldAct);
end;

destructor TFreeBSDPtraceAdapter.Destroy;
begin
  if FAttached then
    Detach;
  inherited Destroy;
end;

function TFreeBSDPtraceAdapter.IsStopSignal(Sig: Integer): Boolean;
begin
  case Sig of
    SIGSEGV, SIGFPE, SIGILL, SIGBUS, SIGABRT:
      Result := True;
  else
    Result := False;
  end;
end;

function TFreeBSDPtraceAdapter.SignalName(Sig: Integer): String;
begin
  case Sig of
    SIGHUP:   Result := 'SIGHUP';
    SIGINT:   Result := 'SIGINT';
    SIGQUIT:  Result := 'SIGQUIT';
    SIGILL:   Result := 'SIGILL';
    SIGTRAP:  Result := 'SIGTRAP';
    SIGABRT:  Result := 'SIGABRT';
    SIGBUS:   Result := 'SIGBUS';
    SIGFPE:   Result := 'SIGFPE';
    SIGKILL:  Result := 'SIGKILL';
    SIGSEGV:  Result := 'SIGSEGV';
    SIGPIPE:  Result := 'SIGPIPE';
    SIGALRM:  Result := 'SIGALRM';
    SIGTERM:  Result := 'SIGTERM';
    SIGSTOP:  Result := 'SIGSTOP';
    SIGTSTP:  Result := 'SIGTSTP';
  else
    Result := 'SIG' + IntToStr(Sig);
  end;
end;

function TFreeBSDPtraceAdapter.Launch(const BinaryPath: String): Boolean;
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

  if gVerbose then
    WriteLn('[INFO] Launching program: ', BinaryPath);

  ChildPID := FpFork;

  if ChildPID = -1 then
  begin
    WriteLn('[ERROR] Failed to fork: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if ChildPID = 0 then
  begin
    c_setpgid(0, 0);

    { FreeBSD uses PT_TRACE_ME; addr and data are ignored }
    if ptrace(PT_TRACE_ME, 0, nil, 0) = -1 then
    begin
      WriteLn('[ERROR] Child: Failed to enable tracing');
      fpExit(1);
    end;

    SetLength(Args, Length(FCommandLineArgs) + 2);
    Args[0] := PChar(BinaryPath);
    for I := 0 to High(FCommandLineArgs) do
      Args[I + 1] := PChar(FCommandLineArgs[I]);
    Args[Length(Args) - 1] := nil;

    FpExecV(PChar(BinaryPath), @Args[0]);

    WriteLn('[ERROR] Child: Failed to exec: ', SysErrorMessage(fpgeterrno));
    fpExit(1);
  end
  else
  begin
    if gVerbose then
      WriteLn('[INFO] Child process created with PID ', ChildPID);

    gWaitingPID := ChildPID;
    gUserInterrupted := False;
    if FpWaitPid(ChildPID, @Status, 0) = -1 then
    begin
      gWaitingPID := -1;
      WriteLn('[ERROR] Failed to wait for child process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;
    gWaitingPID := -1;

    if not WIFSTOPPED(Status) then
    begin
      WriteLn('[ERROR] Child process did not stop as expected');
      Exit;
    end;

    FPID := ChildPID;
    FAttached := True;

    if gVerbose then
    begin
      WriteLn('[INFO] Child process stopped at entry point');
      WriteLn('[INFO] Debugger has control (process is paused)');
    end;
    Result := True;
  end;
end;

function TFreeBSDPtraceAdapter.Attach(PID: Integer): Boolean;
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

  if ptrace(PT_ATTACH, FPID, nil, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to attach to process ', PID, ': ', SysErrorMessage(fpgeterrno));
    FPID := -1;
    Exit;
  end;

  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
    ptrace(PT_DETACH, FPID, nil, 0);
    FPID := -1;
    Exit;
  end;

  FAttached := True;
  WriteLn('[INFO] Successfully attached to PID ', FPID);
  Result := True;
end;

function TFreeBSDPtraceAdapter.Detach: Boolean;
var
  I: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[WARN] Not attached to any process');
    Exit(True);
  end;

  if Length(FBreakpoints) > 0 then
  begin
    if gVerbose then
      WriteLn('[INFO] Removing all breakpoints before detach');
    for I := 0 to High(FBreakpoints) do
    begin
      if FBreakpoints[I].Active then
        RemoveBreakpoint(FBreakpoints[I].Address);
    end;
    SetLength(FBreakpoints, 0);
  end;

  { FreeBSD PT_DETACH: addr=1 (resume at current PC), data=signal to deliver }
  if ptrace(PT_DETACH, FPID, Pointer(1), 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to detach from process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if gVerbose then
    WriteLn('[INFO] Detached from PID ', FPID);
  FAttached := False;
  FPID := -1;
  Result := True;
end;

function TFreeBSDPtraceAdapter.Continue: Boolean;
var
  Status: cInt;
  WaitResult: TPid;
  DR6: QWord;
  Regs: TRegisters;
  WatchSlot: Integer;
  Sig: Integer;
  DataSignal: cInt;
begin
  Result := False;
  FLastFiredWatchpoint := -1;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  if FPendingSignal <> 0 then
  begin
    DataSignal := FPendingSignal;
    if gVerbose then
      WriteLn('[DEBUG] Delivering pending signal ', SignalName(FPendingSignal),
              ' to process');
    FPendingSignal := 0;
  end
  else
    DataSignal := 0;

  while True do
  begin
    { FreeBSD PT_CONTINUE: addr=1 means resume at current PC, data=signal }
    if ptrace(PT_CONTINUE, FPID, Pointer(1), DataSignal) = -1 then
    begin
      WriteLn('[ERROR] Failed to continue process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    DataSignal := 0;

    gWaitingPID := FPID;
    gUserInterrupted := False;
    WaitResult := FpWaitPid(FPID, @Status, 0);
    gWaitingPID := -1;
    if WaitResult = -1 then
    begin
      WriteLn('[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    if WIFSTOPPED(Status) then
    begin
      Sig := WSTOPSIG(Status);

      if Sig = SIGTRAP then
      begin
        DR6 := ReadDebugRegister(6);
        WriteDebugRegister(6, 0);

        if (DR6 and $F) <> 0 then
        begin
          WatchSlot := -1;
          if (DR6 and 1) <> 0 then WatchSlot := 0
          else if (DR6 and 2) <> 0 then WatchSlot := 1
          else if (DR6 and 4) <> 0 then WatchSlot := 2
          else if (DR6 and 8) <> 0 then WatchSlot := 3;

          FLastFiredWatchpoint := WatchSlot;

          if GetRegisters(Regs) then
          begin
            {$IFDEF CPUX86_64}
            FLastBreakpointAddr := Regs.RIP;
            FLastBreakpointRBP := Regs.RBP;
            {$ENDIF}
            {$IFDEF CPUI386}
            FLastBreakpointAddr := Regs.EIP;
            FLastBreakpointRBP := Regs.EBP;
            {$ENDIF}
          end;

          if gVerbose then
            WriteLn('[DEBUG] Hardware watchpoint hit: slot ', WatchSlot);
        end
        else
        begin
          if not HandleBreakpointHit then
          begin
            WriteLn('[ERROR] Failed to handle breakpoint');
            Exit;
          end;
        end;
        Result := True;
        Exit;
      end
      else if Sig = SIGSTOP then
      begin
        gUserInterrupted := False;
        WriteLn('');
        WriteLn('[INFO] Interrupted');
        Result := True;
        Exit;
      end
      else if IsStopSignal(Sig) then
      begin
        WriteLn('[INFO] Process received ', SignalName(Sig), ' (signal ', Sig, ')');
        FPendingSignal := Sig;
        Result := True;
        Exit;
      end
      else
      begin
        if gVerbose then
          WriteLn('[DEBUG] Passing through ', SignalName(Sig), ' to process');
        DataSignal := Sig;
      end;
    end
    else if WIFEXITED(Status) then
    begin
      WriteLn('[INFO] Process exited with code ', WEXITSTATUS(Status));
      FAttached := False;
      FPID := -1;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end
    else if WIFSIGNALED(Status) then
    begin
      WriteLn('[INFO] Process terminated by signal ',
              SignalName(WTERMSIG(Status)), ' (', WTERMSIG(Status), ')');
      FAttached := False;
      FPID := -1;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end;
  end;
end;

function TFreeBSDPtraceAdapter.Step: Boolean;
var
  Status: cInt;
  WaitResult: TPid;
  Sig: Integer;
  DataSignal: cInt;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  DataSignal := 0;

  while True do
  begin
    { FreeBSD PT_STEP: addr=1 means resume at current PC, data=signal }
    if ptrace(PT_STEP, FPID, Pointer(1), DataSignal) = -1 then
    begin
      WriteLn('[ERROR] Failed to single step: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    DataSignal := 0;

    gWaitingPID := FPID;
    gUserInterrupted := False;
    WaitResult := FpWaitPid(FPID, @Status, 0);
    gWaitingPID := -1;
    if WaitResult = -1 then
    begin
      WriteLn('[ERROR] Failed to wait for step: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    if WIFSTOPPED(Status) then
    begin
      Sig := WSTOPSIG(Status);

      if Sig = SIGTRAP then
      begin
        if gVerbose then WriteLn('[INFO] Step complete');
        Result := True;
        Exit;
      end
      else if Sig = SIGSTOP then
      begin
        gUserInterrupted := False;
        WriteLn('');
        WriteLn('[INFO] Interrupted');
        Result := True;
        Exit;
      end
      else if IsStopSignal(Sig) then
      begin
        WriteLn('[INFO] Process received ', SignalName(Sig),
                ' (signal ', Sig, ') during step');
        FPendingSignal := Sig;
        Result := True;
        Exit;
      end
      else
      begin
        if gVerbose then
          WriteLn('[DEBUG] Passing through ', SignalName(Sig), ' during step');
        DataSignal := Sig;
      end;
    end
    else if WIFEXITED(Status) then
    begin
      WriteLn('[INFO] Process exited during step with code ', WEXITSTATUS(Status));
      FAttached := False;
      FPID := -1;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end
    else if WIFSIGNALED(Status) then
    begin
      WriteLn('[INFO] Process terminated during step by signal ',
              SignalName(WTERMSIG(Status)), ' (', WTERMSIG(Status), ')');
      FAttached := False;
      FPID := -1;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end;
  end;
end;

function TFreeBSDPtraceAdapter.ReadMemory(Address: QWord; Size: Cardinal;
  out Buffer): Boolean;
var
  P: PByte;
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

  while Offset < Size do
  begin
    Data := ptrace(PT_READ_D, FPID, Pointer(PtrUInt(Address + Offset)), 0);

    if (Data = -1) and (fpgeterrno <> 0) then
    begin
      WriteLn('[ERROR] Failed to read memory at $', IntToHex(Address + Offset, 16),
              ': ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    BytesToCopy := SizeOf(cLong);
    if Offset + BytesToCopy > Size then
      BytesToCopy := Size - Offset;

    Move(Data, P[Offset], BytesToCopy);
    Inc(Offset, SizeOf(cLong));
  end;

  Result := True;
end;

function TFreeBSDPtraceAdapter.WriteMemory(Address: QWord; Size: Cardinal;
  const Buffer): Boolean;
var
  P: PByte;
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

  while Offset < Size do
  begin
    if Offset + SizeOf(cLong) > Size then
    begin
      Data := ptrace(PT_READ_D, FPID, Pointer(PtrUInt(Address + Offset)), 0);
      if (Data = -1) and (fpgeterrno <> 0) then
      begin
        WriteLn('[ERROR] Failed to read memory for partial write: ',
                SysErrorMessage(fpgeterrno));
        Exit;
      end;
      Move(P[Offset], Data, Size - Offset);
    end
    else
      Move(P[Offset], Data, SizeOf(cLong));

    if ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(Address + Offset)), cInt(Data)) = -1 then
    begin
      WriteLn('[ERROR] Failed to write memory at $', IntToHex(Address + Offset, 16),
              ': ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    Inc(Offset, SizeOf(cLong));
  end;

  Result := True;
end;

function TFreeBSDPtraceAdapter.GetRegisters(out Regs: TRegisters): Boolean;
var
  FreeBSDRegs: TFreeBSDRegs;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  FillChar(FreeBSDRegs, SizeOf(FreeBSDRegs), 0);

  { FreeBSD PT_GETREGS: addr is ignored, data points to struct reg }
  if ptrace(PT_GETREGS, FPID, @FreeBSDRegs, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to get registers: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  {$IFDEF CPUX86_64}
  Regs.RAX := FreeBSDRegs.r_rax;
  Regs.RBX := FreeBSDRegs.r_rbx;
  Regs.RCX := FreeBSDRegs.r_rcx;
  Regs.RDX := FreeBSDRegs.r_rdx;
  Regs.RSI := FreeBSDRegs.r_rsi;
  Regs.RDI := FreeBSDRegs.r_rdi;
  Regs.RBP := FreeBSDRegs.r_rbp;
  Regs.RSP := FreeBSDRegs.r_rsp;
  Regs.R8 := FreeBSDRegs.r_r8;
  Regs.R9 := FreeBSDRegs.r_r9;
  Regs.R10 := FreeBSDRegs.r_r10;
  Regs.R11 := FreeBSDRegs.r_r11;
  Regs.R12 := FreeBSDRegs.r_r12;
  Regs.R13 := FreeBSDRegs.r_r13;
  Regs.R14 := FreeBSDRegs.r_r14;
  Regs.R15 := FreeBSDRegs.r_r15;
  Regs.RIP := FreeBSDRegs.r_rip;
  Regs.RFLAGS := FreeBSDRegs.r_rflags;
  {$ENDIF}

  {$IFDEF CPUI386}
  Regs.EAX := FreeBSDRegs.r_eax;
  Regs.EBX := FreeBSDRegs.r_ebx;
  Regs.ECX := FreeBSDRegs.r_ecx;
  Regs.EDX := FreeBSDRegs.r_edx;
  Regs.ESI := FreeBSDRegs.r_esi;
  Regs.EDI := FreeBSDRegs.r_edi;
  Regs.EBP := FreeBSDRegs.r_ebp;
  Regs.ESP := FreeBSDRegs.r_esp;
  Regs.EIP := FreeBSDRegs.r_eip;
  Regs.EFLAGS := FreeBSDRegs.r_eflags;
  {$ENDIF}

  Result := True;
end;

function TFreeBSDPtraceAdapter.SetRegisters(const Regs: TRegisters): Boolean;
var
  FreeBSDRegs: TFreeBSDRegs;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  FillChar(FreeBSDRegs, SizeOf(FreeBSDRegs), 0);

  { Get current registers first to preserve segment registers etc. }
  if ptrace(PT_GETREGS, FPID, @FreeBSDRegs, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to get current registers: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  {$IFDEF CPUX86_64}
  FreeBSDRegs.r_rax := Regs.RAX;
  FreeBSDRegs.r_rbx := Regs.RBX;
  FreeBSDRegs.r_rcx := Regs.RCX;
  FreeBSDRegs.r_rdx := Regs.RDX;
  FreeBSDRegs.r_rsi := Regs.RSI;
  FreeBSDRegs.r_rdi := Regs.RDI;
  FreeBSDRegs.r_rbp := Regs.RBP;
  FreeBSDRegs.r_rsp := Regs.RSP;
  FreeBSDRegs.r_r8 := Regs.R8;
  FreeBSDRegs.r_r9 := Regs.R9;
  FreeBSDRegs.r_r10 := Regs.R10;
  FreeBSDRegs.r_r11 := Regs.R11;
  FreeBSDRegs.r_r12 := Regs.R12;
  FreeBSDRegs.r_r13 := Regs.R13;
  FreeBSDRegs.r_r14 := Regs.R14;
  FreeBSDRegs.r_r15 := Regs.R15;
  FreeBSDRegs.r_rip := Regs.RIP;
  FreeBSDRegs.r_rflags := Regs.RFLAGS;
  {$ENDIF}

  {$IFDEF CPUI386}
  FreeBSDRegs.r_eax := Regs.EAX;
  FreeBSDRegs.r_ebx := Regs.EBX;
  FreeBSDRegs.r_ecx := Regs.ECX;
  FreeBSDRegs.r_edx := Regs.EDX;
  FreeBSDRegs.r_esi := Regs.ESI;
  FreeBSDRegs.r_edi := Regs.EDI;
  FreeBSDRegs.r_ebp := Regs.EBP;
  FreeBSDRegs.r_esp := Regs.ESP;
  FreeBSDRegs.r_eip := Regs.EIP;
  FreeBSDRegs.r_eflags := Regs.EFLAGS;
  {$ENDIF}

  if ptrace(PT_SETREGS, FPID, @FreeBSDRegs, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to set registers: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  Result := True;
end;

{ Breakpoint management }

function TFreeBSDPtraceAdapter.HandleBreakpointHit: Boolean;
var
  Regs: TRegisters;
  BreakpointAddr: QWord;
  Idx: Integer;
  Status: cInt;
  OrigData, NewData: cLong;
begin
  Result := False;

  if not GetRegisters(Regs) then
  begin
    WriteLn('[ERROR] Failed to get registers after breakpoint');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  BreakpointAddr := Regs.RIP - 1;
  {$ENDIF}
  {$IFDEF CPUI386}
  BreakpointAddr := Regs.EIP - 1;
  {$ENDIF}

  FLastBreakpointAddr := BreakpointAddr;
  {$IFDEF CPUX86_64}
  FLastBreakpointRBP := Regs.RBP;
  {$ENDIF}
  {$IFDEF CPUI386}
  FLastBreakpointRBP := Regs.EBP;
  {$ENDIF}

  Idx := FindBreakpoint(BreakpointAddr);
  if Idx < 0 then
  begin
    WriteLn('[WARN] Breakpoint hit at unknown address: 0x', IntToHex(BreakpointAddr, 16));
    Exit(True);
  end;

  if gVerbose then
    WriteLn('[INFO] Hit breakpoint at 0x', IntToHex(BreakpointAddr, 16));

  { Back up instruction pointer }
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

  { Restore original instruction }
  if ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(BreakpointAddr)),
            cInt(FBreakpoints[Idx].OriginalData)) = -1 then
  begin
    WriteLn('[ERROR] Failed to restore original instruction');
    Exit;
  end;

  { Single-step over the original instruction }
  if ptrace(PT_STEP, FPID, Pointer(1), 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to single-step over restored instruction');
    Exit;
  end;

  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to wait for single-step');
    Exit;
  end;

  WriteDebugRegister(6, 0);

  { Re-insert the breakpoint }
  OrigData := ptrace(PT_READ_D, FPID, Pointer(PtrUInt(BreakpointAddr)), 0);
  NewData := OrigData and cLong($FFFFFFFFFFFFFF00) or $CC;
  if ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(BreakpointAddr)), cInt(NewData)) = -1 then
  begin
    WriteLn('[ERROR] Failed to re-insert breakpoint');
    Exit;
  end;

  Result := True;
end;

function TFreeBSDPtraceAdapter.FindBreakpoint(Address: QWord): Integer;
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

function TFreeBSDPtraceAdapter.SetBreakpoint(Address: QWord): Boolean;
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
      Trap := $CC;
      ModifiedData := FBreakpoints[Idx].OriginalData;
      Move(Trap, ModifiedData, 1);

      if ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(Address)), cInt(ModifiedData)) = -1 then
      begin
        WriteLn('[ERROR] Failed to reactivate breakpoint: ', SysErrorMessage(fpgeterrno));
        Exit(False);
      end;

      FBreakpoints[Idx].Active := True;
      if gVerbose then
        WriteLn('[INFO] Reactivated breakpoint at $', IntToHex(Address, 16));
      Exit(True);
    end;
  end;

  Data := ptrace(PT_READ_D, FPID, Pointer(PtrUInt(Address)), 0);
  if (Data = -1) and (fpgeterrno <> 0) then
  begin
    WriteLn('[ERROR] Failed to read memory for breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  BpInfo.Address := Address;
  BpInfo.OriginalData := Data;
  BpInfo.Active := True;

  ModifiedData := Data;
  Trap := $CC;
  Move(Trap, ModifiedData, 1);

  if ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(Address)), cInt(ModifiedData)) = -1 then
  begin
    WriteLn('[ERROR] Failed to set breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := BpInfo;

  if gVerbose then
    WriteLn('[INFO] Breakpoint set at $', IntToHex(Address, 16));
  Result := True;
end;

function TFreeBSDPtraceAdapter.RemoveBreakpoint(Address: QWord): Boolean;
var
  Idx: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

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

  if ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(Address)),
            cInt(FBreakpoints[Idx].OriginalData)) = -1 then
  begin
    WriteLn('[ERROR] Failed to remove breakpoint: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  FBreakpoints[Idx].Active := False;

  if gVerbose then
    WriteLn('[INFO] Breakpoint removed from $', IntToHex(Address, 16));
  Result := True;
end;

function TFreeBSDPtraceAdapter.GetCurrentAddress: QWord;
var
  Regs: TRegisters;
begin
  Result := 0;
  if not FAttached then Exit;
  if not GetRegisters(Regs) then Exit;
  {$IFDEF CPUX86_64}
  Result := Regs.RIP;
  {$ENDIF}
  {$IFDEF CPUI386}
  Result := Regs.EIP;
  {$ENDIF}
end;

function TFreeBSDPtraceAdapter.GetFrameBasePointer: QWord;
var
  Regs: TRegisters;
begin
  Result := 0;
  if not FAttached then Exit;
  if not GetRegisters(Regs) then Exit;
  {$IFDEF CPUX86_64}
  Result := Regs.RBP;
  {$ENDIF}
  {$IFDEF CPUI386}
  Result := Regs.EBP;
  {$ENDIF}
end;

function TFreeBSDPtraceAdapter.GetLastBreakpointAddress: QWord;
begin
  Result := FLastBreakpointAddr;
end;

function TFreeBSDPtraceAdapter.GetLastBreakpointRBP: QWord;
begin
  Result := FLastBreakpointRBP;
end;

function TFreeBSDPtraceAdapter.SetCommandLineArgs(const Args: array of String): Boolean;
var
  I: Integer;
begin
  SetLength(FCommandLineArgs, Length(Args));
  for I := 0 to High(Args) do
    FCommandLineArgs[I] := Args[I];

  if Length(Args) > 0 then
    WriteLn('[INFO] Set command-line arguments: ', String.Join(' ', Args));

  Result := True;
end;

{ Debug register access via PT_GETDBREGS/PT_SETDBREGS }

function TFreeBSDPtraceAdapter.ReadDebugRegister(RegIndex: Integer): QWord;
var
  DBregs: TFreeBSDDBregs;
begin
  Result := 0;
  FillChar(DBregs, SizeOf(DBregs), 0);
  if ptrace(PT_GETDBREGS, FPID, @DBregs, 0) = -1 then
    Exit;
  {$IFDEF CPUX86_64}
  Result := DBregs.dr[RegIndex];
  {$ENDIF}
  {$IFDEF CPUI386}
  Result := DBregs.dr[RegIndex];
  {$ENDIF}
end;

function TFreeBSDPtraceAdapter.WriteDebugRegister(RegIndex: Integer;
  Value: QWord): Boolean;
var
  DBregs: TFreeBSDDBregs;
begin
  Result := False;
  FillChar(DBregs, SizeOf(DBregs), 0);
  if ptrace(PT_GETDBREGS, FPID, @DBregs, 0) = -1 then
    Exit;
  {$IFDEF CPUX86_64}
  DBregs.dr[RegIndex] := Value;
  {$ENDIF}
  {$IFDEF CPUI386}
  DBregs.dr[RegIndex] := Cardinal(Value);
  {$ENDIF}
  Result := ptrace(PT_SETDBREGS, FPID, @DBregs, 0) <> -1;
end;

function TFreeBSDPtraceAdapter.SetWatchpoint(Address: QWord; Size: Byte;
  WatchType: TWatchpointType): Integer;
var
  Slot: Integer;
  DR7, EnableBit, CondBits, LenBits: QWord;
  LenCode, CondCode: QWord;
begin
  Result := -1;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  Slot := -1;
  for Result := 0 to 3 do
    if not FWatchSlots[Result].Active then
    begin
      Slot := Result;
      Break;
    end;

  if Slot = -1 then
  begin
    WriteLn('[ERROR] All 4 hardware watchpoint slots are in use');
    Result := -1;
    Exit;
  end;

  case Size of
    1: LenCode := 0;
    2: LenCode := 1;
    4: LenCode := 3;
    8: LenCode := 2;
  else
    WriteLn('[ERROR] Unsupported watchpoint size: ', Size, ' (must be 1, 2, 4, or 8)');
    Result := -1;
    Exit;
  end;

  case WatchType of
    wtWrite:     CondCode := 1;
    wtReadWrite: CondCode := 3;
  end;

  if not WriteDebugRegister(Slot, Address) then
  begin
    WriteLn('[ERROR] Failed to write watchpoint address to DR', Slot);
    Result := -1;
    Exit;
  end;

  DR7 := ReadDebugRegister(7);

  EnableBit := QWord(1) shl (2 * Slot);
  CondBits := CondCode shl (16 + 4 * Slot);
  LenBits := LenCode shl (18 + 4 * Slot);

  DR7 := DR7 or EnableBit or CondBits or LenBits;

  if not WriteDebugRegister(7, DR7) then
  begin
    WriteLn('[ERROR] Failed to write DR7 control register');
    Result := -1;
    Exit;
  end;

  FWatchSlots[Slot].Address := Address;
  FWatchSlots[Slot].Size := Size;
  FWatchSlots[Slot].Active := True;

  if gVerbose then
    WriteLn('[DEBUG] Watchpoint set in slot ', Slot,
            ' at 0x', IntToHex(Address, 16), ' size=', Size);

  Result := Slot;
end;

function TFreeBSDPtraceAdapter.ClearWatchpoint(Slot: Integer): Boolean;
var
  DR7, Mask: QWord;
begin
  Result := False;

  if (Slot < 0) or (Slot > 3) then
  begin
    WriteLn('[ERROR] Invalid watchpoint slot: ', Slot);
    Exit;
  end;

  if not FWatchSlots[Slot].Active then
  begin
    if gVerbose then WriteLn('[INFO] Watchpoint slot ', Slot, ' already inactive');
    Result := True;
    Exit;
  end;

  DR7 := ReadDebugRegister(7);
  Mask := not (QWord($3) shl (2 * Slot) or QWord($F) shl (16 + 4 * Slot));
  DR7 := DR7 and Mask;

  if not WriteDebugRegister(7, DR7) then
  begin
    WriteLn('[ERROR] Failed to clear DR7 for slot ', Slot);
    Exit;
  end;

  WriteDebugRegister(Slot, 0);

  FWatchSlots[Slot].Active := False;

  if gVerbose then
    WriteLn('[DEBUG] Watchpoint slot ', Slot, ' cleared');

  Result := True;
end;

function TFreeBSDPtraceAdapter.GetFiredWatchpoint: Integer;
begin
  Result := FLastFiredWatchpoint;
end;

function TFreeBSDPtraceAdapter.InjectCall(MethodAddr, SelfPtr: QWord;
  ManagedReturn: Boolean; out RetValue: QWord): Boolean;
{$IFDEF CPUX86_64}
const
  MAX_ITERATIONS = 1000;
var
  SavedRegs, NewRegs, RetRegs: TRegisters;
  SentinelAddr: QWord;
  OrigData: cLong;
  NewRSP, ResultBufAddr: QWord;
  ReturnAddr: QWord;
  ZeroBuf: QWord;
  Status: cInt;
  Iterations: Integer;
  StoppedAddr: QWord;
  BpIdx: Integer;
begin
  Result := False;
  RetValue := 0;

  if not FAttached then
  begin
    WriteLn('[ERROR] InjectCall: not attached to any process');
    Exit;
  end;

  if not GetRegisters(SavedRegs) then
  begin
    WriteLn('[ERROR] InjectCall: failed to save registers');
    Exit;
  end;

  SentinelAddr := SavedRegs.RIP;

  OrigData := ptrace(PT_READ_D, FPID, Pointer(PtrUInt(SentinelAddr)), 0);
  if (OrigData = -1) and (fpgeterrno <> 0) then
  begin
    WriteLn('[ERROR] InjectCall: failed to read memory at sentinel');
    Exit;
  end;

  if ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(SentinelAddr)),
            cInt(OrigData and cLong($FFFFFFFFFFFFFF00) or $CC)) = -1 then
  begin
    WriteLn('[ERROR] InjectCall: failed to write INT3 sentinel');
    Exit;
  end;

  NewRSP := (SavedRegs.RSP - 128 - 8) and QWord($FFFFFFFFFFFFFFF0);

  ResultBufAddr := 0;
  if ManagedReturn then
  begin
    ResultBufAddr := NewRSP - 8;
    NewRSP := (NewRSP - 16) and QWord($FFFFFFFFFFFFFFF0);
    ZeroBuf := 0;
    if not WriteMemory(ResultBufAddr, 8, ZeroBuf) then
    begin
      WriteLn('[ERROR] InjectCall: failed to zero result buffer');
      ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(SentinelAddr)), cInt(OrigData));
      Exit;
    end;
  end;

  ReturnAddr := SentinelAddr;
  if not WriteMemory(NewRSP, 8, ReturnAddr) then
  begin
    WriteLn('[ERROR] InjectCall: failed to write return address');
    ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(SentinelAddr)), cInt(OrigData));
    Exit;
  end;

  NewRegs := SavedRegs;
  NewRegs.RIP := MethodAddr;
  NewRegs.RSP := NewRSP;
  NewRegs.RDI := SelfPtr;
  if ManagedReturn then
    NewRegs.RSI := ResultBufAddr;

  if not SetRegisters(NewRegs) then
  begin
    WriteLn('[ERROR] InjectCall: failed to set registers');
    ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(SentinelAddr)), cInt(OrigData));
    Exit;
  end;

  if gVerbose then
    WriteLn('[DEBUG] InjectCall: calling $', IntToHex(MethodAddr, 16),
            ' Self=$', IntToHex(SelfPtr, 16),
            ' RSP=$', IntToHex(NewRSP, 16));

  Iterations := 0;
  repeat
    if ptrace(PT_CONTINUE, FPID, Pointer(1), 0) = -1 then
    begin
      WriteLn('[ERROR] InjectCall: failed to continue');
      Break;
    end;

    if FpWaitPid(FPID, @Status, 0) = -1 then
    begin
      WriteLn('[ERROR] InjectCall: failed to wait');
      Break;
    end;

    if WIFEXITED(Status) or WIFSIGNALED(Status) then
    begin
      WriteLn('[ERROR] InjectCall: process terminated during injection');
      FAttached := False;
      FPID := -1;
      Exit;
    end;

    if not WIFSTOPPED(Status) then
      Break;

    if not GetRegisters(RetRegs) then
      Break;
    StoppedAddr := RetRegs.RIP - 1;

    if StoppedAddr = SentinelAddr then
    begin
      RetValue := RetRegs.RAX;
      if ManagedReturn then
        RetValue := ResultBufAddr;
      Result := True;
      Break;
    end;

    BpIdx := FindBreakpoint(StoppedAddr);
    if BpIdx >= 0 then
    begin
      if gVerbose then
        WriteLn('[DEBUG] InjectCall: hit user breakpoint at $',
                IntToHex(StoppedAddr, 16), ' — stepping past');
      RetRegs.RIP := StoppedAddr;
      SetRegisters(RetRegs);
      ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(StoppedAddr)),
             cInt(FBreakpoints[BpIdx].OriginalData));
      ptrace(PT_STEP, FPID, Pointer(1), 0);
      FpWaitPid(FPID, @Status, 0);
      WriteDebugRegister(6, 0);
      ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(StoppedAddr)),
             cInt(FBreakpoints[BpIdx].OriginalData and cLong($FFFFFFFFFFFFFF00) or $CC));
    end
    else
    begin
      if gVerbose then
        WriteLn('[DEBUG] InjectCall: unexpected stop at $',
                IntToHex(StoppedAddr, 16), ' signal=', WSTOPSIG(Status));
    end;

    Inc(Iterations);
  until Iterations >= MAX_ITERATIONS;

  if Iterations >= MAX_ITERATIONS then
    WriteLn('[ERROR] InjectCall: timeout — iteration limit reached');

  ptrace(PT_WRITE_D, FPID, Pointer(PtrUInt(SentinelAddr)), cInt(OrigData));
  SetRegisters(SavedRegs);

  if gVerbose and Result then
    WriteLn('[DEBUG] InjectCall: completed, RetValue=$', IntToHex(RetValue, 16));
end;
{$ELSE}
begin
  Result := False;
  RetValue := 0;
  WriteLn('[ERROR] InjectCall: only supported on x86_64');
end;
{$ENDIF}

function TFreeBSDPtraceAdapter.SendInterrupt: Boolean;
begin
  Result := False;
  if (FPID <= 0) or (not FAttached) then
    Exit;
  FpKill(FPID, SIGSTOP);
  Result := True;
end;

function TFreeBSDPtraceAdapter.GetLoadBase(const BinaryPath: String): QWord;
var
  MapsFile: TextFile;
  Line, BinaryBaseName: String;
  SpacePos: Integer;
  AddrStr: String;
begin
  Result := 0;

  if FPID <= 0 then
    Exit;

  BinaryBaseName := ExtractFileName(BinaryPath);

  { FreeBSD procfs: /proc/<pid>/map (NOTE: untested — format differs from Linux) }
  {$PUSH}{$I-}
  AssignFile(MapsFile, '/proc/' + IntToStr(FPID) + '/map');
  Reset(MapsFile);
  if IOResult <> 0 then
    Exit;

  while not EOF(MapsFile) do
  begin
    ReadLn(MapsFile, Line);
    if IOResult <> 0 then
      Break;

    if (Pos(BinaryBaseName, Line) > 0) and (Pos('r-x', Line) > 0) then
    begin
      SpacePos := Pos(' ', Line);
      if SpacePos > 1 then
      begin
        AddrStr := Copy(Line, 3, SpacePos - 3);
        Result := StrToQWord('$' + AddrStr);
        Break;
      end;
    end;
  end;

  CloseFile(MapsFile);
  {$POP}

  if gVerbose and (Result <> 0) then
    WriteLn('[DEBUG] Load base from /proc/map: $', IntToHex(Result, 16));
end;

{$ENDIF} { FREEBSD }

end.
