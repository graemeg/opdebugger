{
  PDR Debugger - macOS Mach Exception Ports Adapter

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Platform-specific process control implementation for macOS using Mach
  exception ports, mach_vm_read/mach_vm_write, and thread_get_state/
  thread_set_state.

  PREREQUISITES: The program being debugged must be code-signed with the
  com.apple.security.get-task-allow entitlement (Blaise --debug-opdf signs
  it so), otherwise task_for_pid fails.  pdr itself needs no entitlement
  when the user may use developer tools (member of _developer, or
  "sudo DevToolsSecurity -enable"); otherwise run it as root.

  STATUS: the AArch64 (Apple Silicon) implementation is tested against
  Blaise macos-arm64 programs.  The x86_64/i386 implementation is still
  UNTESTED: it was written from Apple's Mach documentation and the XNU
  headers.
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
    {$IFDEF CPUAARCH64}
    OriginalInsn: Cardinal;      // 4-byte instruction replaced by BRK #0
    {$ENDIF}
    Active: Boolean;
  end;

  TWatchSlotInfo = record
    Address: QWord;
    Size: Byte;
    Active: Boolean;
    {$IFDEF CPUAARCH64}
    Control: QWord;              // DBGWCR value (DBGWVR is Address and not 7)
    {$ENDIF}
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
    FRedirectChildIO: Boolean;     // Accepted for parity with the ptrace adapters

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
    {$IFDEF CPUAARCH64}
    procedure MarkDetached;
    function AcquireTask: Boolean;
    function WaitForStop(out Status: cInt): Boolean;
    function GetExceptionClass(out FaultAddr: QWord): Cardinal;
    procedure RecordStop;
    function RawStep(out Status: cInt): Boolean;
    function StepOverBreakpointAtPC(out Stepped: Boolean; out Status: cInt): Boolean;
    function HandleTrap: Boolean;
    function ReadDebugState(out State): Boolean;      // arm_debug_state64_t
    function WriteDebugState(const State): Boolean;   // arm_debug_state64_t
    function ApplyWatchpoints(Armed: Boolean): Boolean;
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
    function GetTLSBase: QWord;

    property PID: Integer read FPID;
    property IsAttached: Boolean read FAttached;
    property RedirectChildIO: Boolean read FRedirectChildIO write FRedirectChildIO;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

{$IF DEFINED(CPUX86_64) or DEFINED(CPUI386)}

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

type
  PMachPortT = ^mach_port_t;

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
    WriteLn(StdErr, '[ERROR] Failed to enumerate threads (kern_return=', KR, ')');
    Exit;
  end;

  if ThreadCount = 0 then
  begin
    WriteLn(StdErr, '[ERROR] Process has no threads');
    Exit;
  end;

  FThreadPort := PMachPortT(ThreadList)^;
  Result := True;
end;

function TMacOSMachAdapter.SetupExceptionPort: Boolean;
var
  KR: kern_return_t;
begin
  Result := False;

  KR := mach_port_allocate(mach_task_self, MACH_PORT_RIGHT_RECEIVE, FExceptionPort);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] Failed to allocate exception port (kern_return=', KR, ')');
    Exit;
  end;

  KR := mach_port_insert_right(mach_task_self, FExceptionPort, FExceptionPort,
                               MACH_MSG_TYPE_MAKE_SEND);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] Failed to insert send right (kern_return=', KR, ')');
    Exit;
  end;

  KR := task_set_exception_ports(FTaskPort, EXC_MASK_BREAKPOINT,
    FExceptionPort, EXCEPTION_DEFAULT,
    {$IFDEF CPUX86_64}x86_THREAD_STATE64{$ELSE}x86_THREAD_STATE32{$ENDIF});
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] Failed to set exception ports (kern_return=', KR, ')');
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
    WriteLn(StdErr, '[ERROR] Failed to receive exception message (kern_return=', KR, ')');
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
    WriteLn(StdErr, '[ERROR] Already attached to PID ', FPID);
    Exit;
  end;

  if not FileExists(BinaryPath) then
  begin
    WriteLn(StdErr, '[ERROR] Binary file not found: ', BinaryPath);
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Launching program: ', BinaryPath);

  ChildPID := FpFork;

  if ChildPID = -1 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to fork: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if ChildPID = 0 then
  begin
    c_setpgid(0, 0);

    { macOS: PT_TRACE_ME enables ptrace tracing and SIGSTOP at exec }
    if ptrace(PT_TRACE_ME, 0, nil, 0) <> 0 then
    begin
      WriteLn(StdErr, '[ERROR] Child: Failed to enable tracing');
      fpExit(1);
    end;

    SetLength(Args, Length(FCommandLineArgs) + 2);
    Args[0] := PChar(BinaryPath);
    for I := 0 to High(FCommandLineArgs) do
      Args[I + 1] := PChar(FCommandLineArgs[I]);
    Args[Length(Args) - 1] := nil;

    FpExecV(PChar(BinaryPath), @Args[0]);

    WriteLn(StdErr, '[ERROR] Child: Failed to exec: ', SysErrorMessage(fpgeterrno));
    fpExit(1);
  end
  else
  begin
    if gVerbose then
      WriteLn(StdErr, '[INFO] Child process created with PID ', ChildPID);

    gWaitingPID := ChildPID;
    gUserInterrupted := False;
    if FpWaitPid(ChildPID, @Status, 0) = -1 then
    begin
      gWaitingPID := -1;
      WriteLn(StdErr, '[ERROR] Failed to wait for child process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;
    gWaitingPID := -1;

    if not WIFSTOPPED(Status) then
    begin
      WriteLn(StdErr, '[ERROR] Child process did not stop as expected');
      Exit;
    end;

    FPID := ChildPID;

    { Obtain the Mach task port for memory access and thread state }
    KR := task_for_pid(mach_task_self, FPID, FTaskPort);
    if KR <> KERN_SUCCESS then
    begin
      WriteLn(StdErr, '[ERROR] task_for_pid failed (kern_return=', KR, ')');
      WriteLn(StdErr, '[ERROR] Ensure the binary is code-signed with ',
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
      WriteLn(StdErr, '[INFO] Child process stopped at entry point');
      WriteLn(StdErr, '[INFO] Mach task port: ', FTaskPort, ', thread: ', FThreadPort);
      WriteLn(StdErr, '[INFO] Debugger has control (process is paused)');
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
    WriteLn(StdErr, '[ERROR] Already attached to PID ', FPID);
    Exit;
  end;

  FPID := PID;

  { Use PT_ATTACHEXC for exception-based debugging }
  if ptrace(PT_ATTACHEXC, FPID, nil, 0) <> 0 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to attach to process ', PID, ': ', SysErrorMessage(fpgeterrno));
    FPID := -1;
    Exit;
  end;

  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
    ptrace(PT_DETACH, FPID, nil, 0);
    FPID := -1;
    Exit;
  end;

  KR := task_for_pid(mach_task_self, FPID, FTaskPort);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] task_for_pid failed (kern_return=', KR, ')');
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
  WriteLn(StdErr, '[INFO] Successfully attached to PID ', FPID);
  Result := True;
end;

function TMacOSMachAdapter.Detach: Boolean;
var
  I: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[WARN] Not attached to any process');
    Exit(True);
  end;

  if Length(FBreakpoints) > 0 then
  begin
    if gVerbose then
      WriteLn(StdErr, '[INFO] Removing all breakpoints before detach');
    for I := 0 to High(FBreakpoints) do
    begin
      if FBreakpoints[I].Active then
        RemoveBreakpoint(FBreakpoints[I].Address);
    end;
    SetLength(FBreakpoints, 0);
  end;

  if ptrace(PT_DETACH, FPID, Pointer(1), 0) <> 0 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to detach from process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Detached from PID ', FPID);
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
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
      WriteLn(StdErr, '[ERROR] Failed to continue process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    SignalToDeliver := 0;

    gWaitingPID := FPID;
    gUserInterrupted := False;
    WaitResult := FpWaitPid(FPID, @Status, 0);
    gWaitingPID := -1;
    if WaitResult = -1 then
    begin
      WriteLn(StdErr, '[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
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
            WriteLn(StdErr, '[DEBUG] Hardware watchpoint hit: slot ', WatchSlot);

          Result := True;
          Exit;
        end;
        {$ENDIF}

        if not HandleBreakpointHit then
        begin
          WriteLn(StdErr, '[ERROR] Failed to handle breakpoint');
          Exit;
        end;
        Result := True;
        Exit;
      end
      else if Sig = SIGSTOP then
      begin
        gUserInterrupted := False;
        WriteLn('');
        WriteLn(StdErr, '[INFO] Interrupted');
        Result := True;
        Exit;
      end
      else if (Sig = SIGSEGV) or (Sig = SIGFPE) or (Sig = SIGILL) or
              (Sig = SIGBUS) or (Sig = SIGABRT) then
      begin
        WriteLn(StdErr, '[INFO] Process received signal ', Sig);
        FPendingSignal := Sig;
        Result := True;
        Exit;
      end
      else
      begin
        if gVerbose then
          WriteLn(StdErr, '[DEBUG] Passing through signal ', Sig, ' to process');
        SignalToDeliver := Sig;
      end;
    end
    else if WIFEXITED(Status) then
    begin
      WriteLn(StdErr, '[INFO] Process exited with code ', WEXITSTATUS(Status));
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
      WriteLn(StdErr, '[INFO] Process terminated by signal ', WTERMSIG(Status));
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  SignalToDeliver := 0;

  while True do
  begin
    if ptrace(PT_STEP, FPID, Pointer(1), SignalToDeliver) <> 0 then
    begin
      WriteLn(StdErr, '[ERROR] Failed to single step: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    SignalToDeliver := 0;

    gWaitingPID := FPID;
    gUserInterrupted := False;
    WaitResult := FpWaitPid(FPID, @Status, 0);
    gWaitingPID := -1;
    if WaitResult = -1 then
    begin
      WriteLn(StdErr, '[ERROR] Failed to wait for step: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;

    if WIFSTOPPED(Status) then
    begin
      Sig := WSTOPSIG(Status);

      if Sig = SIGTRAP then
      begin
        if gVerbose then WriteLn(StdErr, '[INFO] Step complete');
        Result := True;
        Exit;
      end
      else if Sig = SIGSTOP then
      begin
        gUserInterrupted := False;
        WriteLn('');
        WriteLn(StdErr, '[INFO] Interrupted');
        Result := True;
        Exit;
      end
      else if (Sig = SIGSEGV) or (Sig = SIGFPE) or (Sig = SIGILL) or
              (Sig = SIGBUS) or (Sig = SIGABRT) then
      begin
        WriteLn(StdErr, '[INFO] Process received signal ', Sig, ' during step');
        FPendingSignal := Sig;
        Result := True;
        Exit;
      end
      else
      begin
        if gVerbose then
          WriteLn(StdErr, '[DEBUG] Passing through signal ', Sig, ' during step');
        SignalToDeliver := Sig;
      end;
    end
    else if WIFEXITED(Status) then
    begin
      WriteLn(StdErr, '[INFO] Process exited during step with code ', WEXITSTATUS(Status));
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
      WriteLn(StdErr, '[INFO] Process terminated during step by signal ', WTERMSIG(Status));
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  KR := mach_vm_read_overwrite(FTaskPort, Address, Size,
    mach_vm_address_t(@Buffer), OutSize);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] Failed to read memory at $', IntToHex(Address, 16),
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
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
      WriteLn(StdErr, '[ERROR] Failed to write memory at $', IntToHex(Address, 16),
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
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
    WriteLn(StdErr, '[ERROR] Failed to get thread state (kern_return=', KR, ')');
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
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
    WriteLn(StdErr, '[ERROR] Failed to set thread state (kern_return=', KR, ')');
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
    WriteLn(StdErr, '[ERROR] Failed to get registers after breakpoint');
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
    WriteLn(StdErr, '[WARN] Breakpoint hit at unknown address: 0x', IntToHex(BreakpointAddr, 16));
    Exit(True);
  end;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Hit breakpoint at 0x', IntToHex(BreakpointAddr, 16));

  { Back up instruction pointer }
  {$IFDEF CPUX86_64}
  Regs.RIP := BreakpointAddr;
  {$ENDIF}
  {$IFDEF CPUI386}
  Regs.EIP := BreakpointAddr;
  {$ENDIF}

  if not SetRegisters(Regs) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to restore instruction pointer');
    Exit;
  end;

  { Restore original byte }
  OrigByte := FBreakpoints[Idx].OriginalByte;
  if not WriteMemory(BreakpointAddr, 1, OrigByte) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to restore original instruction');
    Exit;
  end;

  { Single-step over the original instruction }
  if ptrace(PT_STEP, FPID, Pointer(1), 0) <> 0 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to single-step over restored instruction');
    Exit;
  end;

  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to wait for single-step');
    Exit;
  end;

  { Re-insert the breakpoint }
  TrapByte := $CC;
  if not WriteMemory(BreakpointAddr, 1, TrapByte) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to re-insert breakpoint');
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  Idx := FindBreakpoint(Address);
  if Idx >= 0 then
  begin
    if FBreakpoints[Idx].Active then
    begin
      WriteLn(StdErr, '[WARN] Breakpoint already set at $', IntToHex(Address, 16));
      Exit(True);
    end
    else
    begin
      TrapByte := $CC;
      if not WriteMemory(Address, 1, TrapByte) then
      begin
        WriteLn(StdErr, '[ERROR] Failed to reactivate breakpoint');
        Exit(False);
      end;
      FBreakpoints[Idx].Active := True;
      if gVerbose then
        WriteLn(StdErr, '[INFO] Reactivated breakpoint at $', IntToHex(Address, 16));
      Exit(True);
    end;
  end;

  if not ReadMemory(Address, 1, OrigByte) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to read memory for breakpoint');
    Exit;
  end;

  BpInfo.Address := Address;
  BpInfo.OriginalByte := OrigByte;
  BpInfo.Active := True;

  TrapByte := $CC;
  if not WriteMemory(Address, 1, TrapByte) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to set breakpoint');
    Exit;
  end;

  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := BpInfo;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Breakpoint set at $', IntToHex(Address, 16));
  Result := True;
end;

function TMacOSMachAdapter.RemoveBreakpoint(Address: QWord): Boolean;
var
  Idx: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  Idx := FindBreakpoint(Address);
  if Idx < 0 then
  begin
    WriteLn(StdErr, '[ERROR] No breakpoint found at $', IntToHex(Address, 16));
    Exit;
  end;

  if not FBreakpoints[Idx].Active then
  begin
    WriteLn(StdErr, '[WARN] Breakpoint at $', IntToHex(Address, 16), ' already removed');
    Exit(True);
  end;

  if not WriteMemory(Address, 1, FBreakpoints[Idx].OriginalByte) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to remove breakpoint');
    Exit;
  end;

  FBreakpoints[Idx].Active := False;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Breakpoint removed from $', IntToHex(Address, 16));
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
    WriteLn(StdErr, '[INFO] Set command-line arguments: ', String.Join(' ', Args));

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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
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
    WriteLn(StdErr, '[ERROR] All 4 hardware watchpoint slots are in use');
    Result := -1;
    Exit;
  end;

  case Size of
    1: LenCode := 0;
    2: LenCode := 1;
    4: LenCode := 3;
    8: LenCode := 2;
  else
    WriteLn(StdErr, '[ERROR] Unsupported watchpoint size: ', Size);
    Result := -1;
    Exit;
  end;

  case WatchType of
    wtWrite:     CondCode := 1;
    wtReadWrite: CondCode := 3;
  end;

  if not ReadDebugState(DR0, DR1, DR2, DR3, DR6, DR7) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to read debug registers');
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
    WriteLn(StdErr, '[ERROR] Failed to write debug registers');
    Result := -1;
    Exit;
  end;

  FWatchSlots[Slot].Address := Address;
  FWatchSlots[Slot].Size := Size;
  FWatchSlots[Slot].Active := True;

  if gVerbose then
    WriteLn(StdErr, '[DEBUG] Watchpoint set in slot ', Slot,
            ' at 0x', IntToHex(Address, 16), ' size=', Size);

  Result := Slot;
end;
{$ELSE}
begin
  Result := -1;
  WriteLn(StdErr, '[ERROR] Hardware watchpoints only supported on x86_64');
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
    WriteLn(StdErr, '[ERROR] Invalid watchpoint slot: ', Slot);
    Exit;
  end;

  if not FWatchSlots[Slot].Active then
  begin
    if gVerbose then WriteLn(StdErr, '[INFO] Watchpoint slot ', Slot, ' already inactive');
    Result := True;
    Exit;
  end;

  if not ReadDebugState(DR0, DR1, DR2, DR3, DR6, DR7) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to read debug registers');
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
    WriteLn(StdErr, '[ERROR] Failed to write debug registers');
    Exit;
  end;

  FWatchSlots[Slot].Active := False;

  if gVerbose then
    WriteLn(StdErr, '[DEBUG] Watchpoint slot ', Slot, ' cleared');

  Result := True;
end;
{$ELSE}
begin
  Result := False;
  WriteLn(StdErr, '[ERROR] Hardware watchpoints only supported on x86_64');
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
    WriteLn(StdErr, '[ERROR] InjectCall: not attached to any process');
    Exit;
  end;

  if not GetRegisters(SavedRegs) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to save registers');
    Exit;
  end;

  SentinelAddr := SavedRegs.RIP;

  if not ReadMemory(SentinelAddr, 1, OrigByte) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to read memory at sentinel');
    Exit;
  end;

  TrapByte := $CC;
  if not WriteMemory(SentinelAddr, 1, TrapByte) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to write INT3 sentinel');
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
      WriteLn(StdErr, '[ERROR] InjectCall: failed to zero result buffer');
      WriteMemory(SentinelAddr, 1, OrigByte);
      Exit;
    end;
  end;

  ReturnAddr := SentinelAddr;
  if not WriteMemory(NewRSP, 8, ReturnAddr) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to write return address');
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
    WriteLn(StdErr, '[ERROR] InjectCall: failed to set registers');
    WriteMemory(SentinelAddr, 1, OrigByte);
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[DEBUG] InjectCall: calling $', IntToHex(MethodAddr, 16),
            ' Self=$', IntToHex(SelfPtr, 16),
            ' RSP=$', IntToHex(NewRSP, 16));

  Iterations := 0;
  repeat
    if ptrace(PT_CONTINUE, FPID, Pointer(1), 0) <> 0 then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: failed to continue');
      Break;
    end;

    if FpWaitPid(FPID, @Status, 0) = -1 then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: failed to wait');
      Break;
    end;

    if WIFEXITED(Status) or WIFSIGNALED(Status) then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: process terminated during injection');
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
        WriteLn(StdErr, '[DEBUG] InjectCall: hit user breakpoint at $',
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
        WriteLn(StdErr, '[DEBUG] InjectCall: unexpected stop at $',
                IntToHex(StoppedAddr, 16), ' signal=', WSTOPSIG(Status));
    end;

    Inc(Iterations);
  until Iterations >= MAX_ITERATIONS;

  if Iterations >= MAX_ITERATIONS then
    WriteLn(StdErr, '[ERROR] InjectCall: timeout — iteration limit reached');

  WriteMemory(SentinelAddr, 1, OrigByte);
  SetRegisters(SavedRegs);

  if gVerbose and Result then
    WriteLn(StdErr, '[DEBUG] InjectCall: completed, RetValue=$', IntToHex(RetValue, 16));
end;
{$ELSE}
begin
  Result := False;
  RetValue := 0;
  WriteLn(StdErr, '[ERROR] InjectCall: only supported on x86_64');
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

function TMacOSMachAdapter.GetTLSBase: QWord;
begin
  { TODO: Use thread_get_state with x86_THREAD_STATE64 to read fs_base,
    or read the TLS base from the thread's Mach port — untested. }
  Result := 0;
end;

{$ELSEIF DEFINED(CPUAARCH64)}

{ ====================================================================
  AArch64 (Apple Silicon)

  Process control is signal driven, exactly like the Linux adapter: the
  child runs under PT_TRACE_ME, every Mach exception (BRK, single step,
  watchpoint) reaches pdr as a SIGTRAP stop through waitpid, and PT_STEP
  single-steps.  Mach is used only where ptrace has no equivalent on macOS:
  task_for_pid for the task port, mach_vm_* for memory, and
  thread_get_state/thread_set_state for registers and debug registers.
  No exception port is registered.

  Breakpoints are the 4-byte BRK #0.  A BRK trap leaves PC ON the BRK, so a
  hit does not rewind PC and does not step past it; instead, resuming from
  a PC that holds an active breakpoint first steps over it (restore the
  original instruction, PT_STEP, re-insert).  If that one step lands on
  another active breakpoint, the resume reports it as a hit immediately.

  Only the main thread is debugged: PT_STEP single-steps the task's first
  thread, and debug registers are per thread.
  ==================================================================== }

const
  KERN_SUCCESS = 0;

  { Thread state flavours (mach/arm/thread_status.h) }
  ARM_THREAD_STATE64          = 6;
  ARM_THREAD_STATE64_COUNT    = 68;
  ARM_EXCEPTION_STATE64       = 7;
  ARM_EXCEPTION_STATE64_COUNT = 4;
  ARM_DEBUG_STATE64           = 15;
  ARM_DEBUG_STATE64_COUNT     = 130;

  { ESR_EL1 exception classes (ESR >> 26) }
  ESR_EC_SOFTWARE_STEP_LOWER = $32;
  ESR_EC_WATCHPOINT_LOWER    = $34;
  ESR_EC_WATCHPOINT_SAME     = $35;
  ESR_EC_BRK                 = $3C;

  { BRK #0 }
  BRK_INSN = Cardinal($D4200000);

  { DBGWCR: E (enable), PAC = EL0 only, LSC = store / load+store }
  WCR_ENABLE    = 1;
  WCR_PAC_EL0   = 2 shl 1;
  WCR_LSC_STORE = 2 shl 3;
  WCR_LSC_RW    = 3 shl 3;

  VM_PROT_WRITE   = 2;
  VM_PROT_EXECUTE = 4;
  VM_PROT_COPY    = $10;
  VM_REGION_BASIC_INFO_64       = 9;
  VM_REGION_BASIC_INFO_COUNT_64 = 9;
  MATTR_CACHE           = 1;
  MATTR_VAL_CACHE_FLUSH = 6;

  MH_MAGIC_64    = Cardinal($FEEDFACF);
  MH_EXECUTE     = 2;
  LC_SEGMENT_64  = $19;

  { POSIX signal numbers (macOS) }
  SIGHUP  = 1;
  SIGINT  = 2;
  SIGQUIT = 3;
  SIGILL  = 4;
  SIGTRAP = 5;
  SIGABRT = 6;
  SIGFPE  = 8;
  SIGKILL = 9;
  SIGBUS  = 10;
  SIGSEGV = 11;
  SIGPIPE = 13;
  SIGALRM = 14;
  SIGTERM = 15;
  SIGSTOP = 17;
  SIGTSTP = 18;

  { ptrace requests (sys/ptrace.h) }
  PT_TRACE_ME = 0;
  PT_CONTINUE = 7;
  PT_KILL     = 8;
  PT_STEP     = 9;
  PT_ATTACH   = 10;
  PT_DETACH   = 11;

type
  mach_port_t = Cardinal;
  kern_return_t = Integer;
  mach_vm_address_t = QWord;
  mach_vm_size_t = QWord;
  mach_msg_type_number_t = Cardinal;
  PMachPortT = ^mach_port_t;

  arm_thread_state64_t = record
    x: array[0..28] of QWord;
    fp: QWord;
    lr: QWord;
    sp: QWord;
    pc: QWord;
    cpsr: Cardinal;
    flags: Cardinal;
  end;

  arm_exception_state64_t = record
    far: QWord;
    esr: Cardinal;
    exception: Cardinal;
  end;

  arm_debug_state64_t = record
    bvr: array[0..15] of QWord;
    bcr: array[0..15] of QWord;
    wvr: array[0..15] of QWord;
    wcr: array[0..15] of QWord;
    mdscr_el1: QWord;
  end;

  { #pragma pack(4) in mach/vm_region.h }
  vm_region_basic_info_64_t = packed record
    protection: Integer;
    max_protection: Integer;
    inheritance: Cardinal;
    shared: Cardinal;
    reserved: Cardinal;
    offset: QWord;
    behavior: Integer;
    user_wired_count: Word;
    pad: Word;
  end;

  mach_header_64_t = record
    magic: Cardinal;
    cputype: Integer;
    cpusubtype: Integer;
    filetype: Cardinal;
    ncmds: Cardinal;
    sizeofcmds: Cardinal;
    flags: Cardinal;
    reserved: Cardinal;
  end;

  segment_command_64_t = record
    cmd: Cardinal;
    cmdsize: Cardinal;
    segname: array[0..15] of Char;
    vmaddr: QWord;
    vmsize: QWord;
    fileoff: QWord;
    filesize: QWord;
    maxprot: Integer;
    initprot: Integer;
    nsects: Cardinal;
    flags: Cardinal;
  end;

function task_for_pid(target_tport: mach_port_t; pid: Integer;
  out t: mach_port_t): kern_return_t; cdecl; external 'c';
function mach_task_self: mach_port_t; cdecl; external 'c';
function mach_error_string(error_value: kern_return_t): PChar; cdecl; external 'c';
function mach_vm_read_overwrite(target_task: mach_port_t; address: mach_vm_address_t;
  size: mach_vm_size_t; data: mach_vm_address_t;
  out outsize: mach_vm_size_t): kern_return_t; cdecl; external 'c';
function mach_vm_write(target_task: mach_port_t; address: mach_vm_address_t;
  data: PtrUInt; dataCnt: mach_msg_type_number_t): kern_return_t; cdecl; external 'c';
function mach_vm_protect(target_task: mach_port_t; address: mach_vm_address_t;
  size: mach_vm_size_t; set_maximum: Integer;
  new_protection: Integer): kern_return_t; cdecl; external 'c';
function mach_vm_region(target_task: mach_port_t; var address: mach_vm_address_t;
  var size: mach_vm_size_t; flavor: Integer; info: Pointer;
  var infoCnt: mach_msg_type_number_t;
  out object_name: mach_port_t): kern_return_t; cdecl; external 'c';
function vm_machine_attribute(target_task: mach_port_t; address: PtrUInt;
  size: PtrUInt; attribute: Cardinal; var value: Integer): kern_return_t;
  cdecl; external 'c';
function vm_deallocate(target_task: mach_port_t; address: PtrUInt;
  size: PtrUInt): kern_return_t; cdecl; external 'c';
function task_threads(target_task: mach_port_t; out act_list: Pointer;
  out act_listCnt: mach_msg_type_number_t): kern_return_t; cdecl; external 'c';
function thread_get_state(target_act: mach_port_t; flavor: Integer;
  old_state: Pointer;
  var old_stateCnt: mach_msg_type_number_t): kern_return_t; cdecl; external 'c';
function thread_set_state(target_act: mach_port_t; flavor: Integer;
  new_state: Pointer;
  new_stateCnt: mach_msg_type_number_t): kern_return_t; cdecl; external 'c';

function ptrace(request: cInt; pid: TPid; addr: Pointer;
  data: cInt): cInt; cdecl; external 'c' name 'ptrace';
function c_setpgid(pid: TPid; pgid: TPid): cInt;
  cdecl; external 'c' name 'setpgid';

var
  { Ctrl+C support: unit-level state for SIGINT handler }
  gWaitingPID: TPid = -1;
  gUserInterrupted: Boolean = False;

procedure HandleSIGINT(Sig: cInt); cdecl;
begin
  if gWaitingPID > 0 then
    FpKill(gWaitingPID, SIGSTOP);
  gUserInterrupted := True;
end;

function IsStopSignal(Sig: Integer): Boolean;
begin
  { Signals that indicate a real problem — stop and report to user }
  case Sig of
    SIGSEGV, SIGFPE, SIGILL, SIGBUS, SIGABRT:
      Result := True;
  else
    Result := False;
  end;
end;

function SignalName(Sig: Integer): String;
begin
  case Sig of
    SIGHUP:  Result := 'SIGHUP';
    SIGINT:  Result := 'SIGINT';
    SIGQUIT: Result := 'SIGQUIT';
    SIGILL:  Result := 'SIGILL';
    SIGTRAP: Result := 'SIGTRAP';
    SIGABRT: Result := 'SIGABRT';
    SIGBUS:  Result := 'SIGBUS';
    SIGFPE:  Result := 'SIGFPE';
    SIGKILL: Result := 'SIGKILL';
    SIGSEGV: Result := 'SIGSEGV';
    SIGPIPE: Result := 'SIGPIPE';
    SIGALRM: Result := 'SIGALRM';
    SIGTERM: Result := 'SIGTERM';
    SIGSTOP: Result := 'SIGSTOP';
    SIGTSTP: Result := 'SIGTSTP';
  else
    Result := 'SIG' + IntToStr(Sig);
  end;
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
  FRedirectChildIO := False;
  for I := 0 to 3 do
    FWatchSlots[I].Active := False;

  { Install SIGINT handler so Ctrl+C interrupts the tracee instead of killing pdr }
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

procedure TMacOSMachAdapter.MarkDetached;
var
  I: Integer;
begin
  FAttached := False;
  FPID := -1;
  FTaskPort := 0;
  FThreadPort := 0;
  FPendingSignal := 0;
  SetLength(FBreakpoints, 0);
  for I := 0 to 3 do
    FWatchSlots[I].Active := False;
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
    WriteLn(StdErr, '[ERROR] Failed to enumerate threads (kern_return=', KR, ')');
    Exit;
  end;

  if ThreadCount > 0 then
    FThreadPort := PMachPortT(ThreadList)^;
  vm_deallocate(mach_task_self, PtrUInt(ThreadList),
                ThreadCount * SizeOf(mach_port_t));

  if ThreadCount = 0 then
  begin
    WriteLn(StdErr, '[ERROR] Process has no threads');
    Exit;
  end;

  Result := True;
end;

function TMacOSMachAdapter.SetupExceptionPort: Boolean;
begin
  { Not used: exceptions arrive as SIGTRAP stops (see the block comment) }
  Result := True;
end;

function TMacOSMachAdapter.WaitForException(out ExcType: Integer): Boolean;
begin
  ExcType := 0;
  Result := False;
end;

function TMacOSMachAdapter.ReplyToException(ExcType: Integer): Boolean;
begin
  Result := True;
end;

function TMacOSMachAdapter.AcquireTask: Boolean;
var
  KR: kern_return_t;
begin
  Result := False;
  KR := task_for_pid(mach_task_self, FPID, FTaskPort);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] task_for_pid failed: ', mach_error_string(KR),
            ' (kern_return=', KR, ')');
    WriteLn(StdErr, '[ERROR] The target must be signed with the ',
            'com.apple.security.get-task-allow entitlement (Blaise --debug-opdf ',
            'does this), and pdr must be allowed to debug: run ',
            '"sudo DevToolsSecurity -enable" or run pdr with sudo');
    Exit;
  end;
  Result := GetMainThread;
end;

function TMacOSMachAdapter.Launch(const BinaryPath: String): Boolean;
var
  ChildPID: TPid;
  Status: cInt;
  Args: array of PChar;
  I: Integer;
  NullFD: cInt;
begin
  Result := False;

  if FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Already attached to PID ', FPID);
    Exit;
  end;

  if not FileExists(BinaryPath) then
  begin
    WriteLn(StdErr, '[ERROR] Binary file not found: ', BinaryPath);
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Launching program: ', BinaryPath);

  ChildPID := FpFork;

  if ChildPID = -1 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to fork: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if ChildPID = 0 then
  begin
    { Own process group, so terminal Ctrl+C only goes to pdr }
    c_setpgid(0, 0);

    if FRedirectChildIO then
    begin
      NullFD := FpOpen('/dev/null', O_RDWR);
      if NullFD >= 0 then
      begin
        FpDup2(NullFD, 0);
        FpDup2(NullFD, 1);
        FpDup2(NullFD, 2);
        if NullFD > 2 then
          FpClose(NullFD);
      end;
    end;

    { PT_TRACE_ME: the exec below stops the child with SIGTRAP }
    if ptrace(PT_TRACE_ME, 0, nil, 0) <> 0 then
    begin
      WriteLn(StdErr, '[ERROR] Child: Failed to enable tracing');
      fpExit(1);
    end;

    SetLength(Args, Length(FCommandLineArgs) + 2);
    Args[0] := PChar(BinaryPath);
    for I := 0 to High(FCommandLineArgs) do
      Args[I + 1] := PChar(FCommandLineArgs[I]);
    Args[Length(Args) - 1] := nil;

    FpExecV(PChar(BinaryPath), @Args[0]);

    WriteLn(StdErr, '[ERROR] Child: Failed to exec: ', SysErrorMessage(fpgeterrno));
    fpExit(1);
  end;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Child process created with PID ', ChildPID);

  gWaitingPID := ChildPID;
  gUserInterrupted := False;
  if FpWaitPid(ChildPID, @Status, 0) = -1 then
  begin
    gWaitingPID := -1;
    WriteLn(StdErr, '[ERROR] Failed to wait for child process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;
  gWaitingPID := -1;

  if not WIFSTOPPED(Status) then
  begin
    WriteLn(StdErr, '[ERROR] Child process did not stop as expected');
    Exit;
  end;

  FPID := ChildPID;
  if not AcquireTask then
  begin
    ptrace(PT_KILL, FPID, nil, 0);
    FpWaitPid(FPID, @Status, 0);
    FPID := -1;
    Exit;
  end;

  FAttached := True;

  if gVerbose then
  begin
    WriteLn(StdErr, '[INFO] Child process stopped at entry point');
    WriteLn(StdErr, '[INFO] Mach task port: ', FTaskPort, ', thread: ', FThreadPort);
  end;
  Result := True;
end;

function TMacOSMachAdapter.Attach(PID: Integer): Boolean;
var
  Status: cInt;
begin
  Result := False;

  if FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Already attached to PID ', FPID);
    Exit;
  end;

  FPID := PID;

  { PT_ATTACH, not PT_ATTACHEXC: exceptions must keep arriving as signals,
    since no exception port is serviced }
  if ptrace(PT_ATTACH, FPID, nil, 0) <> 0 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to attach to process ', PID, ': ',
            SysErrorMessage(fpgeterrno));
    FPID := -1;
    Exit;
  end;

  if FpWaitPid(FPID, @Status, 0) = -1 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
    ptrace(PT_DETACH, FPID, Pointer(1), 0);
    FPID := -1;
    Exit;
  end;

  if not AcquireTask then
  begin
    ptrace(PT_DETACH, FPID, Pointer(1), 0);
    FPID := -1;
    Exit;
  end;

  FAttached := True;
  WriteLn(StdErr, '[INFO] Successfully attached to PID ', FPID);
  Result := True;
end;

function TMacOSMachAdapter.Detach: Boolean;
var
  I: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[WARN] Not attached to any process');
    Exit(True);
  end;

  for I := 0 to 3 do
    if FWatchSlots[I].Active then
      ClearWatchpoint(I);

  if Length(FBreakpoints) > 0 then
  begin
    if gVerbose then
      WriteLn(StdErr, '[INFO] Removing all breakpoints before detach');
    for I := 0 to High(FBreakpoints) do
      if FBreakpoints[I].Active then
        RemoveBreakpoint(FBreakpoints[I].Address);
    SetLength(FBreakpoints, 0);
  end;

  if ptrace(PT_DETACH, FPID, Pointer(1), 0) <> 0 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to detach from process: ', SysErrorMessage(fpgeterrno));
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Detached from PID ', FPID);
  MarkDetached;
  Result := True;
end;

{ Waits for the tracee to stop.  Returns False if waitpid itself failed.
  On exit/termination reports it and marks the adapter detached. }
function TMacOSMachAdapter.WaitForStop(out Status: cInt): Boolean;
var
  WaitResult: TPid;
begin
  gWaitingPID := FPID;
  gUserInterrupted := False;
  WaitResult := FpWaitPid(FPID, @Status, 0);
  gWaitingPID := -1;
  if WaitResult = -1 then
  begin
    WriteLn(StdErr, '[ERROR] Failed to wait for process: ', SysErrorMessage(fpgeterrno));
    Exit(False);
  end;

  if WIFEXITED(Status) then
  begin
    WriteLn(StdErr, '[INFO] Process exited with code ', WEXITSTATUS(Status));
    MarkDetached;
  end
  else if WIFSIGNALED(Status) then
  begin
    WriteLn(StdErr, '[INFO] Process terminated by signal ',
            SignalName(WTERMSIG(Status)), ' (', WTERMSIG(Status), ')');
    MarkDetached;
  end;
  Result := True;
end;

function TMacOSMachAdapter.GetExceptionClass(out FaultAddr: QWord): Cardinal;
var
  State: arm_exception_state64_t;
  Count: mach_msg_type_number_t;
begin
  Result := 0;
  FaultAddr := 0;
  FillChar(State, SizeOf(State), 0);
  Count := ARM_EXCEPTION_STATE64_COUNT;
  if thread_get_state(FThreadPort, ARM_EXCEPTION_STATE64, @State, Count) <> KERN_SUCCESS then
    Exit;
  FaultAddr := State.far;
  Result := State.esr shr 26;
end;

procedure TMacOSMachAdapter.RecordStop;
var
  Regs: TRegisters;
begin
  if GetRegisters(Regs) then
  begin
    FLastBreakpointAddr := Regs.PC;
    FLastBreakpointRBP := Regs.X[29];
  end;
end;

{ One raw PT_STEP of the main thread.  Signals other than SIGTRAP that
  arrive first are passed through (benign) or left pending (serious). }
function TMacOSMachAdapter.RawStep(out Status: cInt): Boolean;
var
  SignalToDeliver: cInt;
  Sig: Integer;
begin
  Result := False;
  SignalToDeliver := 0;
  while True do
  begin
    if ptrace(PT_STEP, FPID, Pointer(1), SignalToDeliver) <> 0 then
    begin
      WriteLn(StdErr, '[ERROR] Failed to single step: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;
    SignalToDeliver := 0;

    if not WaitForStop(Status) then
      Exit;
    if not WIFSTOPPED(Status) then
      Exit(True);  { exited — already reported }

    { The kernel implements PT_STEP through the thread's debug state and
      clears that state when the step completes — watchpoints included.
      Put them back. }
    ApplyWatchpoints(True);

    Sig := WSTOPSIG(Status);
    if (Sig = SIGTRAP) or (Sig = SIGSTOP) or IsStopSignal(Sig) then
      Exit(True);

    if gVerbose then
      WriteLn(StdErr, '[DEBUG] Passing through ', SignalName(Sig), ' during step');
    SignalToDeliver := Sig;
  end;
end;

{ If PC sits on an active breakpoint, execute the original instruction
  under it with one single step and re-insert the BRK.  Returns False on
  failure; Stepped tells whether a step was taken. }
function TMacOSMachAdapter.StepOverBreakpointAtPC(out Stepped: Boolean;
  out Status: cInt): Boolean;
var
  Regs: TRegisters;
  Idx: Integer;
  Trap: Cardinal;
begin
  Result := False;
  Stepped := False;
  Status := 0;

  if not GetRegisters(Regs) then
    Exit;
  Idx := FindBreakpoint(Regs.PC);
  if (Idx < 0) or not FBreakpoints[Idx].Active then
    Exit(True);

  if not WriteMemory(Regs.PC, 4, FBreakpoints[Idx].OriginalInsn) then
    Exit;

  Stepped := True;
  Result := RawStep(Status);

  if FAttached then
  begin
    Trap := BRK_INSN;
    if not WriteMemory(FBreakpoints[Idx].Address, 4, Trap) then
    begin
      WriteLn(StdErr, '[ERROR] Failed to re-insert breakpoint at $',
              IntToHex(FBreakpoints[Idx].Address, 16));
      Result := False;
    end;
  end;
end;

{ Classify a SIGTRAP stop from Continue: watchpoint, breakpoint, or other. }
function TMacOSMachAdapter.HandleTrap: Boolean;
var
  EC: Cardinal;
  FaultAddr: QWord;
  Slot, I: Integer;
  Status: cInt;
begin
  Result := False;
  EC := GetExceptionClass(FaultAddr);

  if (EC = ESR_EC_WATCHPOINT_LOWER) or (EC = ESR_EC_WATCHPOINT_SAME) then
  begin
    Slot := -1;
    for I := 0 to 3 do
      if FWatchSlots[I].Active and (FaultAddr >= FWatchSlots[I].Address) and
         (FaultAddr < FWatchSlots[I].Address + FWatchSlots[I].Size) then
      begin
        Slot := I;
        Break;
      end;
    if Slot < 0 then
      for I := 0 to 3 do
        if FWatchSlots[I].Active then
        begin
          Slot := I;
          Break;
        end;
    FLastFiredWatchpoint := Slot;

    { AArch64 watchpoints trap BEFORE the access completes.  Disarm, step
      the accessing instruction (RawStep re-arms afterwards) — so the new
      value is visible and continuing does not re-trigger on the same
      access. }
    if not ApplyWatchpoints(False) then
      Exit;
    if not RawStep(Status) then
      Exit;
    if not FAttached then
      Exit(True);

    RecordStop;
    if gVerbose then
      WriteLn(StdErr, '[DEBUG] Hardware watchpoint hit: slot ', Slot,
              ' (access at $', IntToHex(FaultAddr, 16), ')');
    Exit(True);
  end;

  Result := HandleBreakpointHit;
end;

function TMacOSMachAdapter.Continue: Boolean;
var
  Status: cInt;
  Sig: Integer;
  SignalToDeliver: cInt;
  Stepped: Boolean;
  Regs: TRegisters;
begin
  Result := False;
  FLastFiredWatchpoint := -1;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  if FPendingSignal <> 0 then
  begin
    SignalToDeliver := FPendingSignal;
    if gVerbose then
      WriteLn(StdErr, '[DEBUG] Delivering pending signal ', SignalName(FPendingSignal),
              ' to process');
    FPendingSignal := 0;
  end
  else
  begin
    SignalToDeliver := 0;

    { Resuming from a breakpoint: execute the instruction under it first }
    if not StepOverBreakpointAtPC(Stepped, Status) then
      Exit;
    if Stepped then
    begin
      if not FAttached then
        Exit(True);  { exited during the step — already reported }
      Sig := WSTOPSIG(Status);
      if Sig <> SIGTRAP then
      begin
        if Sig = SIGSTOP then
          WriteLn(StdErr, '[INFO] Interrupted')
        else
        begin
          WriteLn(StdErr, '[INFO] Process received ', SignalName(Sig), ' (signal ', Sig, ')');
          FPendingSignal := Sig;
        end;
        RecordStop;
        Exit(True);
      end;
      { The step landed on another active breakpoint: that is a hit }
      if GetRegisters(Regs) and (FindBreakpoint(Regs.PC) >= 0) and
         FBreakpoints[FindBreakpoint(Regs.PC)].Active then
        Exit(HandleBreakpointHit);
    end;
  end;

  while True do
  begin
    { PT_CONTINUE with addr=1 resumes at the current PC }
    if ptrace(PT_CONTINUE, FPID, Pointer(1), SignalToDeliver) <> 0 then
    begin
      WriteLn(StdErr, '[ERROR] Failed to continue process: ', SysErrorMessage(fpgeterrno));
      Exit;
    end;
    SignalToDeliver := 0;

    if not WaitForStop(Status) then
      Exit;
    if not WIFSTOPPED(Status) then
      Exit(True);  { exited — already reported }

    Sig := WSTOPSIG(Status);
    if Sig = SIGTRAP then
    begin
      if not HandleTrap then
      begin
        WriteLn(StdErr, '[ERROR] Failed to handle breakpoint');
        Exit;
      end;
      Exit(True);
    end
    else if Sig = SIGSTOP then
    begin
      gUserInterrupted := False;
      WriteLn('');
      WriteLn(StdErr, '[INFO] Interrupted');
      RecordStop;
      Exit(True);
    end
    else if IsStopSignal(Sig) then
    begin
      WriteLn(StdErr, '[INFO] Process received ', SignalName(Sig), ' (signal ', Sig, ')');
      FPendingSignal := Sig;
      RecordStop;
      Exit(True);
    end
    else
    begin
      if gVerbose then
        WriteLn(StdErr, '[DEBUG] Passing through ', SignalName(Sig), ' to process');
      SignalToDeliver := Sig;
    end;
  end;
end;

function TMacOSMachAdapter.Step: Boolean;
var
  Status: cInt;
  Sig: Integer;
  Stepped: Boolean;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  { On a breakpoint, stepping over it IS the single step }
  if not StepOverBreakpointAtPC(Stepped, Status) then
    Exit;
  if not Stepped then
    if not RawStep(Status) then
      Exit;

  if not FAttached then
    Exit(True);  { exited during the step — already reported }

  Sig := WSTOPSIG(Status);
  if Sig = SIGTRAP then
  begin
    if gVerbose then WriteLn(StdErr, '[INFO] Step complete');
  end
  else if Sig = SIGSTOP then
  begin
    gUserInterrupted := False;
    WriteLn('');
    WriteLn(StdErr, '[INFO] Interrupted');
  end
  else
  begin
    WriteLn(StdErr, '[INFO] Process received ', SignalName(Sig),
            ' (signal ', Sig, ') during step');
    FPendingSignal := Sig;
  end;
  Result := True;
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
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  KR := mach_vm_read_overwrite(FTaskPort, Address, Size,
    mach_vm_address_t(@Buffer), OutSize);
  if (KR <> KERN_SUCCESS) or (OutSize <> Size) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to read memory at $', IntToHex(Address, 16),
            ' (kern_return=', KR, ')');
    Exit;
  end;

  Result := True;
end;

function TMacOSMachAdapter.WriteMemory(Address: QWord; Size: Cardinal;
  const Buffer): Boolean;
var
  KR: kern_return_t;
  RegionAddr: mach_vm_address_t;
  RegionSize: mach_vm_size_t;
  Info: vm_region_basic_info_64_t;
  InfoCount: mach_msg_type_number_t;
  ObjName: mach_port_t;
  CacheVal: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  KR := mach_vm_write(FTaskPort, Address, PtrUInt(@Buffer), Size);
  if KR = KERN_SUCCESS then
    Exit(True);

  { Read-only page — code (r-x) in practice.  Make a private writable copy
    (VM_PROT_COPY: the page is file-backed and code-signed), write, put the
    original protection back, and flush the caches so the CPU fetches the
    new instruction.  Apple Silicon enforces W^X, so the page is writable
    only while it is NOT executable. }
  RegionAddr := Address;
  RegionSize := 0;
  FillChar(Info, SizeOf(Info), 0);
  InfoCount := VM_REGION_BASIC_INFO_COUNT_64;
  KR := mach_vm_region(FTaskPort, RegionAddr, RegionSize, VM_REGION_BASIC_INFO_64,
                       @Info, InfoCount, ObjName);
  if (KR <> KERN_SUCCESS) or (RegionAddr > Address) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to write memory at $', IntToHex(Address, 16),
            ' (no mapped region)');
    Exit;
  end;

  KR := mach_vm_protect(FTaskPort, Address, Size, 0,
    (Info.protection and not VM_PROT_EXECUTE) or VM_PROT_WRITE or VM_PROT_COPY);
  if KR = KERN_SUCCESS then
  begin
    KR := mach_vm_write(FTaskPort, Address, PtrUInt(@Buffer), Size);
    mach_vm_protect(FTaskPort, Address, Size, 0, Info.protection);
  end;
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] Failed to write memory at $', IntToHex(Address, 16),
            ' (kern_return=', KR, ')');
    Exit;
  end;

  if (Info.protection and VM_PROT_EXECUTE) <> 0 then
  begin
    CacheVal := MATTR_VAL_CACHE_FLUSH;
    vm_machine_attribute(FTaskPort, PtrUInt(Address), Size, MATTR_CACHE, CacheVal);
  end;

  Result := True;
end;

function TMacOSMachAdapter.GetRegisters(out Regs: TRegisters): Boolean;
var
  KR: kern_return_t;
  Count: mach_msg_type_number_t;
  State: arm_thread_state64_t;
  I: Integer;
begin
  Result := False;
  FillChar(Regs, SizeOf(Regs), 0);

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  FillChar(State, SizeOf(State), 0);
  Count := ARM_THREAD_STATE64_COUNT;
  KR := thread_get_state(FThreadPort, ARM_THREAD_STATE64, @State, Count);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] Failed to get thread state (kern_return=', KR, ')');
    Exit;
  end;

  for I := 0 to 28 do
    Regs.X[I] := State.x[I];
  Regs.X[29] := State.fp;
  Regs.X[30] := State.lr;
  Regs.SP := State.sp;
  Regs.PC := State.pc;
  Regs.PSTATE := State.cpsr;
  Result := True;
end;

function TMacOSMachAdapter.SetRegisters(const Regs: TRegisters): Boolean;
var
  KR: kern_return_t;
  Count: mach_msg_type_number_t;
  State: arm_thread_state64_t;
  I: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  { Read first so the flags word is preserved }
  FillChar(State, SizeOf(State), 0);
  Count := ARM_THREAD_STATE64_COUNT;
  thread_get_state(FThreadPort, ARM_THREAD_STATE64, @State, Count);

  for I := 0 to 28 do
    State.x[I] := Regs.X[I];
  State.fp := Regs.X[29];
  State.lr := Regs.X[30];
  State.sp := Regs.SP;
  State.pc := Regs.PC;
  State.cpsr := Cardinal(Regs.PSTATE);

  KR := thread_set_state(FThreadPort, ARM_THREAD_STATE64, @State,
                         ARM_THREAD_STATE64_COUNT);
  if KR <> KERN_SUCCESS then
  begin
    WriteLn(StdErr, '[ERROR] Failed to set thread state (kern_return=', KR, ')');
    Exit;
  end;

  Result := True;
end;

{ Breakpoint management }

function TMacOSMachAdapter.HandleBreakpointHit: Boolean;
var
  Regs: TRegisters;
  Idx: Integer;
begin
  Result := False;

  if not GetRegisters(Regs) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to get registers after breakpoint');
    Exit;
  end;

  { BRK leaves PC on the BRK itself — nothing to rewind }
  FLastBreakpointAddr := Regs.PC;
  FLastBreakpointRBP := Regs.X[29];

  Idx := FindBreakpoint(Regs.PC);
  if (Idx < 0) or not FBreakpoints[Idx].Active then
  begin
    { A trap pdr did not plant (a BRK compiled into the program).  Step past
      it, or every resume would re-execute it. }
    WriteLn(StdErr, '[WARN] Breakpoint hit at unknown address: 0x', IntToHex(Regs.PC, 16));
    Regs.PC := Regs.PC + 4;
    SetRegisters(Regs);
    Exit(True);
  end;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Hit breakpoint at 0x', IntToHex(Regs.PC, 16));
  Result := True;
end;

function TMacOSMachAdapter.FindBreakpoint(Address: QWord): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FBreakpoints) do
    if FBreakpoints[I].Address = Address then
      Exit(I);
end;

function TMacOSMachAdapter.SetBreakpoint(Address: QWord): Boolean;
var
  OrigInsn, Trap: Cardinal;
  Idx: Integer;
  BpInfo: TBreakpointInfo;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  if (Address and 3) <> 0 then
  begin
    WriteLn(StdErr, '[ERROR] Breakpoint address $', IntToHex(Address, 16),
            ' is not 4-byte aligned');
    Exit;
  end;

  Trap := BRK_INSN;
  Idx := FindBreakpoint(Address);
  if Idx >= 0 then
  begin
    if FBreakpoints[Idx].Active then
    begin
      WriteLn(StdErr, '[WARN] Breakpoint already set at $', IntToHex(Address, 16));
      Exit(True);
    end;
    if not WriteMemory(Address, 4, Trap) then
    begin
      WriteLn(StdErr, '[ERROR] Failed to reactivate breakpoint');
      Exit(False);
    end;
    FBreakpoints[Idx].Active := True;
    if gVerbose then
      WriteLn(StdErr, '[INFO] Reactivated breakpoint at $', IntToHex(Address, 16));
    Exit(True);
  end;

  if not ReadMemory(Address, 4, OrigInsn) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to read memory for breakpoint');
    Exit;
  end;

  BpInfo.Address := Address;
  BpInfo.OriginalByte := Byte(OrigInsn);
  BpInfo.OriginalInsn := OrigInsn;
  BpInfo.Active := True;

  if not WriteMemory(Address, 4, Trap) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to set breakpoint');
    Exit;
  end;

  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := BpInfo;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Breakpoint set at $', IntToHex(Address, 16));
  Result := True;
end;

function TMacOSMachAdapter.RemoveBreakpoint(Address: QWord): Boolean;
var
  Idx: Integer;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  Idx := FindBreakpoint(Address);
  if Idx < 0 then
  begin
    WriteLn(StdErr, '[ERROR] No breakpoint found at $', IntToHex(Address, 16));
    Exit;
  end;

  if not FBreakpoints[Idx].Active then
  begin
    WriteLn(StdErr, '[WARN] Breakpoint at $', IntToHex(Address, 16), ' already removed');
    Exit(True);
  end;

  if not WriteMemory(Address, 4, FBreakpoints[Idx].OriginalInsn) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to remove breakpoint');
    Exit;
  end;

  FBreakpoints[Idx].Active := False;

  if gVerbose then
    WriteLn(StdErr, '[INFO] Breakpoint removed from $', IntToHex(Address, 16));
  Result := True;
end;

function TMacOSMachAdapter.GetCurrentAddress: QWord;
var
  Regs: TRegisters;
begin
  Result := 0;
  if not FAttached then Exit;
  if GetRegisters(Regs) then
    Result := Regs.PC;
end;

function TMacOSMachAdapter.GetFrameBasePointer: QWord;
var
  Regs: TRegisters;
begin
  Result := 0;
  if not FAttached then Exit;
  if GetRegisters(Regs) then
    Result := Regs.X[29];
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
    WriteLn(StdErr, '[INFO] Set command-line arguments: ', String.Join(' ', Args));

  Result := True;
end;

{ Hardware watchpoints: DBGWVR<n>/DBGWCR<n> through ARM_DEBUG_STATE64 }

function TMacOSMachAdapter.ReadDebugState(out State): Boolean;
var
  Count: mach_msg_type_number_t;
begin
  FillChar(State, SizeOf(arm_debug_state64_t), 0);
  Count := ARM_DEBUG_STATE64_COUNT;
  Result := thread_get_state(FThreadPort, ARM_DEBUG_STATE64, @State, Count) = KERN_SUCCESS;
end;

function TMacOSMachAdapter.WriteDebugState(const State): Boolean;
begin
  Result := thread_set_state(FThreadPort, ARM_DEBUG_STATE64, @State,
                             ARM_DEBUG_STATE64_COUNT) = KERN_SUCCESS;
end;

{ Rebuild the watchpoint registers from FWatchSlots, the authoritative
  copy: the thread's debug state does not survive a PT_STEP.  Armed=False
  leaves every slot programmed but disabled. }
function TMacOSMachAdapter.ApplyWatchpoints(Armed: Boolean): Boolean;
var
  State: arm_debug_state64_t;
  I: Integer;
  AnyActive: Boolean;
begin
  AnyActive := False;
  for I := 0 to 3 do
    AnyActive := AnyActive or FWatchSlots[I].Active;
  if not AnyActive then
    Exit(True);

  if not ReadDebugState(State) then
    Exit(False);
  for I := 0 to 3 do
    if FWatchSlots[I].Active then
    begin
      State.wvr[I] := FWatchSlots[I].Address and not QWord(7);
      if Armed then
        State.wcr[I] := FWatchSlots[I].Control
      else
        State.wcr[I] := FWatchSlots[I].Control and not QWord(WCR_ENABLE);
    end
    else
    begin
      State.wvr[I] := 0;
      State.wcr[I] := 0;
    end;
  Result := WriteDebugState(State);
end;

function TMacOSMachAdapter.SetWatchpoint(Address: QWord; Size: Byte;
  WatchType: TWatchpointType): Integer;
var
  Slot, I: Integer;
  ByteSelect, Lsc: QWord;
begin
  Result := -1;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] Not attached to any process');
    Exit;
  end;

  Slot := -1;
  for I := 0 to 3 do
    if not FWatchSlots[I].Active then
    begin
      Slot := I;
      Break;
    end;

  if Slot = -1 then
  begin
    WriteLn(StdErr, '[ERROR] All 4 hardware watchpoint slots are in use');
    Exit;
  end;

  if not (Size in [1, 2, 4, 8]) then
  begin
    WriteLn(StdErr, '[ERROR] Unsupported watchpoint size: ', Size);
    Exit;
  end;

  { One watchpoint covers bytes of a single aligned doubleword: DBGWVR holds
    the doubleword address, BAS selects the watched bytes within it }
  if (Address and 7) + Size > 8 then
  begin
    WriteLn(StdErr, '[ERROR] Watchpoint at $', IntToHex(Address, 16), ' size ', Size,
            ' crosses an 8-byte boundary');
    Exit;
  end;
  ByteSelect := ((QWord(1) shl Size) - 1) shl (Address and 7);

  case WatchType of
    wtWrite:     Lsc := WCR_LSC_STORE;
    wtReadWrite: Lsc := WCR_LSC_RW;
  end;

  FWatchSlots[Slot].Address := Address;
  FWatchSlots[Slot].Size := Size;
  FWatchSlots[Slot].Control := (ByteSelect shl 5) or Lsc or WCR_PAC_EL0 or WCR_ENABLE;
  FWatchSlots[Slot].Active := True;

  if not ApplyWatchpoints(True) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to write debug registers');
    FWatchSlots[Slot].Active := False;
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[DEBUG] Watchpoint set in slot ', Slot,
            ' at 0x', IntToHex(Address, 16), ' size=', Size);

  Result := Slot;
end;

function TMacOSMachAdapter.ClearWatchpoint(Slot: Integer): Boolean;
var
  State: arm_debug_state64_t;
begin
  Result := False;

  if (Slot < 0) or (Slot > 3) then
  begin
    WriteLn(StdErr, '[ERROR] Invalid watchpoint slot: ', Slot);
    Exit;
  end;

  if not FWatchSlots[Slot].Active then
  begin
    if gVerbose then WriteLn(StdErr, '[INFO] Watchpoint slot ', Slot, ' already inactive');
    Exit(True);
  end;

  FWatchSlots[Slot].Active := False;

  if not ReadDebugState(State) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to read debug registers');
    Exit;
  end;

  State.wvr[Slot] := 0;
  State.wcr[Slot] := 0;

  if not WriteDebugState(State) then
  begin
    WriteLn(StdErr, '[ERROR] Failed to write debug registers');
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[DEBUG] Watchpoint slot ', Slot, ' cleared');

  Result := True;
end;

function TMacOSMachAdapter.GetFiredWatchpoint: Integer;
begin
  Result := FLastFiredWatchpoint;
end;

{ Method call injection.  AAPCS64: Self in X0, the managed-result buffer
  (FPC-style sret) in X1, ordinal/pointer result back in X0.  The return
  address goes in LR: it points at a BRK sentinel planted at the current PC. }
function TMacOSMachAdapter.InjectCall(MethodAddr, SelfPtr: QWord;
  ManagedReturn: Boolean; out RetValue: QWord): Boolean;
const
  MAX_ITERATIONS = 1000;  { Safety limit against infinite loops }
  RED_ZONE = 128;         { Darwin arm64 leaf red zone below SP }
var
  SavedRegs, NewRegs, RetRegs: TRegisters;
  SentinelAddr: QWord;
  OrigInsn, Trap: Cardinal;
  NewSP, ResultBufAddr: QWord;
  ZeroBuf: QWord;
  Status: cInt;
  Iterations: Integer;
  BpIdx: Integer;
begin
  Result := False;
  RetValue := 0;

  if not FAttached then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: not attached to any process');
    Exit;
  end;

  if not GetRegisters(SavedRegs) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to save registers');
    Exit;
  end;

  SentinelAddr := SavedRegs.PC;
  if not ReadMemory(SentinelAddr, 4, OrigInsn) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to read memory at sentinel');
    Exit;
  end;

  Trap := BRK_INSN;
  if not WriteMemory(SentinelAddr, 4, Trap) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to write BRK sentinel');
    Exit;
  end;

  NewSP := (SavedRegs.SP - RED_ZONE) and not QWord(15);

  ResultBufAddr := 0;
  if ManagedReturn then
  begin
    NewSP := NewSP - 16;
    ResultBufAddr := NewSP;
    ZeroBuf := 0;
    if not WriteMemory(ResultBufAddr, 8, ZeroBuf) then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: failed to zero result buffer');
      WriteMemory(SentinelAddr, 4, OrigInsn);
      Exit;
    end;
  end;

  NewRegs := SavedRegs;
  NewRegs.PC := MethodAddr;
  NewRegs.SP := NewSP;
  NewRegs.X[30] := SentinelAddr;
  NewRegs.X[0] := SelfPtr;
  if ManagedReturn then
    NewRegs.X[1] := ResultBufAddr;

  if not SetRegisters(NewRegs) then
  begin
    WriteLn(StdErr, '[ERROR] InjectCall: failed to set registers');
    WriteMemory(SentinelAddr, 4, OrigInsn);
    Exit;
  end;

  if gVerbose then
    WriteLn(StdErr, '[DEBUG] InjectCall: calling $', IntToHex(MethodAddr, 16),
            ' Self=$', IntToHex(SelfPtr, 16),
            ' SP=$', IntToHex(NewSP, 16));

  Iterations := 0;
  repeat
    if ptrace(PT_CONTINUE, FPID, Pointer(1), 0) <> 0 then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: failed to continue');
      Break;
    end;

    if FpWaitPid(FPID, @Status, 0) = -1 then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: failed to wait');
      Break;
    end;

    if WIFEXITED(Status) or WIFSIGNALED(Status) then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: process terminated during injection');
      MarkDetached;
      Exit;
    end;

    if not WIFSTOPPED(Status) then
      Break;

    if WSTOPSIG(Status) <> SIGTRAP then
    begin
      WriteLn(StdErr, '[ERROR] InjectCall: ', SignalName(WSTOPSIG(Status)),
              ' during injected call');
      Break;
    end;

    if not GetRegisters(RetRegs) then
      Break;

    if RetRegs.PC = SentinelAddr then
    begin
      RetValue := RetRegs.X[0];
      if ManagedReturn then
        RetValue := ResultBufAddr;
      Result := True;
      Break;
    end;

    { A user breakpoint inside the injected call: execute the original
      instruction under it and carry on }
    BpIdx := FindBreakpoint(RetRegs.PC);
    if (BpIdx >= 0) and FBreakpoints[BpIdx].Active then
    begin
      if gVerbose then
        WriteLn(StdErr, '[DEBUG] InjectCall: hit user breakpoint at $',
                IntToHex(RetRegs.PC, 16), ' — stepping past');
      WriteMemory(RetRegs.PC, 4, FBreakpoints[BpIdx].OriginalInsn);
      if not RawStep(Status) or not FAttached then
        Break;
      WriteMemory(FBreakpoints[BpIdx].Address, 4, Trap);
    end
    else
    begin
      if gVerbose then
        WriteLn(StdErr, '[DEBUG] InjectCall: unexpected stop at $',
                IntToHex(RetRegs.PC, 16));
      Break;
    end;

    Inc(Iterations);
  until Iterations >= MAX_ITERATIONS;

  if Iterations >= MAX_ITERATIONS then
    WriteLn(StdErr, '[ERROR] InjectCall: timeout — iteration limit reached');

  if not FAttached then
    Exit;  { the process died during the call — nothing to restore }

  WriteMemory(SentinelAddr, 4, OrigInsn);
  SetRegisters(SavedRegs);

  if gVerbose and Result then
    WriteLn(StdErr, '[DEBUG] InjectCall: completed, RetValue=$', IntToHex(RetValue, 16));
end;

function TMacOSMachAdapter.SendInterrupt: Boolean;
begin
  Result := False;
  if (FPID <= 0) or (not FAttached) then
    Exit;
  FpKill(FPID, SIGSTOP);
  Result := True;
end;

{ The ASLR slide of the main executable: the runtime address of its Mach-O
  header minus the link-time __TEXT vmaddr.  That is the amount to add to
  every link-time (OPDF) address — what the engine's SetSlide expects, and
  what ELF's load base is for a PIE linked at 0.  The header is found by
  walking the task's regions for the MH_EXECUTE image; its in-memory load
  commands give the unslid __TEXT vmaddr. }
function TMacOSMachAdapter.GetLoadBase(const BinaryPath: String): QWord;
var
  Addr: mach_vm_address_t;
  Size: mach_vm_size_t;
  Info: vm_region_basic_info_64_t;
  InfoCount: mach_msg_type_number_t;
  ObjName: mach_port_t;
  Hdr: mach_header_64_t;
  Seg: segment_command_64_t;
  CmdAddr: QWord;
  I: Integer;
  OutSize: mach_vm_size_t;
begin
  Result := 0;
  if not FAttached then
    Exit;

  Addr := 0;
  while True do
  begin
    Size := 0;
    InfoCount := VM_REGION_BASIC_INFO_COUNT_64;
    if mach_vm_region(FTaskPort, Addr, Size, VM_REGION_BASIC_INFO_64,
                      @Info, InfoCount, ObjName) <> KERN_SUCCESS then
      Exit;

    if (mach_vm_read_overwrite(FTaskPort, Addr, SizeOf(Hdr),
          mach_vm_address_t(@Hdr), OutSize) = KERN_SUCCESS) and
       (Hdr.magic = MH_MAGIC_64) and (Hdr.filetype = MH_EXECUTE) then
      Break;

    Addr := Addr + Size;
  end;

  CmdAddr := Addr + SizeOf(Hdr);
  for I := 1 to Hdr.ncmds do
  begin
    if mach_vm_read_overwrite(FTaskPort, CmdAddr, SizeOf(Seg),
         mach_vm_address_t(@Seg), OutSize) <> KERN_SUCCESS then
      Exit;
    if (Seg.cmd = LC_SEGMENT_64) and (StrPas(PChar(@Seg.segname[0])) = '__TEXT') then
    begin
      Result := Addr - Seg.vmaddr;
      if gVerbose then
        WriteLn(StdErr, '[DEBUG] Mach-O header at $', IntToHex(Addr, 16),
                ', __TEXT vmaddr $', IntToHex(Seg.vmaddr, 16),
                ', slide $', IntToHex(Result, 16));
      Exit;
    end;
    CmdAddr := CmdAddr + Seg.cmdsize;
  end;
end;

function TMacOSMachAdapter.GetTLSBase: QWord;
begin
  { The thread pointer (TPIDRRO_EL0) is not part of ARM_THREAD_STATE64, and
    Darwin threadvars are TLV descriptors rather than a fixed TLS block —
    not supported yet. }
  Result := 0;
end;

{$ELSE} { neither x86 nor AArch64 }

const
  SNotSupported = 'Debugging is not supported on this CPU (' +
    {$I %FPCTARGETCPU%} + '-darwin); the macOS adapter supports x86_64, i386 and aarch64';

{ TMacOSMachAdapter }

constructor TMacOSMachAdapter.Create;
begin
  inherited Create;
  FPID := -1;
  FAttached := False;
  FLastFiredWatchpoint := -1;
end;

destructor TMacOSMachAdapter.Destroy;
begin
  inherited Destroy;
end;

function TMacOSMachAdapter.FindBreakpoint(Address: QWord): Integer;
begin
  Result := -1;
end;

function TMacOSMachAdapter.HandleBreakpointHit: Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.GetMainThread: Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.SetupExceptionPort: Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.WaitForException(out ExcType: Integer): Boolean;
begin
  ExcType := 0;
  Result := False;
end;

function TMacOSMachAdapter.ReplyToException(ExcType: Integer): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.Launch(const BinaryPath: String): Boolean;
begin
  WriteLn(StdErr, '[ERROR] ', SNotSupported);
  Result := False;
end;

function TMacOSMachAdapter.Attach(PID: Integer): Boolean;
begin
  WriteLn(StdErr, '[ERROR] ', SNotSupported);
  Result := False;
end;

function TMacOSMachAdapter.Detach: Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.Continue: Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.Step: Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.ReadMemory(Address: QWord; Size: Cardinal;
  out Buffer): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.WriteMemory(Address: QWord; Size: Cardinal;
  const Buffer): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.GetRegisters(out Regs: TRegisters): Boolean;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  Result := False;
end;

function TMacOSMachAdapter.SetRegisters(const Regs: TRegisters): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.SetBreakpoint(Address: QWord): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.RemoveBreakpoint(Address: QWord): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.GetCurrentAddress: QWord;
begin
  Result := 0;
end;

function TMacOSMachAdapter.GetFrameBasePointer: QWord;
begin
  Result := 0;
end;

function TMacOSMachAdapter.GetLastBreakpointAddress: QWord;
begin
  Result := 0;
end;

function TMacOSMachAdapter.GetLastBreakpointRBP: QWord;
begin
  Result := 0;
end;

function TMacOSMachAdapter.SetCommandLineArgs(const Args: array of String): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.SetWatchpoint(Address: QWord; Size: Byte;
  WatchType: TWatchpointType): Integer;
begin
  Result := -1;
end;

function TMacOSMachAdapter.ClearWatchpoint(Slot: Integer): Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.GetFiredWatchpoint: Integer;
begin
  Result := -1;
end;

function TMacOSMachAdapter.InjectCall(MethodAddr, SelfPtr: QWord;
  ManagedReturn: Boolean; out RetValue: QWord): Boolean;
begin
  RetValue := 0;
  Result := False;
end;

function TMacOSMachAdapter.SendInterrupt: Boolean;
begin
  Result := False;
end;

function TMacOSMachAdapter.GetLoadBase(const BinaryPath: String): QWord;
begin
  Result := 0;
end;

function TMacOSMachAdapter.GetTLSBase: QWord;
begin
  Result := 0;
end;

{$IFEND} { CPU }

{$ENDIF} { DARWIN }

end.
