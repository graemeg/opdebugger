program test_25_constants;

{ Compile-time constants render via 'print': ordinal (Integer, Boolean, Char),
  real, and string kinds.  Port of the FPC suite's test_25.  Boolean and real
  constants exercise the ckOrd(typed)/ckReal OPDF constant paths. }

const
  MaxItems    = 100;
  Enabled     = True;
  InitialChar = 'A';
  PiApprox    = 3.14159;
  AppTitle    = 'Hello Debug';

var
  Sentinel: Integer;

begin
  Sentinel := 1;        { break here }
  Sentinel := Sentinel + 1;
end.
