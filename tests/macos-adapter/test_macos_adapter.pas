{
  PDR Debugger - macOS AArch64 process-control adapter tests

  Copyright (c) 2026 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  Drives TMacOSMachAdapter directly against target.c (built with clang by
  run_tests.sh), so process control is tested without a Pascal compiler or
  OPDF.  Symbol addresses come from the Mach-O symbol table; the adapter's
  ASLR slide turns them into runtime addresses.

  Usage: test_macos_adapter <path-to-target>
}
program test_macos_adapter;

{$mode objfpc}{$H+}

uses
  SysUtils, pdr_ports, pdr_binary, pdr_macos_mach;

var
  Passed: Integer = 0;
  Failed: Integer = 0;

procedure Check(Condition: Boolean; const Msg: String);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('  PASS: ', Msg);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FAIL: ', Msg);
  end;
end;

procedure Section(const Title: String);
begin
  WriteLn;
  WriteLn('--- ', Title, ' ---');
end;

function ReadQWordAt(Adapter: TMacOSMachAdapter; Addr: QWord): QWord;
begin
  Result := QWord(-1);
  Adapter.ReadMemory(Addr, 8, Result);
end;

var
  TargetPath: String;
  Reader: IBinaryReader;
  Adapter: TMacOSMachAdapter;
  Ctrl: IProcessController;
  SymSetValues, SymCounter, SymGetAnswer: QWord;
  Slide, Bp, CounterAddr: QWord;
  Insn: Cardinal;
  Regs, Regs2: TRegisters;
  Slot: Integer;
  RetValue: QWord;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: test_macos_adapter <path-to-target>');
    Halt(2);
  end;
  TargetPath := ParamStr(1);

  Reader := CreateBinaryReader(TargetPath);
  if Reader = nil then
  begin
    WriteLn('Cannot read target binary: ', TargetPath);
    Halt(2);
  end;
  SymSetValues := Reader.FindSymbolAddress('set_values');
  SymCounter := Reader.FindSymbolAddress('counter');
  SymGetAnswer := Reader.FindSymbolAddress('get_answer');
  Reader := nil;
  if (SymSetValues = 0) or (SymCounter = 0) or (SymGetAnswer = 0) then
  begin
    WriteLn('Target is missing set_values/counter/get_answer symbols');
    Halt(2);
  end;

  Adapter := TMacOSMachAdapter.Create;
  Ctrl := Adapter;  { interface reference owns the adapter }
  Adapter.RedirectChildIO := True;

  Section('Launch');
  Check(Ctrl.Launch(TargetPath), 'Launch stops the child at exec');
  Check(Adapter.IsAttached, 'Adapter is attached after launch');
  if not Adapter.IsAttached then
  begin
    WriteLn('Cannot continue without a debuggee (see [ERROR] above)');
    Halt(1);
  end;

  Section('ASLR slide');
  Slide := Ctrl.GetLoadBase(TargetPath);
  Check((Slide and $3FFF) = 0, 'Slide is 16 KiB page aligned');
  Bp := SymSetValues + Slide;
  CounterAddr := SymCounter + Slide;
  Insn := 0;
  Check(Ctrl.ReadMemory(Bp, 4, Insn) and ((Insn and $9F000000) = $90000000),
    'First instruction of set_values (slid) is its ADRP');

  Section('Breakpoint hit');
  Check(Ctrl.SetBreakpoint(Bp), 'SetBreakpoint at set_values');
  Check(Ctrl.Continue, 'Continue to the breakpoint');
  Check(Ctrl.GetLastBreakpointAddress = Bp, 'Last breakpoint address is set_values');
  Check(Ctrl.GetCurrentAddress = Bp, 'PC is left on the breakpoint (BRK does not advance)');
  Check(Ctrl.GetFiredWatchpoint = -1, 'No watchpoint reported for a breakpoint hit');
  Check(Ctrl.GetFrameBasePointer <> 0, 'Frame pointer (X29) is readable');

  Section('Adjacent breakpoint');
  Check(Ctrl.SetBreakpoint(Bp + 4), 'SetBreakpoint at set_values+4');
  Check(Ctrl.Continue, 'Continue from a breakpoint onto the next one');
  Check(Ctrl.GetLastBreakpointAddress = Bp + 4,
    'Stepping over the first breakpoint reports the adjacent one as a hit');
  Check(Ctrl.GetCurrentAddress = Bp + 4, 'PC is on the adjacent breakpoint');
  Check(Ctrl.RemoveBreakpoint(Bp + 4), 'RemoveBreakpoint at set_values+4');

  Section('Single step');
  Check(Ctrl.Step, 'Step one instruction');
  Check(Ctrl.GetCurrentAddress = Bp + 8, 'PC advanced by one instruction');

  Section('Registers');
  Check(Ctrl.GetRegisters(Regs), 'GetRegisters');
  Check(Regs.PC = Bp + 8, 'Regs.PC matches GetCurrentAddress');
  Regs2 := Regs;
  Regs2.X[10] := QWord($1122334455667788);
  Check(Ctrl.SetRegisters(Regs2), 'SetRegisters');
  Check(Ctrl.GetRegisters(Regs2) and (Regs2.X[10] = QWord($1122334455667788)),
    'X10 round-trips through SetRegisters');
  Check(Ctrl.SetRegisters(Regs), 'Original registers restored');

  Section('Call injection');
  Check(Ctrl.InjectCall(SymGetAnswer + Slide, 100, False, RetValue),
    'InjectCall get_answer(100)');
  Check(RetValue = 142, 'Injected call returns 142 in X0');
  Check(Ctrl.GetRegisters(Regs2) and (Regs2.PC = Regs.PC) and (Regs2.SP = Regs.SP),
    'PC and SP are restored after the injected call');

  Section('Hardware watchpoint');
  Slot := Ctrl.SetWatchpoint(CounterAddr, 8, wtWrite);
  Check(Slot = 0, 'SetWatchpoint on counter uses slot 0');
  Check(Ctrl.Continue, 'Continue to the first store');
  Check(Ctrl.GetFiredWatchpoint = Slot, 'Watchpoint slot reported as fired');
  Check(ReadQWordAt(Adapter, CounterAddr) = 10, 'counter = 10 after the first store');
  Check(Ctrl.Continue, 'Continue to the second store');
  Check(Ctrl.GetFiredWatchpoint = Slot, 'Watchpoint fires again');
  Check(ReadQWordAt(Adapter, CounterAddr) = 20, 'counter = 20 after the second store');
  Check(Ctrl.ClearWatchpoint(Slot), 'ClearWatchpoint');

  Section('Run to exit');
  Check(Ctrl.Continue, 'Continue to process exit');
  Check(not Adapter.IsAttached, 'Adapter detached after exit');
  Check(Ctrl.GetCurrentAddress = 0, 'GetCurrentAddress is 0 after exit');

  WriteLn;
  WriteLn('========================');
  WriteLn('Total:  ', Passed + Failed);
  WriteLn('Passed: ', Passed);
  WriteLn('Failed: ', Failed);
  if Failed > 0 then
    Halt(1);
end.
