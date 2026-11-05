/* Debuggee for test_macos_adapter: plain C, so the adapter can be tested
   without any Pascal compiler.  Symbols are looked up with nm. */
#include <pthread.h>

volatile long counter;
volatile long total;

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

/* Called only from a second thread, to test breakpoints hit off the main
   thread. */
long work(long step)
{
  return step * 2;
}

static void *worker(void *arg)
{
  long step;

  (void)arg;
  for (step = 1; step <= 5; step++)
    total += work(step);
  return 0;
}

int main(void)
{
  pthread_t thread;

  set_values();
  if (pthread_create(&thread, 0, worker, 0) != 0)
    return 2;
  pthread_join(thread, 0);
  return (int)(counter - 30) + (total == 30 ? 0 : 1);
}
