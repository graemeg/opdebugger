program test_04_classes;

{$mode objfpc}{$H+}

uses
  SysUtils, baseunix;

type
  TMyClass = class
  private
    FInteger: Integer;
    FBoolean: Boolean;
    FAnsiString: AnsiString;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Test;
  end;

var
  MyInstance: TMyClass;
  MyNilInstance: TMyClass = nil;

{ TMyClass }

constructor TMyClass.Create;
begin
  inherited Create;
  FInteger := 42;
  FBoolean := True;
  FAnsiString := 'Hello from a class';
end;

destructor TMyClass.Destroy;
begin
  inherited Destroy;
end;

procedure TMyClass.Test;
begin
  // Dummy procedure
end;

begin
  WriteLn('Creating class instance...');
  MyInstance := TMyClass.Create;

  WriteLn('Instance created. PID: ', FpGetPID);
  WriteLn('Press Enter to exit...');
  ReadLn;

  MyInstance.Free;
  WriteLn('Instance freed.');
end.
