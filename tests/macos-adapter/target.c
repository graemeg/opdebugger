/* Debuggee for test_macos_adapter: plain C, so the adapter can be tested
   without any Pascal compiler.  Symbols are looked up with nm. */
volatile long counter;

long get_answer(long self)
{
  return self + 42;
}

void set_values(void)
{
  counter = 10;
  counter = 20;
  counter = 30;
}

int main(void)
{
  set_values();
  return (int)(counter - 30);
}
