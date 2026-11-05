/* Debuggee for test_macos_adapter: plain C, so the adapter can be tested
   without any Pascal compiler.  Symbols are looked up with nm. */
#include <pthread.h>
#include <unistd.h>

volatile long counter;
volatile long total;
volatile long released;

static int pipefd[2];

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

/* Blocks in read() through a raw system call, so that while it waits its
   PC is parked_pc, the instruction after the svc, inside this program. */
static void *sleeper(void *arg)
{
  char c;
  register long x0 __asm__("x0") = pipefd[0];
  register char *x1 __asm__("x1") = &c;
  register long x2 __asm__("x2") = 1;
  register long x16 __asm__("x16") = 3;  /* SYS_read */

  (void)arg;
  __asm__ volatile("svc #0x80\n"
                   ".globl _parked_pc\n"
                   "_parked_pc:\n"
                   "nop\n"
                   : "+r"(x0) : "r"(x1), "r"(x2), "r"(x16) : "memory", "cc");
  return 0;
}

/* Exit through a raw system call at exit_svc, so a breakpoint there makes
   the process exit while pdr steps over it. */
static void raw_exit(long code) __attribute__((noreturn));
static void raw_exit(long code)
{
  register long x0 __asm__("x0") = code;
  register long x16 __asm__("x16") = 1;  /* SYS_exit */

  __asm__ volatile(".globl _exit_svc\n"
                   "_exit_svc:\n"
                   "svc #0x80\n"
                   : : "r"(x0), "r"(x16) : "memory");
  __builtin_unreachable();
}

int main(void)
{
  pthread_t thread;

  set_values();
  if (pthread_create(&thread, 0, worker, 0) != 0)
    return 2;
  pthread_join(thread, 0);

  /* A thread parked on a breakpoint it has not reached yet, while the main
     thread stores to a watched variable. */
  if (pipe(pipefd) != 0)
    return 3;
  if (pthread_create(&thread, 0, sleeper, 0) != 0)
    return 2;
  usleep(200000);  /* let the sleeper block in read */
  released = 1;
  if (write(pipefd[1], "x", 1) != 1)
    return 4;
  pthread_join(thread, 0);
  raw_exit((counter - 30) + (total == 30 ? 0 : 1));
}
