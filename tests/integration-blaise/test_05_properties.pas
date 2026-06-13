program test_05_properties;

{ Class instances with inheritance and properties: the debugger renders own
  and inherited fields plus property accessors.  Port of the FPC suite's
  test_05 (AnsiString -> the Blaise string type). }

type
  TBaseClass = class
  private
    FBaseValue: Integer;
    FBaseString: String;
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TDerivedClass = class(TBaseClass)
  private
    FDerivedValue: Boolean;
    FDerivedString: String;
    function GetBaseValue: Integer;
    function GetDerivedValue: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    property BaseValue: Integer read GetBaseValue;
    property BaseString: String read FBaseString;
    property DerivedValue: Boolean read GetDerivedValue;
    property DerivedString: String read FDerivedString;
  end;

var
  Instance: TDerivedClass;
  BaseInstance: TBaseClass;
  Sentinel: Integer;

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
  Instance := TDerivedClass.Create;
  BaseInstance := TBaseClass.Create;
  Sentinel := 1;        { break here: both instances constructed }
  Instance.Free;
  BaseInstance.Free;
end.
