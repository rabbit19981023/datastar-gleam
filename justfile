dev:
  watchexec -w src \
            --clear --restart \
            --wrap-process=session \
            --stop-signal=SIGKILL \
            just run
run:
  gleam run

stop:
  pkill -x watchexec
