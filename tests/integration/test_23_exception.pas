program test_23_exception;
{$mode objfpc}{$H+}
uses SysUtils;
var
  Value: Integer;
begin
  Value := 42;
  raise Exception.Create('Something went wrong');
end.
