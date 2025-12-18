{
  PDR Debugger - Port Interfaces (Hexagonal Architecture)

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit defines the interfaces (ports) for the debugger's hexagonal architecture.
}
unit pdr_ports;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ogopdf;

type
  { Debugger state }
  TDebuggerState = (
    dsIdle,        // Not attached to any process
    dsRunning,     // Process is running
    dsPaused,      // Process is paused at breakpoint or by user
    dsTerminated   // Process has exited
  );

  { CPU Register values }
  TRegisters = record
    {$IFDEF CPUX86_64}
    RAX, RBX, RCX, RDX: QWord;
    RSI, RDI, RBP, RSP: QWord;
    R8, R9, R10, R11: QWord;
    R12, R13, R14, R15: QWord;
    RIP: QWord;
    RFLAGS: QWord;
    {$ENDIF}
    {$IFDEF CPUI386}
    EAX, EBX, ECX, EDX: Cardinal;
    ESI, EDI, EBP, ESP: Cardinal;
    EIP: Cardinal;
    EFLAGS: Cardinal;
    {$ENDIF}
  end;

  { Breakpoint handle }
  TBreakpointHandle = type Integer;

  { Type category for specialized handling }
  TTypeCategory = (
    tcPrimitive,      // Integer, Boolean, Char
    tcShortString,    // ShortString
    tcAnsiString,     // AnsiString
    tcUnicodeString,  // UnicodeString
    tcWideString,     // WideString (COM-compatible, UTF-16)
    tcPointer,        // Pointer type
    tcArray,          // Array type
    tcRecord,         // Record/Structure
    tcClass           // Class type
  );

  TDebuggerField = record
    Name: String;
    TypeID: TTypeID;
    Offset: Cardinal;
  end;
  TDebuggerFieldArray = array of TDebuggerField;

  TDebuggerClass = record
    ParentTypeID: TTypeID;
    VMTAddress: QWord;
    InstanceSize: Cardinal;
    Fields: TDebuggerFieldArray;
  end;
  PDebuggerClass = ^TDebuggerClass;

  { Type information }
  { Array dimension bounds }
  TArrayBound = record
    LowerBound: Int64;
    UpperBound: Int64;
  end;

  TArrayBounds = array of TArrayBound;

  TTypeInfo = record
    TypeID: TTypeID;
    Name: String;
    Size: Cardinal;
    IsSigned: Boolean;
    Category: TTypeCategory;
    // String-specific
    MaxLength: Byte;  // For ShortString: max length (0-255)
    // Pointer-specific
    PointerTo: TTypeID; // For pointers: the type ID of the pointed-to type
    // Class-specific
    ClassInfo: PDebuggerClass; // For classes: pointer to detailed class info
    // Array-specific
    ElementTypeID: TTypeID;  // Type of array elements
    IsDynamic: Boolean;      // True for dynamic arrays (pointer-based)
    Dimensions: Byte;        // Number of dimensions (1-4)
    Bounds: TArrayBounds;    // Array bounds for each dimension
  end;

  { Variable information }
  TVariableInfo = record
    Name: String;
    TypeID: TTypeID;
    Address: QWord;
    LocationExpr: Byte;      // For stack-based: 0=global, 1=RBP-relative
    LocationData: SmallInt;  // For stack-based: RBP offset
  end;

  { Variable value (evaluated) }
  TVariableValue = record
    Name: String;
    TypeName: String;
    Value: String;       // Formatted display value
    Address: QWord;
    IsValid: Boolean;
  end;

  { Source line information }
  TLineInfo = record
    Address: QWord;
    FileName: String;
    LineNumber: Cardinal;
    ColumnNumber: Word;
  end;

  { Calling convention types }
  TCallingConvention = (
    ccRegister,    // FPC default (registers then stack)
    ccCdecl,       // C declaration
    ccPascal,      // Pascal declaration
    ccStdCall      // Windows standard call
  );

  { Dynamic array types - declared after record types }
  TStringArray = array of String;
  TVariableValueArray = array of TVariableValue;
  TLineInfoArray = array of TLineInfo;

  {===================================================================}
  { SECONDARY PORTS - Adapters implement these interfaces            }
  {===================================================================}

  { Process Controller Port - Platform-specific process control }
  IProcessController = interface
    ['{34567890-3456-3456-3456-345678901234}']

    { Launch program under debugger control }
    function Launch(const BinaryPath: String): Boolean;

    { Attach to running process }
    function Attach(PID: Integer): Boolean;

    { Detach from process }
    function Detach: Boolean;

    { Continue execution }
    function Continue: Boolean;

    { Single step }
    function Step: Boolean;

    { Read memory from target process }
    function ReadMemory(Address: QWord; Size: Cardinal; out Buffer): Boolean;

    { Write memory to target process }
    function WriteMemory(Address: QWord; Size: Cardinal; const Buffer): Boolean;

    { Get CPU registers }
    function GetRegisters(out Regs: TRegisters): Boolean;

    { Set CPU registers }
    function SetRegisters(const Regs: TRegisters): Boolean;

    { Set breakpoint at address }
    function SetBreakpoint(Address: QWord): Boolean;

    { Remove breakpoint }
    function RemoveBreakpoint(Address: QWord): Boolean;

    { Get current instruction pointer }
    function GetCurrentAddress: QWord;

    { Get frame base pointer (RBP) for stack frame access }
    function GetFrameBasePointer: QWord;

    { Get address of last breakpoint hit (before handling) }
    function GetLastBreakpointAddress: QWord;

    { Set command-line arguments for program }
    function SetCommandLineArgs(const Args: array of String): Boolean;
  end;

  { Debug Info Reader Port - Format-specific debug info reading }
  IDebugInfoReader = interface
    ['{23456789-2345-2345-2345-234567890123}']

    { Load debug information from file }
    function Load(const BinaryPath: String): Boolean;

    { Find variable by name }
    function FindVariable(const Name: String; out VarInfo: TVariableInfo): Boolean;

    { Find variable with scope awareness (checks locals first, then globals) }
    function FindVariableWithScope(const Name: String; RIP: QWord;
                                   out VarInfo: TVariableInfo): Boolean;

    { Find type by ID }
    function FindType(TypeID: TTypeID; out TypeInfo: TTypeInfo): Boolean;

    { Get list of all global variables }
    function GetGlobalVariables: TStringArray;

    { Get target architecture from debug info }
    function GetTargetArch: TTargetArch;

    { Get pointer size }
    function GetPointerSize: Byte;

    { Find address for source line }
    function FindAddressByLine(const FileName: String; LineNum: Cardinal;
                              out Address: QWord): Boolean;

    { Find source line for address }
    function FindLineByAddress(Address: QWord; out LineInfo: TLineInfo): Boolean;

    { Get all line entries for a file }
    function GetFileLineEntries(const FileName: String): TLineInfoArray;
  end;

  { Architecture Adapter Port - Architecture-specific operations }
  IArchAdapter = interface
    ['{45678901-4567-4567-4567-456789012345}']

    { Get pointer size in bytes (4 or 8) }
    function GetPointerSize: Byte;

    { Get word size in bytes }
    function GetWordSize: Byte;

    { Read pointer from memory (handles 32-bit vs 64-bit) }
    function ReadPointer(Address: QWord; out Ptr: QWord): Boolean;

    { Get calling convention for this architecture }
    function GetDefaultCallingConvention: TCallingConvention;
  end;

  {===================================================================}
  { PRIMARY PORT - Application/UI uses this interface                }
  {===================================================================}

  { Command Handler Port - Core debugger engine interface }
  ICommandHandler = interface
    ['{12345678-1234-1234-1234-123456789012}']

    { Session management }
    function LoadProgram(const BinaryPath: String): Boolean;
    function SetCommandLineArgs(const Args: array of String): Boolean;
    function Attach(PID: Integer): Boolean;
    function Detach: Boolean;

    { Execution control }
    function Run: Boolean;
    function Continue: Boolean;
    function Step: Boolean;
    function StepLine: Boolean;
    function StepOver: Boolean;
    function Pause: Boolean;

    { Breakpoints }
    function SetBreakpoint(const Location: String): TBreakpointHandle;
    function RemoveBreakpoint(Handle: TBreakpointHandle): Boolean;

    { Inspection }
    function EvaluateExpression(const Expr: String): TVariableValue;
    function GetLocalVariables: TVariableValueArray;
    function GetCallStack: TStringArray;

    { State query }
    function GetState: TDebuggerState;
  end;

implementation

end.
