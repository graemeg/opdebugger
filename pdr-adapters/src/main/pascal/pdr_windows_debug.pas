{
  PDR Debugger - Windows Debug API Adapter

  Copyright (c) 2025-2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Platform-specific process control implementation for Windows using the
  Windows Debug API (CreateProcess/DEBUG_PROCESS, WaitForDebugEvent,
  ReadProcessMemory/WriteProcessMemory, GetThreadContext/SetThreadContext).

  NOTE: This implementation is currently UNTESTED. It has been written based
  on Microsoft Win32 API documentation. Issues will be addressed once Blaise
  supports Windows as a compilation target.
}
unit pdr_windows_debug;

{$mode objfpc}{$H+}

interface

{$IFDEF WINDOWS}

uses
  SysUtils, Windows, pdr_ports;

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

  TWindowsDebugAdapter = class(TInterfacedObject, IProcessController)
  private
    FProcessInfo: TProcessInformation;
    FAttached: Boolean;
    FBreakpoints: array of TBreakpointInfo;
    FLastBreakpointAddr: QWord;
    FLastBreakpointRBP: QWord;
    FCommandLineArgs: array of String;
    FWatchSlots: array[0..3] of TWatchSlotInfo;
    FLastFiredWatchpoint: Integer;
    FMainThreadHandle: THandle;
    FProcessHandle: THandle;
    FProcessID: DWORD;
    FInitialBreakpointHit: Boolean;

    function FindBreakpoint(Address: QWord): Integer;
    function HandleBreakpointHit(ThreadHandle: THandle): Boolean;
    procedure UpdateDebugRegisters(ThreadHandle: THandle);
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

    property IsAttached: Boolean read FAttached;
  end;

{$ENDIF}

implementation

{$IFDEF WINDOWS}

const
  { Debug event constants }
  EXCEPTION_DEBUG_EVENT      = 1;
  CREATE_THREAD_DEBUG_EVENT  = 2;
  CREATE_PROCESS_DEBUG_EVENT = 3;
  EXIT_THREAD_DEBUG_EVENT    = 4;
  EXIT_PROCESS_DEBUG_EVENT   = 5;
  LOAD_DLL_DEBUG_EVENT       = 6;
  UNLOAD_DLL_DEBUG_EVENT     = 7;
  OUTPUT_DEBUG_STRING_EVENT  = 8;
  RIP_EVENT                  = 9;

  { Exception codes }
  STATUS_BREAKPOINT          = $80000003;
  STATUS_SINGLE_STEP         = $80000004;
  STATUS_ACCESS_VIOLATION    = $C0000005;
  STATUS_STACK_OVERFLOW      = $C00000FD;

  { Continue status }
  DBG_CONTINUE               = $00010002;
  DBG_EXCEPTION_NOT_HANDLED  = $80010001;

  { Context flags }
  {$IFDEF CPUX86_64}
  CONTEXT_AMD64              = $00100000;
  CONTEXT_CONTROL_FLAG       = CONTEXT_AMD64 or $00000001;
  CONTEXT_INTEGER_FLAG       = CONTEXT_AMD64 or $00000002;
  CONTEXT_DEBUG_REGISTERS_FLAG = CONTEXT_AMD64 or $00000010;
  CONTEXT_FULL_FLAG          = CONTEXT_CONTROL_FLAG or CONTEXT_INTEGER_FLAG;
  {$ENDIF}
  {$IFDEF CPUI386}
  CONTEXT_I386               = $00010000;
  CONTEXT_CONTROL_FLAG       = CONTEXT_I386 or $00000001;
  CONTEXT_INTEGER_FLAG       = CONTEXT_I386 or $00000002;
  CONTEXT_DEBUG_REGISTERS_FLAG = CONTEXT_I386 or $00000010;
  CONTEXT_FULL_FLAG          = CONTEXT_CONTROL_FLAG or CONTEXT_INTEGER_FLAG;
  {$ENDIF}

  { Thread access rights }
  THREAD_GET_CONTEXT         = $0008;
  THREAD_SET_CONTEXT         = $0010;
  THREAD_SUSPEND_RESUME      = $0002;
  THREAD_ALL_ACCESS          = $001FFFFF;

  { SingleStep trap flag }
  TRAP_FLAG                  = $00000100;

type
  {$IFDEF CPUX86_64}
  TWinContext = packed record
    P1Home: QWord;
    P2Home: QWord;
    P3Home: QWord;
    P4Home: QWord;
    P5Home: QWord;
    P6Home: QWord;
    ContextFlags: DWORD;
    MxCsr: DWORD;
    SegCs: Word;
    SegDs: Word;
    SegEs: Word;
    SegFs: Word;
    SegGs: Word;
    SegSs: Word;
    EFlags: DWORD;
    Dr0: QWord;
    Dr1: QWord;
    Dr2: QWord;
    Dr3: QWord;
    Dr6: QWord;
    Dr7: QWord;
    Rax: QWord;
    Rcx: QWord;
    Rdx: QWord;
    Rbx: QWord;
    Rsp: QWord;
    Rbp: QWord;
    Rsi: QWord;
    Rdi: QWord;
    R8: QWord;
    R9: QWord;
    R10: QWord;
    R11: QWord;
    R12: QWord;
    R13: QWord;
    R14: QWord;
    R15: QWord;
    Rip: QWord;
    FltSave: array[0..511] of Byte;
    VectorRegister: array[0..25] of array[0..15] of Byte;
    VectorControl: QWord;
    DebugControl: QWord;
    LastBranchToRip: QWord;
    LastBranchFromRip: QWord;
    LastExceptionToRip: QWord;
    LastExceptionFromRip: QWord;
  end;
  {$ENDIF}
  {$IFDEF CPUI386}
  TWinContext = packed record
    ContextFlags: DWORD;
    Dr0: DWORD;
    Dr1: DWORD;
    Dr2: DWORD;
    Dr3: DWORD;
    Dr6: DWORD;
    Dr7: DWORD;
    FloatSave: array[0..111] of Byte;
    SegGs: DWORD;
    SegFs: DWORD;
    SegEs: DWORD;
    SegDs: DWORD;
    Edi: DWORD;
    Esi: DWORD;
    Ebx: DWORD;
    Edx: DWORD;
    Ecx: DWORD;
    Eax: DWORD;
    Ebp: DWORD;
    Eip: DWORD;
    SegCs: DWORD;
    EFlags: DWORD;
    Esp: DWORD;
    SegSs: DWORD;
    ExtendedRegisters: array[0..511] of Byte;
  end;
  {$ENDIF}

{ Windows API declarations }
function DebugBreakProcess(Process: THandle): BOOL;
  stdcall; external 'kernel32.dll';
function DebugActiveProcess(dwProcessId: DWORD): BOOL;
  stdcall; external 'kernel32.dll';
function DebugActiveProcessStop(dwProcessId: DWORD): BOOL;
  stdcall; external 'kernel32.dll';

{ TWindowsDebugAdapter }

constructor TWindowsDebugAdapter.Create;
var
  I: Integer;
begin
  inherited Create;
  FillChar(FProcessInfo, SizeOf(FProcessInfo), 0);
  FAttached := False;
  FLastBreakpointAddr := 0;
  FLastBreakpointRBP := 0;
  FLastFiredWatchpoint := -1;
  FMainThreadHandle := 0;
  FProcessHandle := 0;
  FProcessID := 0;
  FInitialBreakpointHit := False;
  for I := 0 to 3 do
    FWatchSlots[I].Active := False;
end;

destructor TWindowsDebugAdapter.Destroy;
begin
  if FAttached then
    Detach;
  inherited Destroy;
end;

function TWindowsDebugAdapter.Launch(const BinaryPath: String): Boolean;
var
  StartupInfo: TStartupInfo;
  DebugEvent: TDebugEvent;
  CommandLine: String;
  I: Integer;
begin
  Result := False;

  if FAttached then
  begin
    WriteLn('[ERROR] Already attached to a process');
    Exit;
  end;

  if not FileExists(BinaryPath) then
  begin
    WriteLn('[ERROR] Binary file not found: ', BinaryPath);
    Exit;
  end;

  if gVerbose then
    WriteLn('[INFO] Launching program: ', BinaryPath);

  FillChar(StartupInfo, SizeOf(StartupInfo), 0);
  StartupInfo.cb := SizeOf(StartupInfo);
  FillChar(FProcessInfo, SizeOf(FProcessInfo), 0);

  CommandLine := '"' + BinaryPath + '"';
  for I := 0 to High(FCommandLineArgs) do
    CommandLine := CommandLine + ' ' + FCommandLineArgs[I];

  if not CreateProcess(
    PChar(BinaryPath),
    PChar(CommandLine),
    nil,
    nil,
    False,
    DEBUG_PROCESS or DEBUG_ONLY_THIS_PROCESS or CREATE_NEW_PROCESS_GROUP,
    nil,
    nil,
    StartupInfo,
    FProcessInfo) then
  begin
    WriteLn('[ERROR] Failed to create process: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  FProcessHandle := FProcessInfo.hProcess;
  FMainThreadHandle := FProcessInfo.hThread;
  FProcessID := FProcessInfo.dwProcessId;
  FAttached := True;
  FInitialBreakpointHit := False;

  { Wait for the initial debug events (CREATE_PROCESS, initial breakpoint) }
  while not FInitialBreakpointHit do
  begin
    if not WaitForDebugEvent(DebugEvent, INFINITE) then
    begin
      WriteLn('[ERROR] WaitForDebugEvent failed: ', SysErrorMessage(GetLastError));
      FAttached := False;
      Exit;
    end;

    case DebugEvent.dwDebugEventCode of
      CREATE_PROCESS_DEBUG_EVENT:
      begin
        if gVerbose then
          WriteLn('[INFO] Process created, PID=', FProcessID);
        { Close the image file handle returned by the event }
        if DebugEvent.CreateProcessInfo.hFile <> 0 then
          CloseHandle(DebugEvent.CreateProcessInfo.hFile);
        ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
      end;
      EXCEPTION_DEBUG_EVENT:
      begin
        if DebugEvent.Exception.ExceptionRecord.ExceptionCode = STATUS_BREAKPOINT then
        begin
          FInitialBreakpointHit := True;
          { Do NOT continue — leave the process paused at the entry point }
          ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
          if gVerbose then
          begin
            WriteLn('[INFO] Child process stopped at entry point');
            WriteLn('[INFO] Debugger has control (process is paused)');
          end;
        end
        else
          ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId,
                             DBG_EXCEPTION_NOT_HANDLED);
      end;
      LOAD_DLL_DEBUG_EVENT:
      begin
        if DebugEvent.LoadDll.hFile <> 0 then
          CloseHandle(DebugEvent.LoadDll.hFile);
        ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
      end;
    else
      ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
    end;
  end;

  Result := True;
end;

function TWindowsDebugAdapter.Attach(PID: Integer): Boolean;
begin
  Result := False;

  if FAttached then
  begin
    WriteLn('[ERROR] Already attached to a process');
    Exit;
  end;

  if not DebugActiveProcess(DWORD(PID)) then
  begin
    WriteLn('[ERROR] Failed to attach to process ', PID, ': ',
            SysErrorMessage(GetLastError));
    Exit;
  end;

  { Open the process handle for memory access }
  FProcessHandle := OpenProcess(PROCESS_ALL_ACCESS, False, DWORD(PID));
  if FProcessHandle = 0 then
  begin
    WriteLn('[ERROR] Failed to open process handle: ', SysErrorMessage(GetLastError));
    DebugActiveProcessStop(DWORD(PID));
    Exit;
  end;

  FProcessID := DWORD(PID);
  FAttached := True;
  FInitialBreakpointHit := False;
  WriteLn('[INFO] Successfully attached to PID ', PID);
  Result := True;
end;

function TWindowsDebugAdapter.Detach: Boolean;
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

  if not DebugActiveProcessStop(FProcessID) then
  begin
    WriteLn('[ERROR] Failed to detach from process: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  if FProcessHandle <> 0 then
    CloseHandle(FProcessHandle);
  if FMainThreadHandle <> 0 then
    CloseHandle(FMainThreadHandle);

  if gVerbose then
    WriteLn('[INFO] Detached from PID ', FProcessID);

  FAttached := False;
  FProcessHandle := 0;
  FMainThreadHandle := 0;
  FProcessID := 0;
  Result := True;
end;

function TWindowsDebugAdapter.Continue: Boolean;
var
  DebugEvent: TDebugEvent;
  ContinueStatus: DWORD;
  ExCode: DWORD;
  WatchSlot: Integer;
  Ctx: TWinContext;
begin
  Result := False;
  FLastFiredWatchpoint := -1;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  { Resume the process by entering the debug event loop }
  ContinueDebugEvent(FProcessID, 0, DBG_CONTINUE);

  while True do
  begin
    if not WaitForDebugEvent(DebugEvent, INFINITE) then
    begin
      WriteLn('[ERROR] WaitForDebugEvent failed: ', SysErrorMessage(GetLastError));
      Exit;
    end;

    case DebugEvent.dwDebugEventCode of
      EXCEPTION_DEBUG_EVENT:
      begin
        ExCode := DebugEvent.Exception.ExceptionRecord.ExceptionCode;

        if ExCode = STATUS_BREAKPOINT then
        begin
          if not HandleBreakpointHit(FMainThreadHandle) then
          begin
            WriteLn('[ERROR] Failed to handle breakpoint');
            ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
            Exit;
          end;
          ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
          Result := True;
          Exit;
        end
        else if ExCode = STATUS_SINGLE_STEP then
        begin
          { Check if it was a watchpoint (DR6) }
          FillChar(Ctx, SizeOf(Ctx), 0);
          Ctx.ContextFlags := CONTEXT_DEBUG_REGISTERS_FLAG;
          if GetThreadContext(FMainThreadHandle, Ctx) then
          begin
            if (Ctx.Dr6 and $F) <> 0 then
            begin
              WatchSlot := -1;
              if (Ctx.Dr6 and 1) <> 0 then WatchSlot := 0
              else if (Ctx.Dr6 and 2) <> 0 then WatchSlot := 1
              else if (Ctx.Dr6 and 4) <> 0 then WatchSlot := 2
              else if (Ctx.Dr6 and 8) <> 0 then WatchSlot := 3;
              FLastFiredWatchpoint := WatchSlot;

              { Clear DR6 }
              Ctx.Dr6 := 0;
              SetThreadContext(FMainThreadHandle, Ctx);

              if gVerbose then
                WriteLn('[DEBUG] Hardware watchpoint hit: slot ', WatchSlot);

              ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
              Result := True;
              Exit;
            end;
          end;

          { Regular single-step — shouldn't happen during continue, but handle it }
          ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
          Result := True;
          Exit;
        end
        else if (ExCode = STATUS_ACCESS_VIOLATION) or
                (ExCode = STATUS_STACK_OVERFLOW) then
        begin
          WriteLn('[INFO] Process received exception $', IntToHex(ExCode, 8));
          ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId,
                             DBG_EXCEPTION_NOT_HANDLED);
          Result := True;
          Exit;
        end
        else
        begin
          { First-chance exception — pass to application }
          if DebugEvent.Exception.dwFirstChance <> 0 then
            ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId,
                               DBG_EXCEPTION_NOT_HANDLED)
          else
          begin
            WriteLn('[INFO] Unhandled exception $', IntToHex(ExCode, 8));
            ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId,
                               DBG_EXCEPTION_NOT_HANDLED);
            Result := True;
            Exit;
          end;
        end;
      end;
      EXIT_PROCESS_DEBUG_EVENT:
      begin
        WriteLn('[INFO] Process exited with code ',
                DebugEvent.ExitProcess.dwExitCode);
        ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
        FAttached := False;
        FProcessHandle := 0;
        FMainThreadHandle := 0;
        FProcessID := 0;
        Result := True;
        Exit;
      end;
      LOAD_DLL_DEBUG_EVENT:
      begin
        if DebugEvent.LoadDll.hFile <> 0 then
          CloseHandle(DebugEvent.LoadDll.hFile);
        ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
      end;
    else
      ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
    end;
  end;
end;

function TWindowsDebugAdapter.Step: Boolean;
var
  Ctx: TWinContext;
  DebugEvent: TDebugEvent;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  { Set the trap flag (TF) in EFLAGS to trigger single-step }
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.ContextFlags := CONTEXT_FULL_FLAG;
  if not GetThreadContext(FMainThreadHandle, Ctx) then
  begin
    WriteLn('[ERROR] Failed to get thread context for step: ',
            SysErrorMessage(GetLastError));
    Exit;
  end;

  Ctx.EFlags := Ctx.EFlags or TRAP_FLAG;

  if not SetThreadContext(FMainThreadHandle, Ctx) then
  begin
    WriteLn('[ERROR] Failed to set trap flag: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  { Continue and wait for the single-step exception }
  ContinueDebugEvent(FProcessID, 0, DBG_CONTINUE);

  while True do
  begin
    if not WaitForDebugEvent(DebugEvent, INFINITE) then
    begin
      WriteLn('[ERROR] WaitForDebugEvent failed during step: ',
              SysErrorMessage(GetLastError));
      Exit;
    end;

    case DebugEvent.dwDebugEventCode of
      EXCEPTION_DEBUG_EVENT:
      begin
        if DebugEvent.Exception.ExceptionRecord.ExceptionCode = STATUS_SINGLE_STEP then
        begin
          if gVerbose then WriteLn('[INFO] Step complete');
          ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
          Result := True;
          Exit;
        end
        else
        begin
          ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId,
                             DBG_EXCEPTION_NOT_HANDLED);
        end;
      end;
      EXIT_PROCESS_DEBUG_EVENT:
      begin
        WriteLn('[INFO] Process exited during step with code ',
                DebugEvent.ExitProcess.dwExitCode);
        ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
        FAttached := False;
        FProcessHandle := 0;
        FMainThreadHandle := 0;
        FProcessID := 0;
        Result := True;
        Exit;
      end;
    else
      ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
    end;
  end;
end;

function TWindowsDebugAdapter.ReadMemory(Address: QWord; Size: Cardinal;
  out Buffer): Boolean;
var
  BytesRead: {$IFDEF CPUX86_64}QWord{$ELSE}DWORD{$ENDIF};
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  if not ReadProcessMemory(FProcessHandle, Pointer(PtrUInt(Address)),
                           @Buffer, Size, BytesRead) then
  begin
    WriteLn('[ERROR] Failed to read memory at $', IntToHex(Address, 16),
            ': ', SysErrorMessage(GetLastError));
    Exit;
  end;

  Result := True;
end;

function TWindowsDebugAdapter.WriteMemory(Address: QWord; Size: Cardinal;
  const Buffer): Boolean;
var
  BytesWritten: {$IFDEF CPUX86_64}QWord{$ELSE}DWORD{$ENDIF};
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  if not WriteProcessMemory(FProcessHandle, Pointer(PtrUInt(Address)),
                            @Buffer, Size, BytesWritten) then
  begin
    WriteLn('[ERROR] Failed to write memory at $', IntToHex(Address, 16),
            ': ', SysErrorMessage(GetLastError));
    Exit;
  end;

  { Flush instruction cache in case we wrote to code }
  FlushInstructionCache(FProcessHandle, Pointer(PtrUInt(Address)), Size);

  Result := True;
end;

function TWindowsDebugAdapter.GetRegisters(out Regs: TRegisters): Boolean;
var
  Ctx: TWinContext;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.ContextFlags := CONTEXT_FULL_FLAG;

  if not GetThreadContext(FMainThreadHandle, Ctx) then
  begin
    WriteLn('[ERROR] Failed to get thread context: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  {$IFDEF CPUX86_64}
  Regs.RAX := Ctx.Rax;
  Regs.RBX := Ctx.Rbx;
  Regs.RCX := Ctx.Rcx;
  Regs.RDX := Ctx.Rdx;
  Regs.RSI := Ctx.Rsi;
  Regs.RDI := Ctx.Rdi;
  Regs.RBP := Ctx.Rbp;
  Regs.RSP := Ctx.Rsp;
  Regs.R8 := Ctx.R8;
  Regs.R9 := Ctx.R9;
  Regs.R10 := Ctx.R10;
  Regs.R11 := Ctx.R11;
  Regs.R12 := Ctx.R12;
  Regs.R13 := Ctx.R13;
  Regs.R14 := Ctx.R14;
  Regs.R15 := Ctx.R15;
  Regs.RIP := Ctx.Rip;
  Regs.RFLAGS := Ctx.EFlags;
  {$ENDIF}

  {$IFDEF CPUI386}
  Regs.EAX := Ctx.Eax;
  Regs.EBX := Ctx.Ebx;
  Regs.ECX := Ctx.Ecx;
  Regs.EDX := Ctx.Edx;
  Regs.ESI := Ctx.Esi;
  Regs.EDI := Ctx.Edi;
  Regs.EBP := Ctx.Ebp;
  Regs.ESP := Ctx.Esp;
  Regs.EIP := Ctx.Eip;
  Regs.EFLAGS := Ctx.EFlags;
  {$ENDIF}

  Result := True;
end;

function TWindowsDebugAdapter.SetRegisters(const Regs: TRegisters): Boolean;
var
  Ctx: TWinContext;
begin
  Result := False;

  if not FAttached then
  begin
    WriteLn('[ERROR] Not attached to any process');
    Exit;
  end;

  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.ContextFlags := CONTEXT_FULL_FLAG;

  if not GetThreadContext(FMainThreadHandle, Ctx) then
  begin
    WriteLn('[ERROR] Failed to get current thread context: ',
            SysErrorMessage(GetLastError));
    Exit;
  end;

  {$IFDEF CPUX86_64}
  Ctx.Rax := Regs.RAX;
  Ctx.Rbx := Regs.RBX;
  Ctx.Rcx := Regs.RCX;
  Ctx.Rdx := Regs.RDX;
  Ctx.Rsi := Regs.RSI;
  Ctx.Rdi := Regs.RDI;
  Ctx.Rbp := Regs.RBP;
  Ctx.Rsp := Regs.RSP;
  Ctx.R8 := Regs.R8;
  Ctx.R9 := Regs.R9;
  Ctx.R10 := Regs.R10;
  Ctx.R11 := Regs.R11;
  Ctx.R12 := Regs.R12;
  Ctx.R13 := Regs.R13;
  Ctx.R14 := Regs.R14;
  Ctx.R15 := Regs.R15;
  Ctx.Rip := Regs.RIP;
  Ctx.EFlags := Regs.RFLAGS;
  {$ENDIF}

  {$IFDEF CPUI386}
  Ctx.Eax := Regs.EAX;
  Ctx.Ebx := Regs.EBX;
  Ctx.Ecx := Regs.ECX;
  Ctx.Edx := Regs.EDX;
  Ctx.Esi := Regs.ESI;
  Ctx.Edi := Regs.EDI;
  Ctx.Ebp := Regs.EBP;
  Ctx.Esp := Regs.ESP;
  Ctx.Eip := Regs.EIP;
  Ctx.EFlags := Regs.EFLAGS;
  {$ENDIF}

  if not SetThreadContext(FMainThreadHandle, Ctx) then
  begin
    WriteLn('[ERROR] Failed to set thread context: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  Result := True;
end;

function TWindowsDebugAdapter.HandleBreakpointHit(ThreadHandle: THandle): Boolean;
var
  Regs: TRegisters;
  BreakpointAddr: QWord;
  Idx: Integer;
  OrigByte: Byte;
  Ctx: TWinContext;
  DebugEvent: TDebugEvent;
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

  { Set trap flag for single-step }
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.ContextFlags := CONTEXT_FULL_FLAG;
  GetThreadContext(ThreadHandle, Ctx);
  Ctx.EFlags := Ctx.EFlags or TRAP_FLAG;
  SetThreadContext(ThreadHandle, Ctx);

  { Continue and wait for single-step }
  ContinueDebugEvent(FProcessID, 0, DBG_CONTINUE);

  if not WaitForDebugEvent(DebugEvent, 5000) then
  begin
    WriteLn('[ERROR] Timeout waiting for single-step after breakpoint');
    Exit;
  end;

  { Re-insert the breakpoint }
  OrigByte := $CC;
  if not WriteMemory(BreakpointAddr, 1, OrigByte) then
  begin
    WriteLn('[ERROR] Failed to re-insert breakpoint');
    Exit;
  end;

  Result := True;
end;

function TWindowsDebugAdapter.FindBreakpoint(Address: QWord): Integer;
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

function TWindowsDebugAdapter.SetBreakpoint(Address: QWord): Boolean;
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
        WriteLn('[ERROR] Failed to reactivate breakpoint: ', SysErrorMessage(GetLastError));
        Exit(False);
      end;
      FBreakpoints[Idx].Active := True;
      if gVerbose then
        WriteLn('[INFO] Reactivated breakpoint at $', IntToHex(Address, 16));
      Exit(True);
    end;
  end;

  { Read original byte }
  if not ReadMemory(Address, 1, OrigByte) then
  begin
    WriteLn('[ERROR] Failed to read memory for breakpoint: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  BpInfo.Address := Address;
  BpInfo.OriginalByte := OrigByte;
  BpInfo.Active := True;

  { Write INT3 }
  TrapByte := $CC;
  if not WriteMemory(Address, 1, TrapByte) then
  begin
    WriteLn('[ERROR] Failed to set breakpoint: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  SetLength(FBreakpoints, Length(FBreakpoints) + 1);
  FBreakpoints[High(FBreakpoints)] := BpInfo;

  if gVerbose then
    WriteLn('[INFO] Breakpoint set at $', IntToHex(Address, 16));
  Result := True;
end;

function TWindowsDebugAdapter.RemoveBreakpoint(Address: QWord): Boolean;
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
    WriteLn('[ERROR] Failed to remove breakpoint: ', SysErrorMessage(GetLastError));
    Exit;
  end;

  FBreakpoints[Idx].Active := False;

  if gVerbose then
    WriteLn('[INFO] Breakpoint removed from $', IntToHex(Address, 16));
  Result := True;
end;

function TWindowsDebugAdapter.GetCurrentAddress: QWord;
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

function TWindowsDebugAdapter.GetFrameBasePointer: QWord;
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

function TWindowsDebugAdapter.GetLastBreakpointAddress: QWord;
begin
  Result := FLastBreakpointAddr;
end;

function TWindowsDebugAdapter.GetLastBreakpointRBP: QWord;
begin
  Result := FLastBreakpointRBP;
end;

function TWindowsDebugAdapter.SetCommandLineArgs(const Args: array of String): Boolean;
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

{ Hardware watchpoints via debug registers in CONTEXT }

procedure TWindowsDebugAdapter.UpdateDebugRegisters(ThreadHandle: THandle);
var
  Ctx: TWinContext;
  I: Integer;
  DR7: QWord;
  CondCode, LenCode: QWord;
begin
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.ContextFlags := CONTEXT_DEBUG_REGISTERS_FLAG;

  if not GetThreadContext(ThreadHandle, Ctx) then
    Exit;

  DR7 := 0;

  for I := 0 to 3 do
  begin
    if FWatchSlots[I].Active then
    begin
      case I of
        0: Ctx.Dr0 := {$IFDEF CPUX86_64}FWatchSlots[I].Address{$ELSE}DWORD(FWatchSlots[I].Address){$ENDIF};
        1: Ctx.Dr1 := {$IFDEF CPUX86_64}FWatchSlots[I].Address{$ELSE}DWORD(FWatchSlots[I].Address){$ENDIF};
        2: Ctx.Dr2 := {$IFDEF CPUX86_64}FWatchSlots[I].Address{$ELSE}DWORD(FWatchSlots[I].Address){$ENDIF};
        3: Ctx.Dr3 := {$IFDEF CPUX86_64}FWatchSlots[I].Address{$ELSE}DWORD(FWatchSlots[I].Address){$ENDIF};
      end;

      { Enable local breakpoint for this slot }
      DR7 := DR7 or (QWord(1) shl (2 * I));

      { Condition: 01=write, 11=read/write }
      CondCode := 1; { Default: write-only }
      { Length encoding }
      case FWatchSlots[I].Size of
        1: LenCode := 0;
        2: LenCode := 1;
        4: LenCode := 3;
        8: LenCode := 2;
      else
        LenCode := 0;
      end;

      DR7 := DR7 or (CondCode shl (16 + 4 * I));
      DR7 := DR7 or (LenCode shl (18 + 4 * I));
    end;
  end;

  Ctx.Dr7 := {$IFDEF CPUX86_64}DR7{$ELSE}DWORD(DR7){$ENDIF};
  Ctx.Dr6 := 0;

  SetThreadContext(ThreadHandle, Ctx);
end;

function TWindowsDebugAdapter.SetWatchpoint(Address: QWord; Size: Byte;
  WatchType: TWatchpointType): Integer;
var
  Slot: Integer;
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
    1, 2, 4, 8: ;
  else
    WriteLn('[ERROR] Unsupported watchpoint size: ', Size, ' (must be 1, 2, 4, or 8)');
    Result := -1;
    Exit;
  end;

  FWatchSlots[Slot].Address := Address;
  FWatchSlots[Slot].Size := Size;
  FWatchSlots[Slot].Active := True;

  UpdateDebugRegisters(FMainThreadHandle);

  if gVerbose then
    WriteLn('[DEBUG] Watchpoint set in slot ', Slot,
            ' at 0x', IntToHex(Address, 16), ' size=', Size);

  Result := Slot;
end;

function TWindowsDebugAdapter.ClearWatchpoint(Slot: Integer): Boolean;
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

  FWatchSlots[Slot].Active := False;

  UpdateDebugRegisters(FMainThreadHandle);

  if gVerbose then
    WriteLn('[DEBUG] Watchpoint slot ', Slot, ' cleared');

  Result := True;
end;

function TWindowsDebugAdapter.GetFiredWatchpoint: Integer;
begin
  Result := FLastFiredWatchpoint;
end;

function TWindowsDebugAdapter.InjectCall(MethodAddr, SelfPtr: QWord;
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
  DebugEvent: TDebugEvent;
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

  { Windows x86_64 calling convention: RCX = first param (Self) }
  NewRegs := SavedRegs;
  NewRegs.RIP := MethodAddr;
  NewRegs.RSP := NewRSP;
  NewRegs.RCX := SelfPtr;
  if ManagedReturn then
    NewRegs.RDX := ResultBufAddr;

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
    ContinueDebugEvent(FProcessID, 0, DBG_CONTINUE);

    if not WaitForDebugEvent(DebugEvent, 10000) then
    begin
      WriteLn('[ERROR] InjectCall: timeout waiting for debug event');
      Break;
    end;

    if DebugEvent.dwDebugEventCode = EXIT_PROCESS_DEBUG_EVENT then
    begin
      WriteLn('[ERROR] InjectCall: process terminated during injection');
      FAttached := False;
      Exit;
    end;

    if DebugEvent.dwDebugEventCode <> EXCEPTION_DEBUG_EVENT then
    begin
      ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId, DBG_CONTINUE);
      Inc(Iterations);
      System.Continue;
    end;

    if DebugEvent.Exception.ExceptionRecord.ExceptionCode <> STATUS_BREAKPOINT then
    begin
      ContinueDebugEvent(FProcessID, DebugEvent.dwThreadId,
                         DBG_EXCEPTION_NOT_HANDLED);
      Inc(Iterations);
      System.Continue;
    end;

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
      Step;
      TrapByte := $CC;
      WriteMemory(StoppedAddr, 1, TrapByte);
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

function TWindowsDebugAdapter.SendInterrupt: Boolean;
begin
  Result := False;
  if (FProcessHandle = 0) or (not FAttached) then
    Exit;
  Result := DebugBreakProcess(FProcessHandle);
end;

{$ENDIF} { WINDOWS }

end.
