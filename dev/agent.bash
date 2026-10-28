# shellcheck shell=bash disable=SC2034
# Usage: . dev/agent.bash, as o11n's dev/agent.sh does: the stages of ./check.sh it runs on this
# clone, and when.
CHECKED_AT_SESSION_START=(stamps pending format lint docs eval)
REFUSED_AT_TURN_START=(stamps)
TOLD_AT_TURN_START=(pending format lint docs eval)
HANDED_OVER=(format lint docs eval leaks bats)
