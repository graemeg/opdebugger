{
  PDR Debugger - macOS Mach Exception Ports Adapter

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Platform-specific process control implementation for macOS using Mach
  exception ports, mach_vm_read/mach_vm_write, and thread_get_state/
  thread_set_state.

  PREREQUISITES: The debugger binary must be code-signed with the
  com.apple.security.get-task-allow entitlement, otherwise task_for_pid
  will fail. On macOS 10.14+ the binary must also have the
  com.apple.security.cs.debugger entitlement or run as root.

  NOTE: This implementation is currently UNTESTED. It has been written based
  on Apple's Mach kernel documentation and XNU source headers. Issues will
  be addressed once Blaise supports macOS as a compilation target.
}
unit pdr_macos_mach;

{$mode objfpc}{$H+}

interface

{$IFDEF DARWIN}

uses
  SysUtils, BaseUnix, Unix, pdr_ports;

type
  TBreakpointInfo = record
    Address: QWord;
    OriginalByte: Byte;
    Active: Boolean;
  end;

  TWatchSlotInfo = record
    Address: QWord;
    Size: Byte;
    Active: Boolean;
  end;

  TMacOSMachAdapter = class(TInterfacedObject, IProcessController)
  private
    FPID: Integer;
    FAttached: Boolean;
    FTaskPort: Cardinal;
    FThreadPort: Cardinal;
    FExceptionPort: Cardinal;
    FBreakpoints: array of TBreakpointInfo;
    FLastBreakpointAddr: QWord;
    FLastBreakpointRBP: QWord;
    FCommandLineArgs: array of String;
    FWatchSlots: array[0..3] of TWatchSlotInfo;
    FLastFiredWatchpoint: Integer;
    FPendingSignal: Integer;

    function FindBreakpoint(Address: QWord): Integer;
    function HandleBreakpointHit: Boolean;
    function GetMainThread: Boolean;
    function SetupExceptionPort: Boolean;
    function WaitForException(out ExcType: Integer): Boolean;
    function ReplyToException(ExcType: Integer): Boolean;
    {$IFDEF CPUX86_64}
    function ReadDebugState(out DR0, DR1, DR2, DR3, DR6, DR7: QWord): Boolean;
    function WriteDebugState(DR0, DR1, DR2, DR3, DR6, DR7: QWord): Boolean;
    {$ENDIF}
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

{$IFDEF DARWIN}

const
  { Mach kernel return codes }
  KERN_SUCCESS           = 0;
  KERN_INVALID_ARGUMENT  = 4;

  { Mach exception types }
  EXC_BAD_ACCESS         = 1;
  EXC_BAD_INSTRUCTION    = 2;
  EXC_ARITHMETIC         = 3;
  EXC_BREAKPOINT         = 6;
  EXC_SOFTWARE           = 7;

  { Exception masks }
  EXC_MASK_BREAKPOINT    = 1 shl EXC_BREAKPOINT;

  { Exception behavior }
  EXCEPTION_DEFAULT      = 1;

  { Thread state flavors (x86_64) }
  {$IFDEF CPUX86_64}
  x86_THREAD_STATE64     = 4;
  x86_THREAD_STATE64_COUNT = 42;
  x86_DEBUG_STATE64      = 11;
  x86_DEBUG_STATE64_COUNT = 16;
  {$ENDIF}
  {$IFDEF CPUI386}
  x86_THREAD_STATE32     = 1;
  x86_THREAD_STATE32_COUNT = 16;
  x86_DEBUG_STATE32      = 10;
  x86_DEBUG_STATE32_COUNT = 8;
  {$ENDIF}

  { POSIX signal numbers (macOS) }
  SIGHUP    = 1;
  SIGINT    = 2;
  SIGQUIT   = 3;
  SIGILL    = 4;
  SIGTRAP   = 5;
  SIGABRT   = 6;
  SIGFPE    = 8;
  SIGKILL   = 9;
  SIGBUS    = 10;
  SIGSEGV   = 11;
  SIGPIPE   = 13;
  SIGALRM   = 14;
  SIGTERM   = 15;
  SIGSTOP   = 17;
  SIGTSTP   = 18;
  SIGCONT   = 19;

  { ptrace requests (macOS still exposes ptrace for process control) }
  PT_TRACE_ME   = 0;
  PT_CONTINUE   = 7;
  PT_KILL       = 8;
  PT_STEP       = 9;
  PT_ATTACH     = 10;
  PT_DETACH     = 11;
  PT_ATTACHEXC  = 14;

type
  mach_port_t = Cardinal;
  kern_return_t = Integer;
  mach_vm_address_t = QWord;
  mach_vm_size_t = QWord;
  vm_offset_t = PtrUInt;
  mach_msg_type_number_t = Cardinal;
  thread_state_flavor_t = Integer;
  thread_act_t = mach_port_t;
  task_t = mach_port_t;
  exception_mask_t = Cardinal;
  exception_behavior_t = Integer;
  thread_state_t = Pointer;

  {$IFDEF CPUX86_64}
  x86_thread_state64_t = packed record
    rax: QWord;
    rbx: QWord;
    rcx: QWord;
    rdx: QWord;
    rdi: QWord;
    rsi: QWord;
    rbp: QWord;
    rsp: QWord;
    r8: QWord;
    r9: QWord;
    r10: QWord;
    r11: QWord;
    r12: QWord;
    r13: QWord;
    r14: QWord;
    r15: QWord;
    rip: QWord;
    rflags: QWord;
    cs: QWord;
    fs: QWord;
    gs: QWord;
  end;

  x86_debug_state64_t = packed record
    dr0: QWord;
    dr1: QWord;
    dr2: QWord;
    dr3: QWord;
    dr4: QWord;
    dr5: QWord;
    dr6: QWord;
    dr7: QWord;
  end;
  {$ENDIF}

  {$IFDEF CPUI386}
  x86_thread_state32_t = packed record
    eax: Cardinal;
    ebx: Cardinal;
    ecx: Cardinal;
    edx: Cardinal;
    edi: Cardinal;
    esi: Cardinal;
    ebp: Cardinal;
    esp: Cardinal;
    ss: Cardinal;
    eflags: Cardinal;
    eip: Cardinal;
    cs: Cardinal;
    ds: Cardinal;
    es: Cardinal;
    fs: Cardinal;
    gs: Cardinal;
  end;

  x86_debug_state32_t = packed record
    dr0: Cardinal;
    dr1: Cardinal;
    dr2: Cardinal;
    dr3: Cardinal;
    dr4: Cardinal;
    dr5: Cardinal;
    dr6: Cardinal;
    dr7: Cardinal;
  end;
  {$ENDIF}

  { Mach exception message structures }
  mach_msg_header_t = packed record
    msgh_bits: Cardinal;
    msgh_size: Cardinal;
    msgh_remote_port: mach_port_t;
    msgh_local_port: mach_port_t;
    msgh_voucher_port: mach_port_t;
    msgh_id: Integer;
  end;

{ External Mach kernel functions }
function task_for_pid(target_tport: mach_port_t; pid: Integer;
  out t: task_t): kern_return_t; cdecl; external 'c';
function mach_task_self: mach_port_t; cdecl; external 'c';

function mach_vm_read_overwrite(target_task: task_t; address: mach_vm_address_t;
  size: mach_vm_size_t; data: mach_vm_address_t;
  out outsize: mach_vm_size_t): kern_return_t; cdecl; external 'c';
function mach_vm_write(target_task: task_t; address: mach_vm_address_t;
  data: vm_offset_t; dataCnt: mach_msg_type_number_t): kern_return_t;
  cdecl; external 'c';
function mach_vm_protect(target_task: task_t; address: mach_vm_address_t;
  size: mach_vm_size_t; set_maximum: Integer;
  new_protection: Integer): kern_return_t; cdecl; external 'c';

function task_threads(target_task: task_t; out act_list: Pointer;
  out act_listCnt: mach_msg_type_number_t): kern_return_t; cdecl; external 'c';

function thread_get_state(target_act: thread_act_t; flavor: thread_state_flavor_t;
  old_state: thread_state_t;
  var old_stateCnt: mach_msg_type_number_t): kern_return_t; cdecl; external 'c';
function thread_set_state(target_act: thread_act_t; flavor: thread_state_flavor_t;
  new_state: thread_state_t;
  new_stateCnt: mach_msg_type_number_t): kern_return_t; cdecl; external 'c';
function thread_suspend(target_act: thread_act_t): kern_return_t;
  cdecl; external 'c';
function thread_resume(target_act: thread_act_t): kern_return_t;
  cdecl; external 'c';

function task_set_exception_ports(task: task_t; exception_mask: exception_mask_t;
  new_port: mach_port_t; behavior: exception_behavior_t;
  new_flavor: thread_state_flavor_t): kern_return_t; cdecl; external 'c';
function mach_port_allocate(task: task_t; right: Integer;
  out name: mach_port_t): kern_return_t; cdecl; external 'c';
function mach_port_insert_right(task: task_t; name: mach_port_t;
  poly: mach_port_t; polyPoly: Integer): kern_return_t; cdecl; external 'c';

function mach_msg(msg: Pointer; option: Integer; send_size: Cardinal;
  rcv_size: Cardinal; rcv_name: mach_port_t; timeout: Cardinal;
  notify: mach_port_t): kern_return_t; cdecl; external 'c';

function ptrace(request: cInt; pid: Integer; addr: Pointer;
  data: cInt): cInt; cdecl; external 'c' name 'ptrace';

function c_setpgid(pid: TPid; pgid: TPid): cInt;
  cdecl; external 'c' name 'setpgid';

const
  MACH_PORT_RIGHT_RECEIVE = 1;
  MACH_MSG_TYPE_MAKE_SEND = 20;
  MACH_RCV_MSG = 2;
  MACH_SEND_MSG = 1;

  { Single-step trap flag for x86 }
  TRAP_FLAG = $00000100;

var
  gWaitingPID: TPid = -1;
  gUserInterrupted: Boolean = False;

procedure HandleSIGINT(Sig: cInt); cdecl;
begin
  if gWaitingPID > 0 then
    FpKill(gWaitingPID, SIGSTOP);
  gUserInterrupted := True;
end;

{ TMacOSMachAdapter }

constructor TMacOSMachAdapter.Create;
var
  I: Integer;
  SigAct, OldAct: SigActionRec;
begin
  inherited Create;
  FPID := -1;
  FAttached := False;
  FTaskPort := 0;
  FThreadPort := 0;
  FExceptionPort := 0;
  FLastBreakpointAddr := 0;
  FLastBreakpointRBP := 0;
  FLastFiredWatchpoint := -1;
  FPendingSignal := 0;
  for I := 0 to 3 do
    FWatchSlots[I].Active := False;

  FillChar(SigAct, SizeOf(SigAct), 0);
  SigAct.sa_handler := SigActionHandler(@HandleSIGINT);
  SigAct.sa_flags := SA_RESTART;
  FpSigAction(SIGINT, @SigAct, @OldAct);
end;

destructor TMacOSMachAdapter.Destroy;
begin
  if FAttached then
    Detach;
  inherited Destroy;
end;

function TMacOSMachAdapter.GetMainThread: Boolean;
var
  ThreadList: Pointer;
  ThreadCount: mach_msg_type_number_t;
  KR: kern_return_t;
begin
  Result := False;
  ThreadList := nil;
  ThreadCount := 0;

  KR := task_threads(FTaskPort, ThreadList, ThreadCount);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to enumerate threads (kern_return=', KR, ')');
    Exit;
  end;

  if ThreadCount = 0 then
  begin
    WriteLn('[ERROR] Process has no threads');
    Exit;
  end;

  FThreadPort := PMachPortT(ThreadList)^;
  Result := True;
end;

type
  PMachPortT = ^mach_port_t;

function TMacOSMachAdapter.SetupExceptionPort: Boolean;
var
  KR: kern_return_t;
begin
  Result := False;

  KR := mach_port_allocate(mach_task_self, MACH_PORT_RIGHT_RECEIVE, FExceptionPort);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to allocate exception port (kern_return=', KR, ')');
    Exit;
  end;

  KR := mach_port_insert_right(mach_task_self, FExceptionPort, FExceptionPort,
                               MACH_MSG_TYPE_MAKE_SEND);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to insert send right (kern_return=', KR, ')');
    Exit;
  end;

  KR := task_set_exception_ports(FTaskPort, EXC_MASK_BREAKPOINT,
    FExceptionPort, EXCEPTION_DEFAULT,
    {$IFDEF CPUX86_64}x86_THREAD_STATE64{$ELSE}x86_THREAD_STATE32{$ENDIF});
  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to set exception ports (kern_return=', KR, ')');
    Exit;
  end;

  Result := True;
end;

function TMacOSMachAdapter.WaitForException(out ExcType: Integer): Boolean;
var
  MsgBuf: array[0..1023] of Byte;
  Header: ^mach_msg_header_t;
  KR: kern_return_t;
begin
  Result := False;
  ExcType := 0;

  FillChar(MsgBuf, SizeOf(MsgBuf), 0);
  Header := @MsgBuf[0];

  KR := mach_msg(Header, MACH_RCV_MSG, 0, SizeOf(MsgBuf),
                 FExceptionPort, 0, 0);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to receive exception message (kern_return=', KR, ')');
    Exit;
  end;

  { The exception type is embedded in the message body; for EXC_BREAKPOINT
    the message ID is typically 2401 (32-bit) or 2405 (64-bit) }
  ExcType := EXC_BREAKPOINT;
  Result := True;
end;

function TMacOSMachAdapter.ReplyToException(ExcType: Integer): Boolean;
begin
  { In a full implementation, we would construct and send a mach_msg reply.
    For now, we use ptrace(PT_CONTINUE) which also resumes the task. }
  Result := True;
end;

function TMacOSMachAdapter.Launch(const BinaryPath: String): Boolean;
var
  ChildPID: TPid;
  Status: cInt;
  Args: array of PChar;
  I: Integer;
  KR: kern_return_t;
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

    { macOS: PT_TRACE_ME enables ptrace tracing and SIGSTOP at exec }
    if ptrace(PT_TRACE_ME, 0, nil, 0) <> 0 then
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

    { Obtain the Mach task port for memory access and thread state }
    KR := task_for_pid(mach_task_self, FPID, FTaskPort);
    if KR <> KERN_SUCCESS then
    begin
      WriteLn('[ERROR] task_for_pid failed (kern_return=', KR, ')');
      WriteLn('[ERROR] Ensure the binary is code-signed with ',
              'com.apple.security.get-task-allow entitlement');
      ptrace(PT_KILL, FPID, nil, 0);
      FPID := -1;
      Exit;
    end;

    if not GetMainThread then
    begin
      ptrace(PT_KILL, FPID, nil, 0);
      FPID := -1;
      Exit;
    end;

    FAttached := True;

    if gVerbose then
    begin
      WriteLn('[INFO] Child process stopped at entry point');
      WriteLn('[INFO] Mach task port: ', FTaskPort, ', thread: ', FThreadPort);
      WriteLn('[INFO] Debugger has control (process is paused)');
    end;
    Result := True;
  end;
end;

function TMacOSMachAdapter.Attach(PID: Integer): Boolean;
var
  Status: cInt;
  KR: kern_return_t;
begin
  Result := False;

  if FAttached then
  begin
    WriteLn('[ERROR] Already attached to PID ', FPID);
    Exit;
  end;

  FPID := PID;

  { Use PT_ATTACHEXC for exception-based debugging }
  if ptrace(PT_ATTACHEXC, FPID, nil, 0) <> 0 then
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

  KR := task_for_pid(mach_task_self, FPID, FTaskPort);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] task_for_pid failed (kern_return=', KR, ')');
    ptrace(PT_DETACH, FPID, nil, 0);
    FPID := -1;
    Exit;
  end;

  if not GetMainThread then
  begin
    ptrace(PT_DETACH, FPID, nil, 0);
    FPID := -1;
    Exit;
  end;

  FAttached := True;
  WriteLn('[INFO] Successfully attached to PID ', FPID);
  Result := True;
end;

function TMacOSMachAdapter.Detach: Boolean;
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

  if ptrace(PT_DETACH, FPID, Pointer(1), 0) <> 0 then
  begin
    WriteLn('[ERROR] Failed to detach from process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if gVerbose then
    WriteLn('[INFO] Detached from PID ', FPID);
  FAttached := False;
  FPID := -1;
  FTaskPort := 0;
  FThreadPort := 0;
  Result := True;
end;

function TMacOSMachAdapter.Continue: Boolean;
var
  Status: cInt;
  WaitResult: TPid;
  Sig: Integer;
  SignalToDeliver: cInt;
  {$IFDEF CPUX86_64}
  DR6: QWord;
  DR0, DR1, DR2, DR3, DR7: QWord;
  {$ENDIF}
  Regs: TRegisters;
  WatchSlot: Integer;
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
    SignalToDeliver := FPendingSignal;
    FPendingSignal := 0;
  end
  else
    SignalToDeliver := 0;

  while True do
  begin
    { macOS: PT_CONTINUE with addr=1 means resume at current PC }
    if ptrace(PT_CONTINUE, FPID, Pointer(1), SignalToDeliver) <> 0 then
    begin
      WriteLn('[ERROR] Failed to continue process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    SignalToDeliver := 0;

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
        {$IFDEF CPUX86_64}
        if ReadDebugState(DR0, DR1, DR2, DR3, DR6, DR7) and ((DR6 and $F) <> 0) then
        begin
          WatchSlot := -1;
          if (DR6 and 1) <> 0 then WatchSlot := 0
          else if (DR6 and 2) <> 0 then WatchSlot := 1
          else if (DR6 and 4) <> 0 then WatchSlot := 2
          else if (DR6 and 8) <> 0 then WatchSlot := 3;

          FLastFiredWatchpoint := WatchSlot;

          WriteDebugState(DR0, DR1, DR2, DR3, 0, DR7);

          if GetRegisters(Regs) then
          begin
            FLastBreakpointAddr := Regs.RIP;
            FLastBreakpointRBP := Regs.RBP;
          end;

          if gVerbose then
            WriteLn('[DEBUG] Hardware watchpoint hit: slot ', WatchSlot);

          Result := True;
          Exit;
        end;
        {$ENDIF}

        if not HandleBreakpointHit then
        begin
          WriteLn('[ERROR] Failed to handle breakpoint');
          Exit;
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
      else if (Sig = SIGSEGV) or (Sig = SIGFPE) or (Sig = SIGILL) or
              (Sig = SIGBUS) or (Sig = SIGABRT) then
      begin
        WriteLn('[INFO] Process received signal ', Sig);
        FPendingSignal := Sig;
        Result := True;
        Exit;
      end
      else
      begin
        if gVerbose then
          WriteLn('[DEBUG] Passing through signal ', Sig, ' to process');
        SignalToDeliver := Sig;
      end;
    end
    else if WIFEXITED(Status) then
    begin
      WriteLn('[INFO] Process exited with code ', WEXITSTATUS(Status));
      FAttached := False;
      FPID := -1;
      FTaskPort := 0;
      FThreadPort := 0;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end
    else if WIFSIGNALED(Status) then
    begin
      WriteLn('[INFO] Process terminated by signal ', WTERMSIG(Status));
      FAttached := False;
      FPID := -1;
      FTaskPort := 0;
      FThreadPort := 0;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end;
  end;
end;

function TMacOSMachAdapter.Step: Boolean;
var
  Status: cInt;
  WaitResult: TPid;
  Sig: Integer;
  SignalToDeliver: cInt;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  SignalToDeliver := 0;

  while True do
  begin
    if ptrace(PT_STEP, FPID, Pointer(1), SignalToDeliver) <> 0 then
    begin
      WriteLn('[ERROR] Failed to single step: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    SignalToDeliver := 0;

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
      else if (Sig = SIGSEGV) or (Sig = SIGFPE) or (Sig = SIGILL) or
              (Sig = SIGBUS) or (Sig = SIGABRT) then
      begin
        WriteLn('[INFO] Process received signal ', Sig, ' during step');
        FPendingSignal := Sig;
        Result := True;
        Exit;
      end
      else
      begin
        if gVerbose then
          WriteLn('[DEBUG] Passing through signal ', Sig, ' during step');
        SignalToDeliver := Sig;
      end;
    end
    else if WIFEXITED(Status) then
    begin
      WriteLn('[INFO] Process exited during step with code ', WEXITSTATUS(Status));
      FAttached := False;
      FPID := -1;
      FTaskPort := 0;
      FThreadPort := 0;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end
    else if WIFSIGNALED(Status) then
    begin
      WriteLn('[INFO] Process terminated during step by signal ', WTERMSIG(Status));
      FAttached := False;
      FPID := -1;
      FTaskPort := 0;
      FThreadPort := 0;
      FPendingSignal := 0;
      Result := True;
      Exit;
    end;
  end;
end;

function TMacOSMachAdapter.ReadMemory(Address: QWord; Size: Cardinal;
  out Buffer): Boolean;
var
  OutSize: mach_vm_size_t;
  KR: kern_return_t;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  KR := mach_vm_read_overwrite(FTaskPort, Address, Size,
    mach_vm_address_t(@Buffer), OutSize);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to read memory at $', IntToHex(Address, 16),
            ' (kern_return=', KR, ')');
    Exit;
  end;

  Result := True;
end;

function TMacOSMachAdapter.WriteMemory(Address: QWord; Size: Cardinal;
  const Buffer): Boolean;
var
  KR: kern_return_t;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  KR := mach_vm_write(FTaskPort, Address, vm_offset_t(@Buffer), Size);
  if KR <> KERN_SUCCESS then
  begin
    { Try making the page writable first (code pages are read-only) }
    mach_vm_protect(FTaskPort, Address and not QWord($FFF), $1000, 0,
                    3 { VM_PROT_READ or VM_PROT_WRITE });
    KR := mach_vm_write(FTaskPort, Address, vm_offset_t(@Buffer), Size);
    if KR <> KERN_SUCCESS then
    begin
      WriteLn('[ERROR] Failed to write memory at $', IntToHex(Address, 16),
              ' (kern_return=', KR, ')');
      Exit;
    end;
  end;

  Result := True;
end;

function TMacOSMachAdapter.GetRegisters(out Regs: TRegisters): Boolean;
var
  KR: kern_return_t;
  Count: mach_msg_type_number_t;
  {$IFDEF CPUX86_64}
  State: x86_thread_state64_t;
  {$ENDIF}
  {$IFDEF CPUI386}
  State: x86_thread_state32_t;
  {$ENDIF}
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  FillChar(State, SizeOf(State), 0);

  {$IFDEF CPUX86_64}
  Count := x86_THREAD_STATE64_COUNT;
  KR := thread_get_state(FThreadPort, x86_THREAD_STATE64, @State, Count);
  {$ENDIF}
  {$IFDEF CPUI386}
  Count := x86_THREAD_STATE32_COUNT;
  KR := thread_get_state(FThreadPort, x86_THREAD_STATE32, @State, Count);
  {$ENDIF}

  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to get thread state (kern_return=', KR, ')');
    Exit;
  end;

  {$IFDEF CPUX86_64}
  Regs.RAX := State.rax;
  Regs.RBX := State.rbx;
  Regs.RCX := State.rcx;
  Regs.RDX := State.rdx;
  Regs.RSI := State.rsi;
  Regs.RDI := State.rdi;
  Regs.RBP := State.rbp;
  Regs.RSP := State.rsp;
  Regs.R8 := State.r8;
  Regs.R9 := State.r9;
  Regs.R10 := State.r10;
  Regs.R11 := State.r11;
  Regs.R12 := State.r12;
  Regs.R13 := State.r13;
  Regs.R14 := State.r14;
  Regs.R15 := State.r15;
  Regs.RIP := State.rip;
  Regs.RFLAGS := State.rflags;
  {$ENDIF}

  {$IFDEF CPUI386}
  Regs.EAX := State.eax;
  Regs.EBX := State.ebx;
  Regs.ECX := State.ecx;
  Regs.EDX := State.edx;
  Regs.ESI := State.esi;
  Regs.EDI := State.edi;
  Regs.EBP := State.ebp;
  Regs.ESP := State.esp;
  Regs.EIP := State.eip;
  Regs.EFLAGS := State.eflags;
  {$ENDIF}

  Result := True;
end;

function TMacOSMachAdapter.SetRegisters(const Regs: TRegisters): Boolean;
var
  KR: kern_return_t;
  Count: mach_msg_type_number_t;
  {$IFDEF CPUX86_64}
  State: x86_thread_state64_t;
  {$ENDIF}
  {$IFDEF CPUI386}
  State: x86_thread_state32_t;
  {$ENDIF}
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  { Get current state first to preserve segment registers }
  FillChar(State, SizeOf(State), 0);
  {$IFDEF CPUX86_64}
  Count := x86_THREAD_STATE64_COUNT;
  thread_get_state(FThreadPort, x86_THREAD_STATE64, @State, Count);
  {$ENDIF}
  {$IFDEF CPUI386}
  Count := x86_THREAD_STATE32_COUNT;
  thread_get_state(FThreadPort, x86_THREAD_STATE32, @State, Count);
  {$ENDIF}

  {$IFDEF CPUX86_64}
  State.rax := Regs.RAX;
  State.rbx := Regs.RBX;
  State.rcx := Regs.RCX;
  State.rdx := Regs.RDX;
  State.rsi := Regs.RSI;
  State.rdi := Regs.RDI;
  State.rbp := Regs.RBP;
  State.rsp := Regs.RSP;
  State.r8 := Regs.R8;
  State.r9 := Regs.R9;
  State.r10 := Regs.R10;
  State.r11 := Regs.R11;
  State.r12 := Regs.R12;
  State.r13 := Regs.R13;
  State.r14 := Regs.R14;
  State.r15 := Regs.R15;
  State.rip := Regs.RIP;
  State.rflags := Regs.RFLAGS;

  Count := x86_THREAD_STATE64_COUNT;
  KR := thread_set_state(FThreadPort, x86_THREAD_STATE64, @State, Count);
  {$ENDIF}

  {$IFDEF CPUI386}
  State.eax := Regs.EAX;
  State.ebx := Regs.EBX;
  State.ecx := Regs.ECX;
  State.edx := Regs.EDX;
  State.esi := Regs.ESI;
  State.edi := Regs.EDI;
  State.ebp := Regs.EBP;
  State.esp := Regs.ESP;
  State.eip := Regs.EIP;
  State.eflags := Regs.EFLAGS;

  Count := x86_THREAD_STATE32_COUNT;
  KR := thread_set_state(FThreadPort, x86_THREAD_STATE32, @State, Count);
  {$ENDIF}

  if KR <> KERN_SUCCESS then
  begin
    WriteLn('[ERROR] Failed to set thread state (kern_return=', KR, ')');
    Exit;
  end;

  Result := True;
end;

{ Breakpoint management }

function TMacOSMachAdapter.HandleBreakpointHit: Boolean;
var
  Regs: TRegisters;
  BreakpointAddr: QWord;
  Idx: Integer;
  OrigByte, TrapByte: Byte;
  Status: cInt;
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

  { Restore original byte }
  OrigByte := FBreakpoints[Idx].OriginalByte;
  if not WriteMemory(BreakpointAddr, 1, OrigByte) then
  begin
    WriteLn('[ERROR] Failed to restore original instruction');
    Exit;
  end;

  { Single-step over the original instruction }
  if ptrace(PT_STEP, FPID, Pointer(1), 0) <> 0 then
  begin
    WriteLn('[ERROR] Failed to single-step over restored instruction');
    Exit;
  end;

  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn('[ERROR] Failed to wait for single-step');
    Exit;
  end;

  { Re-insert the breakpoint }
  TrapByte := $CC;
  if not WriteMemory(BreakpointAddr, 1, TrapByte) then
  begin
    WriteLn('[ERROR] Failed to re-insert breakpoint');
    Exit;
  end;

  Result := True;
end;

function TMacOSMachAdapter.FindBreakpoint(Address: QWord): Integer;
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

function TMacOSMachAdapter.SetBreakpoint(Address: QWord): Boolean;
var
  OrigByte, TrapByte: Byte;
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
      TrapByte := $CC;
      if not WriteMemory(Address, 1, TrapByte) then
      begin
        WriteLn('[ERROR] Failed to reactivate breakpoint');
        Exit(False);
      end;
      FBreakpoints[Idx].Active := True;
      if gVerbose then
        WriteLn('[INFO] Reactivated breakpoint at $', IntToHex(Address, 16));
      Exit(True);
    end;
  end;

  if not ReadMemory(Address, 1, OrigByte) then
  begin
    WriteLn('[ERROR] Failed to read memory for breakpoint');
    Exit;
  end;

  BpInfo.Address := Address;
  BpInfo.OriginalByte := OrigByte;
  BpInfo.Active := True;

  TrapByte := $CC;
  if not WriteMemory(Address, 1, TrapByte) then
  begin
    WriteLn('[ERROR] Failed to set breakpoint');
    Exit;
  end;

  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := BpInfo;

  if gVerbose then
    WriteLn('[INFO] Breakpoint set at $', IntToHex(Address, 16));
  Result := True;
end;

function TMacOSMachAdapter.RemoveBreakpoint(Address: QWord): Boolean;
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

  if not WriteMemory(Address, 1, FBreakpoints[Idx].OriginalByte) then
  begin
    WriteLn('[ERROR] Failed to remove breakpoint');
    Exit;
  end;

  FBreakpoints[Idx].Active := False;

  if gVerbose then
    WriteLn('[INFO] Breakpoint removed from $', IntToHex(Address, 16));
  Result := True;
end;

function TMacOSMachAdapter.GetCurrentAddress: QWord;
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

function TMacOSMachAdapter.GetFrameBasePointer: QWord;
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

function TMacOSMachAdapter.GetLastBreakpointAddress: QWord;
begin
  Result := FLastBreakpointAddr;
end;

function TMacOSMachAdapter.GetLastBreakpointRBP: QWord;
begin
  Result := FLastBreakpointRBP;
end;

function TMacOSMachAdapter.SetCommandLineArgs(const Args: array of String): Boolean;
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

{ Debug register access via thread_get_state/thread_set_state }

{$IFDEF CPUX86_64}
function TMacOSMachAdapter.ReadDebugState(out DR0, DR1, DR2, DR3, DR6, DR7: QWord): Boolean;
var
  State: x86_debug_state64_t;
  Count: mach_msg_type_number_t;
  KR: kern_return_t;
begin
  Result := False;
  FillChar(State, SizeOf(State), 0);
  Count := x86_DEBUG_STATE64_COUNT;
  KR := thread_get_state(FThreadPort, x86_DEBUG_STATE64, @State, Count);
  if KR <> KERN_SUCCESS then
    Exit;
  DR0 := State.dr0;
  DR1 := State.dr1;
  DR2 := State.dr2;
  DR3 := State.dr3;
  DR6 := State.dr6;
  DR7 := State.dr7;
  Result := True;
end;

function TMacOSMachAdapter.WriteDebugState(DR0, DR1, DR2, DR3, DR6, DR7: QWord): Boolean;
var
  State: x86_debug_state64_t;
  Count: mach_msg_type_number_t;
  KR: kern_return_t;
begin
  Result := False;
  FillChar(State, SizeOf(State), 0);
  State.dr0 := DR0;
  State.dr1 := DR1;
  State.dr2 := DR2;
  State.dr3 := DR3;
  State.dr6 := DR6;
  State.dr7 := DR7;
  Count := x86_DEBUG_STATE64_COUNT;
  KR := thread_set_state(FThreadPort, x86_DEBUG_STATE64, @State, Count);
  Result := (KR = KERN_SUCCESS);
end;
{$ENDIF}

function TMacOSMachAdapter.SetWatchpoint(Address: QWord; Size: Byte;
  WatchType: TWatchpointType): Integer;
{$IFDEF CPUX86_64}
var
  Slot: Integer;
  DR0, DR1, DR2, DR3, DR6, DR7: QWord;
  EnableBit, CondBits, LenBits: QWord;
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
    WriteLn('[ERROR] Unsupported watchpoint size: ', Size);
    Result := -1;
    Exit;
  end;

  case WatchType of
    wtWrite:     CondCode := 1;
    wtReadWrite: CondCode := 3;
  end;

  if not ReadDebugState(DR0, DR1, DR2, DR3, DR6, DR7) then
  begin
    WriteLn('[ERROR] Failed to read debug registers');
    Result := -1;
    Exit;
  end;

  case Slot of
    0: DR0 := Address;
    1: DR1 := Address;
    2: DR2 := Address;
    3: DR3 := Address;
  end;

  EnableBit := QWord(1) shl (2 * Slot);
  CondBits := CondCode shl (16 + 4 * Slot);
  LenBits := LenCode shl (18 + 4 * Slot);
  DR7 := DR7 or EnableBit or CondBits or LenBits;

  if not WriteDebugState(DR0, DR1, DR2, DR3, 0, DR7) then
  begin
    WriteLn('[ERROR] Failed to write debug registers');
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
{$ELSE}
begin
  Result := -1;
  WriteLn('[ERROR] Hardware watchpoints only supported on x86_64');
end;
{$ENDIF}

function TMacOSMachAdapter.ClearWatchpoint(Slot: Integer): Boolean;
{$IFDEF CPUX86_64}
var
  DR0, DR1, DR2, DR3, DR6, DR7: QWord;
  Mask: QWord;
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

  if not ReadDebugState(DR0, DR1, DR2, DR3, DR6, DR7) then
  begin
    WriteLn('[ERROR] Failed to read debug registers');
    Exit;
  end;

  case Slot of
    0: DR0 := 0;
    1: DR1 := 0;
    2: DR2 := 0;
    3: DR3 := 0;
  end;

  Mask := not (QWord($3) shl (2 * Slot) or QWord($F) shl (16 + 4 * Slot));
  DR7 := DR7 and Mask;

  if not WriteDebugState(DR0, DR1, DR2, DR3, 0, DR7) then
  begin
    WriteLn('[ERROR] Failed to write debug registers');
    Exit;
  end;

  FWatchSlots[Slot].Active := False;

  if gVerbose then
    WriteLn('[DEBUG] Watchpoint slot ', Slot, ' cleared');

  Result := True;
end;
{$ELSE}
begin
  Result := False;
  WriteLn('[ERROR] Hardware watchpoints only supported on x86_64');
end;
{$ENDIF}

function TMacOSMachAdapter.GetFiredWatchpoint: Integer;
begin
  Result := FLastFiredWatchpoint;
end;

function TMacOSMachAdapter.InjectCall(MethodAddr, SelfPtr: QWord;
  ManagedReturn: Boolean; out RetValue: QWord): Boolean;
{$IFDEF CPUX86_64}
const
  MAX_ITERATIONS = 1000;
var
  SavedRegs, NewRegs, RetRegs: TRegisters;
  SentinelAddr: QWord;
  OrigByte, TrapByte: Byte;
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

  if not ReadMemory(SentinelAddr, 1, OrigByte) then
  begin
    WriteLn('[ERROR] InjectCall: failed to read memory at sentinel');
    Exit;
  end;

  TrapByte := $CC;
  if not WriteMemory(SentinelAddr, 1, TrapByte) then
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
      WriteMemory(SentinelAddr, 1, OrigByte);
      Exit;
    end;
  end;

  ReturnAddr := SentinelAddr;
  if not WriteMemory(NewRSP, 8, ReturnAddr) then
  begin
    WriteLn('[ERROR] InjectCall: failed to write return address');
    WriteMemory(SentinelAddr, 1, OrigByte);
    Exit;
  end;

  { macOS x86_64 uses System V ABI: RDI = first param (Self) }
  NewRegs := SavedRegs;
  NewRegs.RIP := MethodAddr;
  NewRegs.RSP := NewRSP;
  NewRegs.RDI := SelfPtr;
  if ManagedReturn then
    NewRegs.RSI := ResultBufAddr;

  if not SetRegisters(NewRegs) then
  begin
    WriteLn('[ERROR] InjectCall: failed to set registers');
    WriteMemory(SentinelAddr, 1, OrigByte);
    Exit;
  end;

  if gVerbose then
    WriteLn('[DEBUG] InjectCall: calling $', IntToHex(MethodAddr, 16),
            ' Self=$', IntToHex(SelfPtr, 16),
            ' RSP=$', IntToHex(NewRSP, 16));

  Iterations := 0;
  repeat
    if ptrace(PT_CONTINUE, FPID, Pointer(1), 0) <> 0 then
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
      WriteMemory(StoppedAddr, 1, FBreakpoints[BpIdx].OriginalByte);
      ptrace(PT_STEP, FPID, Pointer(1), 0);
      FpWaitPid(FPID, @Status, 0);
      TrapByte := $CC;
      WriteMemory(StoppedAddr, 1, TrapByte);
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

  WriteMemory(SentinelAddr, 1, OrigByte);
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

function TMacOSMachAdapter.SendInterrupt: Boolean;
begin
  Result := False;
  if (FPID <= 0) or (not FAttached) then
    Exit;
  FpKill(FPID, SIGSTOP);
  Result := True;
end;

function TMacOSMachAdapter.GetLoadBase(const BinaryPath: String): QWord;
begin
  { TODO: Use task_info(TASK_DYLD_INFO) and parse the Mach-O load commands
    to determine the actual ASLR slide for macOS binaries. }
  Result := 0;
end;

{$ENDIF} { DARWIN }

end.
