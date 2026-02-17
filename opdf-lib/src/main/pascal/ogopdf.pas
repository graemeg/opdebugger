{
  Object Pascal Debug Format - Core Definitions

  Copyright (c) 2025 Graeme Geldenhuys

  SPDX-License-Identifier: BSD-3-Clause

  This unit defines the core binary structures for the OPDF format.
}
unit ogopdf;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  { Magic bytes for OPDF format identification }
  OPDF_MAGIC = 'OPDF';

  { Current format version }
  OPDF_VERSION = 1;

type
  { Architecture identifiers }
  TTargetArch = (
    archUnknown   = 0,
    archI386      = 1,  // 32-bit x86
    archX86_64    = 2,  // 64-bit x86
    archARM       = 3,  // 32-bit ARM
    archAArch64   = 4,  // 64-bit ARM
    archPowerPC   = 5,  // 32-bit PowerPC
    archPowerPC64 = 6   // 64-bit PowerPC
  );

  { OPDF File Header - 32 bytes total }
  TOPDFHeader = packed record
    Magic: array[0..3] of Char;  // 'OPDF' (4 bytes)
    Version: Word;               // Format version (2 bytes)
    BuildID: TGUID;              // UUID linking binary to debug info (16 bytes)
    TargetArch: Byte;            // Architecture ID (1 byte)
    PointerSize: Byte;           // Pointer size in bytes: 4 or 8 (1 byte)
    TotalRecords: Cardinal;      // Number of debug records (4 bytes)
    Flags: Cardinal;             // Reserved for future use (4 bytes)
  end;

  { Record types }
  TOPDFRecordType = (
    recUnknown       = 0,
    recPrimitive     = 1,  // Integer, Boolean, Char, Enum
    recGlobalVar     = 2,  // Global variable symbol
    recShortStr      = 3,  // ShortString type definition
    recAnsiStr       = 4,  // AnsiString type definition
    recUnicodeStr    = 5,  // UnicodeString type definition
    recPointer       = 6,  // Pointer type
    recArray         = 7,  // Static or dynamic array
    recRecord        = 8,  // Record/Structure
    recClass         = 9,  // Class definition
    recProperty      = 10, // Class property
    recMethod        = 11, // Class method/function
    recLocalVar      = 12, // Local variable
    recParameter     = 13, // Function parameter
    recLineInfo      = 14, // Source line to address mapping
    recFunctionScope = 15, // Function scope (for local variable resolution)
    recInterface     = 16, // Interface definition (COM/CORBA)
    recEnum          = 17  // Enumeration type with member names
  );

  { Generic Record Header - 5 bytes }
  TOPDFRecordHeader = packed record
    RecType: Byte;      // Record type identifier (1 byte)
    RecSize: Cardinal;  // Payload size in bytes (4 bytes)
  end;

  { Type ID - 4 bytes (supports 4 billion types) }
  TTypeID = Cardinal;

  { Name Length - 2 bytes (supports 65K character names) }
  TNameLen = Word;

  { Primitive Type Definition }
  TDefPrimitive = packed record
    TypeID: TTypeID;        // 4 bytes
    SizeInBytes: Byte;      // 1 byte
    IsSigned: Byte;         // 1 byte (1=signed, 0=unsigned)
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { Global Variable Symbol }
  TDefGlobalVar = packed record
    TypeID: TTypeID;        // 4 bytes
    Address: QWord;         // 8 bytes (absolute memory address)
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { ShortString Type Definition }
  TDefShortString = packed record
    TypeID: TTypeID;        // 4 bytes
    MaxLength: Byte;        // 1 byte (0-255)
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { AnsiString Type Definition }
  TDefAnsiString = packed record
    TypeID: TTypeID;        // 4 bytes
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { UnicodeString Type Definition }
  TDefUnicodeString = packed record
    TypeID: TTypeID;        // 4 bytes
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { Pointer Type Definition }
  TDefPointer = packed record
    TypeID: TTypeID;        // 4 bytes (ID of this pointer type)
    TargetTypeID: TTypeID;  // 4 bytes (type being pointed to)
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { Record/Class Field Descriptor }
  TFieldDescriptor = packed record
    FieldTypeID: TTypeID;   // 4 bytes
    Offset: Cardinal;       // 4 bytes (byte offset in structure)
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  TFieldDescriptorArray = array of TFieldDescriptor; // NEW type definition
  TStringArray = array of String;

  { Array Type Definition }
  TDefArray = packed record
    TypeID: TTypeID;        // 4 bytes
    ElementTypeID: TTypeID; // 4 bytes (type of array elements)
    Dimensions: Byte;       // 1 byte (number of dimensions)
    IsDynamic: Byte;        // 1 byte (1=dynamic, 0=static)
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
    // If static: followed by dimension bounds
  end;

  { Record Type Definition }
  TDefRecord = packed record
    TypeID: TTypeID;        // 4 bytes
    FieldCount: Cardinal;   // 4 bytes
    TotalSize: Cardinal;    // 4 bytes (total size in bytes)
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
    // Followed by FieldCount × TFieldDescriptor
  end;

  { Class Type Definition }
  TDefClass = packed record
    TypeID: TTypeID;        // 4 bytes
    ParentTypeID: TTypeID;  // 4 bytes (0 if TObject)
    VMTAddress: QWord;      // 8 bytes (Virtual Method Table address)
    InstanceSize: Cardinal; // 4 bytes (size of instance)
    FieldCount: Cardinal;   // 4 bytes
    NameLen: TNameLen;      // 2 bytes
    // Followed by Name (NameLen bytes)
    // Followed by FieldCount × TFieldDescriptor
  end;

  { Property Access Type }
  TPropertyAccessType = (
    patField  = 0,  // Direct field access
    patMethod = 1,  // Method call (getter/setter)
    patNone   = 2   // No access (write-only has no getter)
  );

  { Property Definition }
  TDefProperty = packed record
    ClassTypeID: TTypeID;     // 4 bytes (owning class)
    PropertyTypeID: TTypeID;  // 4 bytes (property data type)
    ReadType: Byte;           // 1 byte (TPropertyAccessType)
    WriteType: Byte;          // 1 byte (TPropertyAccessType)
    ReadAddr: QWord;          // 8 bytes (field offset or method address)
    WriteAddr: QWord;         // 8 bytes (field offset or method address)
    NameLen: TNameLen;        // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { Method/Function Definition }
  TDefMethod = packed record
    MethodID: Cardinal;       // 4 bytes (unique method ID)
    ClassTypeID: TTypeID;     // 4 bytes (0 for standalone function)
    ReturnTypeID: TTypeID;    // 4 bytes (0 for procedure)
    ParamCount: Byte;         // 1 byte (number of parameters)
    IsVirtual: Byte;          // 1 byte (1 if virtual method)
    Address: QWord;           // 8 bytes (entry point address)
    NameLen: TNameLen;        // 2 bytes
    // Followed by Name (NameLen bytes)
    // Followed by parameter descriptors
  end;

  { Local Variable Definition }
  TDefLocalVar = packed record
    TypeID: TTypeID;          // 4 bytes
    ScopeID: Cardinal;        // 4 bytes (function/block scope)
    LocationExpr: Byte;       // 1 byte (location expression type)
    NameLen: TNameLen;        // 2 bytes
    // Followed by location data (register, stack offset, etc.)
    // Followed by Name (NameLen bytes)
  end;

  { Function Parameter Definition }
  TDefParameter = packed record
    TypeID: TTypeID;          // 4 bytes
    IsVar: Byte;              // 1 byte (1 if var parameter)
    IsConst: Byte;            // 1 byte (1 if const parameter)
    NameLen: TNameLen;        // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { Source Line Information - Maps source code locations to machine addresses }
  TDefLineInfo = packed record
    Address: QWord;           // 8 bytes (machine code address)
    LineNumber: Cardinal;     // 4 bytes (line number in source file)
    ColumnNumber: Word;       // 2 bytes (column number, 0 if unknown)
    FileNameLen: TNameLen;    // 2 bytes (length of source file name)
    // Followed by FileName (FileNameLen bytes)
  end;

  { Function Scope Definition }
  TDefFunctionScope = packed record
    ScopeID: Cardinal;        // 4 bytes (function's low_pc)
    LowPC: QWord;             // 8 bytes (function start address)
    HighPC: QWord;            // 8 bytes (function end address)
    NameLen: TNameLen;        // 2 bytes (length of function name)
    // Followed by Name (NameLen bytes)
  end;

  { Enum Type Definition }
  TDefEnum = packed record
    TypeID: TTypeID;          // 4 bytes
    SizeInBytes: Byte;        // 1 byte (storage size: 1, 2, or 4)
    MemberCount: Cardinal;    // 4 bytes
    NameLen: TNameLen;        // 2 bytes
    // Followed by Name (NameLen bytes)
    // Followed by MemberCount × TEnumMember
  end;

  { Enum Member - value + name }
  TEnumMember = packed record
    Value: Int64;             // 8 bytes (supports full range)
    NameLen: TNameLen;        // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  { Interface Type }
  TInterfaceType = (
    itfCOM      = 0,
    itfCORBA    = 1,
    itfDispatch = 2
  );

  { Interface Type Definition }
  TDefInterface = packed record
    TypeID: TTypeID;          // 4 bytes
    ParentTypeID: TTypeID;    // 4 bytes (parent interface, 0 if root)
    IntfType: Byte;           // 1 byte (TInterfaceType)
    GUID: TGUID;              // 16 bytes (zeroed for CORBA)
    MethodCount: Cardinal;    // 4 bytes
    NameLen: TNameLen;        // 2 bytes
    // Followed by Name (NameLen bytes)
    // Followed by MethodCount × TInterfaceMethodDescriptor
  end;

  { Interface Method Descriptor }
  TInterfaceMethodDescriptor = packed record
    ReturnTypeID: TTypeID;    // 4 bytes (0 for procedure)
    ParamCount: Byte;         // 1 byte
    NameLen: TNameLen;        // 2 bytes
    // Followed by Name (NameLen bytes)
  end;

  TEnumMemberArray = array of TEnumMember;
  TInterfaceMethodDescriptorArray = array of TInterfaceMethodDescriptor;

{ Helper functions }

{ Get architecture name as string }
function ArchToString(Arch: TTargetArch): String;

{ Get record type name as string }
function RecordTypeToString(RecType: TOPDFRecordType): String;

{ Validate OPDF header }
function IsValidOPDFHeader(const Header: TOPDFHeader): Boolean;

implementation

function ArchToString(Arch: TTargetArch): String;
begin
  case Arch of
    archI386:      Result := 'i386';
    archX86_64:    Result := 'x86_64';
    archARM:       Result := 'ARM';
    archAArch64:   Result := 'AArch64';
    archPowerPC:   Result := 'PowerPC';
    archPowerPC64: Result := 'PowerPC64';
    else           Result := 'Unknown';
  end;
end;

function RecordTypeToString(RecType: TOPDFRecordType): String;
begin
  case RecType of
    recPrimitive:  Result := 'Primitive';
    recGlobalVar:  Result := 'GlobalVar';
    recShortStr:   Result := 'ShortString';
    recAnsiStr:    Result := 'AnsiString';
    recUnicodeStr: Result := 'UnicodeString';
    recPointer:    Result := 'Pointer';
    recArray:      Result := 'Array';
    recRecord:     Result := 'Record';
    recClass:      Result := 'Class';
    recProperty:   Result := 'Property';
    recMethod:     Result := 'Method';
    recLocalVar:   Result := 'LocalVar';
    recParameter:  Result := 'Parameter';
    recLineInfo:   Result := 'LineInfo';
    recFunctionScope: Result := 'FunctionScope';
    recInterface:  Result := 'Interface';
    recEnum:       Result := 'Enum';
    else           Result := 'Unknown';
  end;
end;

function IsValidOPDFHeader(const Header: TOPDFHeader): Boolean;
begin
  Result := (Header.Magic = OPDF_MAGIC) and (Header.Version = OPDF_VERSION);
end;

end.
