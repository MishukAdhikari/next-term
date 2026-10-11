# A program that moves itself into a process group of its own but stays in the terminal's session (as some
# supervisors and test runners do). SIGHUP has its default action: a hangup ends it.
import os, time
os.setpgid(0, 0)
time.sleep(100000)
