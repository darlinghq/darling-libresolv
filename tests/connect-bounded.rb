# Run the real connect_bounded from res_send.c against loopback: a listener whose accept queue
# is full drops further SYNs, as a blackholed server does. It runs twice: with the host connect(), and
# with a shim that copies Darling's connect emulation (xnu emulation/src/xnu_syscall/bsd/impl/network/
# connect.c): clear O_NONBLOCK around the Linux connect() and restore it, so a guest never sees EINPROGRESS.
# Usage: ruby tests/connect-bounded.rb [path/to/res_send.c]
require 'tmpdir'
path = ARGV[0] || File.expand_path('../res_send.c', __dir__)
body = File.read(path)[/^connect_bounded\(.*?^\}/m] or abort 'connect_bounded not found'
program = <<~C
  #include <arpa/inet.h>
  #include <errno.h>
  #include <fcntl.h>
  #include <poll.h>
  #include <stdio.h>
  #include <string.h>
  #include <sys/time.h>
  #include <sys/socket.h>
  #include <time.h>
  #include <unistd.h>
  #ifdef EMULATE_DARLING_CONNECT
  static int emu_connect(int fd, const struct sockaddr *sa, socklen_t len) {
      int flags = fcntl(fd, F_GETFL, 0);
      int was_nonblock = flags >= 0 && (flags & O_NONBLOCK);
      if (was_nonblock) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
      int rc = connect(fd, sa, len);
      int saved = errno;
      if (was_nonblock) fcntl(fd, F_SETFL, flags);
      errno = saved;
      return rc;
  }
  #define connect(a, b, c) emu_connect(a, b, c)
  #endif
  static int
  #{body}
  #undef connect
  static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
  static int sock(void) { return socket(AF_INET, SOCK_STREAM, 0); }
  int main(void) {
      struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
      socklen_t sl = sizeof sa;
      int ls = sock();
      if (bind(ls, (struct sockaddr*)&sa, sl) || listen(ls, 0) || getsockname(ls, (struct sockaddr*)&sa, &sl)) return 2;
      // a listener accepts: success, and the socket is blocking again
      int c = sock();
      if (connect_bounded(c, (struct sockaddr*)&sa, sl, 2) != 0) { puts("FAIL: connect to a listener"); return 1; }
      if (fcntl(c, F_GETFL) & O_NONBLOCK) { puts("FAIL: socket left non-blocking"); return 1; }
      // fill the accept queue, then connect: the SYN is dropped
      int fill[4]; for (int i = 0; i < 4; i++) { fill[i] = sock(); fcntl(fill[i], F_SETFL, O_NONBLOCK); connect(fill[i], (struct sockaddr*)&sa, sl); }
      usleep(200000);
      int d = sock(); double t0 = now();
      int r = connect_bounded(d, (struct sockaddr*)&sa, sl, 1); double dt = now() - t0;
      if (r != -1 || errno != ETIMEDOUT || dt < 0.9 || dt > 3) { printf("FAIL: blackhole r=%d errno=%d after %.2fs\\n", r, errno, dt); return 1; }
      if (fcntl(d, F_GETFL) & O_NONBLOCK) { puts("FAIL: failed socket left non-blocking"); return 1; }
      // a closed port is refused, not timed out
      close(ls); int e = sock();
      r = connect_bounded(e, (struct sockaddr*)&sa, sl, 2);
      if (r != -1 || errno != ECONNREFUSED) { printf("FAIL: closed port r=%d errno=%d\\n", r, errno); return 1; }
      puts("PASS: success, blackhole bounded to the timeout, refusal reported");
      return 0;
  }
C
Dir.mktmpdir('connect-bounded') do |dir|
  src = File.join(dir, 'probe.c')
  File.write(src, program)
  [[], ['-DEMULATE_DARLING_CONNECT']].each do |flags|
    exe = File.join(dir, "probe#{flags.size}")
    abort 'compile failed' unless system(ENV.fetch('CC', 'clang'), '-O1', '-g', '-Wall', *flags, src, '-o', exe)
    abort "connect_bounded regression (#{flags.empty? ? 'host connect' : 'Darling connect emulation'})" unless system('timeout', '20', exe, rlimit_core: 0)
  end
end
