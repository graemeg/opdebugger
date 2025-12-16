{
  PDR Debugger - Architecture Adapters

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit implements architecture-specific adapters for x86_64 and i386.
}
unit pdr_arch_adapters;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, pdr_ports;

type
  { Base architecture adapter with common functionality }
  TArchAdapterBase = class(TInterfacedObject)
  protected
    FProcessController: IProcessController;
  public
    constructor Create(AProcessController: IProcessController);
  end;

  { x86_64 (64-bit) Architecture Adapter }
  TArchX86_64Adapter = class(TArchAdapterBase, IArchAdapter)
  public
    { Get pointer size in bytes (8 for x86_64) }
    function GetPointerSize: Byte;

    { Get word size in bytes (8 for x86_64) }
    function GetWordSize: Byte;

    { Read pointer from memory (64-bit) }
    function ReadPointer(Address: QWord; out Ptr: QWord): Boolean;

    { Get default calling convention (ccRegister for FPC) }
    function GetDefaultCallingConvention: TCallingConvention;
  end;

  { x86 (32-bit) Architecture Adapter }
  TArchX86Adapter = class(TArchAdapterBase, IArchAdapter)
  public
    { Get pointer size in bytes (4 for i386) }
    function GetPointerSize: Byte;

    { Get word size in bytes (4 for i386) }
    function GetWordSize: Byte;

    { Read pointer from memory (32-bit) }
    function ReadPointer(Address: QWord; out Ptr: QWord): Boolean;

    { Get default calling convention (ccRegister for FPC) }
    function GetDefaultCallingConvention: TCallingConvention;
  end;

implementation

{ TArchAdapterBase }

constructor TArchAdapterBase.Create(AProcessController: IProcessController);
begin
  inherited Create;
  FProcessController := AProcessController;
end;

{ TArchX86_64Adapter }

function TArchX86_64Adapter.GetPointerSize: Byte;
begin
  Result := 8;  // 64-bit pointers
end;

function TArchX86_64Adapter.GetWordSize: Byte;
begin
  Result := 8;  // 64-bit word size
end;

function TArchX86_64Adapter.ReadPointer(Address: QWord; out Ptr: QWord): Boolean;
var
  Buffer: QWord;
begin
  Result := False;
  Ptr := 0;

  if not Assigned(FProcessController) then
  begin
    WriteLn('[ERROR] Process controller not assigned');
    Exit;
  end;

  // Read 8 bytes (64-bit pointer)
  if not FProcessController.ReadMemory(Address, SizeOf(QWord), Buffer) then
  begin
    WriteLn('[ERROR] Failed to read pointer from address $', IntToHex(Address, 16));
    Exit;
  end;

  Ptr := Buffer;
  Result := True;
end;

function TArchX86_64Adapter.GetDefaultCallingConvention: TCallingConvention;
begin
  // FPC default calling convention: ccRegister
  // Parameters passed in registers (RDI, RSI, RDX, RCX, R8, R9), then stack
  Result := ccRegister;
end;

{ TArchX86Adapter }

function TArchX86Adapter.GetPointerSize: Byte;
begin
  Result := 4;  // 32-bit pointers
end;

function TArchX86Adapter.GetWordSize: Byte;
begin
  Result := 4;  // 32-bit word size
end;

function TArchX86Adapter.ReadPointer(Address: QWord; out Ptr: QWord): Boolean;
var
  Buffer: Cardinal;
begin
  Result := False;
  Ptr := 0;

  if not Assigned(FProcessController) then
  begin
    WriteLn('[ERROR] Process controller not assigned');
    Exit;
  end;

  // Read 4 bytes (32-bit pointer)
  if not FProcessController.ReadMemory(Address, SizeOf(Cardinal), Buffer) then
  begin
    WriteLn('[ERROR] Failed to read pointer from address $', IntToHex(Address, 8));
    Exit;
  end;

  Ptr := Buffer;  // Zero-extend to QWord
  Result := True;
end;

function TArchX86Adapter.GetDefaultCallingConvention: TCallingConvention;
begin
  // FPC default calling convention: ccRegister
  // Parameters passed in registers (EAX, EDX, ECX), then stack
  Result := ccRegister;
end;

end.
