program test_41_thread_breakpoint;

{ Breakpoints hit on a worker thread.  A hit-count breakpoint in Work
  (line 25, count=3) must stop in the third call, made by the worker, and
  report the worker's frames; a line breakpoint in the worker's loop must
  then stop twice more.

  pdr is started with program arguments (test_41_thread_breakpoint.args):
  copying them into the CLI without references once made pdr crash with an
  access violation as it shut down. }

uses Classes;

type
  TWorker = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Total: Int;

function Work(Step: Int): Int;
begin
  Result := Step * 2;
end;

procedure TWorker.Execute;
var
  Count: Int;
begin
  for Count := 1 to 5 do
  begin
    Total := Total + Work(Count);   { line breakpoint target }
  end;
end;

var
  Worker: TWorker;
begin
  Total := 0;
  Worker := TWorker.Create(False);
  Worker.WaitFor();
  WriteLn('[PROG] Total: ', Total);
end.
