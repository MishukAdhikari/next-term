# Ignores SIGHUP, as a program run with nohup does: every terminal leaves it running.
import signal, time, os
signal.signal(signal.SIGHUP, signal.SIG_IGN)
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'signals.log'), 'a').write('hupign %d started\n' % os.getpid())
time.sleep(100000)
