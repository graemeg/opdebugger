program test_04_classes;

{ A class instance renders with its address and field values; a nil
  reference renders as nil.  Port of the FPC suite's test_04 (AnsiString ->
  the Blaise string type). }

type
  TMyClass = class
  private
    FInteger: Integer;
    FBoolean: Boolean;
    FAnsiString: String;
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  MyInstance: TMyClass;
  MyNilInstance: TMyClass;
  Sentinel: Integer;

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

begin
  MyNilInstance := nil;
  MyInstance := TMyClass.Create;
  Sentinel := 1;        { break here: instance constructed, nil still nil }
  MyInstance.Free;
end.
