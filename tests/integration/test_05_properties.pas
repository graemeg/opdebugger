program test_05_properties;

{$mode objfpc}{$H+}

uses
  SysUtils, baseunix;

type
  { Base class with some fields }
  TBaseClass = class
  private
    FBaseValue: Integer;
    FBaseString: AnsiString;
  public
    constructor Create;
    destructor Destroy; override;
  end;

  { Derived class with properties backed by fields }
  TDerivedClass = class(TBaseClass)
  private
    FDerivedValue: Boolean;
    FDerivedString: AnsiString;
    function GetBaseValue: Integer;
    function GetDerivedValue: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Properties backed by fields }
    property BaseValue: Integer read GetBaseValue;
    property BaseString: AnsiString read FBaseString;
    property DerivedValue: Boolean read GetDerivedValue;
    property DerivedString: AnsiString read FDerivedString;
  end;

var
  Instance: TDerivedClass;
  BaseInstance: TBaseClass;
  Sentinel: Integer;

{ TBaseClass implementation }

constructor TBaseClass.Create;
begin
  inherited Create;
  FBaseValue := 100;
  FBaseString := 'Base class string';
end;

destructor TBaseClass.Destroy;
begin
  inherited Destroy;
end;

{ TDerivedClass implementation }

constructor TDerivedClass.Create;
begin
  inherited Create;
  FDerivedValue := True;
  FDerivedString := 'Derived class string';
end;

destructor TDerivedClass.Destroy;
begin
  inherited Destroy;
end;

function TDerivedClass.GetBaseValue: Integer;
begin
  Result := FBaseValue;
end;

function TDerivedClass.GetDerivedValue: Boolean;
begin
  Result := FDerivedValue;
end;

begin
  WriteLn('Creating instances...');
  Instance := TDerivedClass.Create;
  BaseInstance := TBaseClass.Create;

  WriteLn('Instances created. PID: ', FpGetPID);
  WriteLn('Press Enter to exit...');
  ReadLn;

  Instance.Free;
  BaseInstance.Free;
  WriteLn('Instances freed.');
  Sentinel := 1;
end.
