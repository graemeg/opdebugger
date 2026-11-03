{ pdr-dap pause test: runs until it is paused and stopped. }
program dap_loop;

var
  Count: Int64;

procedure Spin();
begin
  Count := Count + 1;
end;

begin
  Count := 0;
  while True do
    Spin();
end.
