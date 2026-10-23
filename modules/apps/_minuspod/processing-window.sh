# shellcheck shell=bash
# Apply MinusPod's processing window: open between WINDOW_START and
# WINDOW_END (local hours, the window may wrap midnight), closed otherwise.
#
# State is derived from the clock rather than from which timer fired, so a
# catch-up run after downtime, or a run by hand, always converges.
#
#   open:   resume the queue; hand the llm-a slot back to its primary (terra)
#   closed: pause the queue; pin llm-a to its failover config (amos1)
#
# Both endpoints are idempotent. A manual failover trigger is sticky
# against MinusPod's own recovery probes, which is what keeps terra's GPU
# out of reach outside the window even when terra answers.

hour=$((10#$(date +%H)))

open=0
if ((WINDOW_START > WINDOW_END)); then
  if ((hour >= WINDOW_START || hour < WINDOW_END)); then open=1; fi
else
  if ((hour >= WINDOW_START && hour < WINDOW_END)); then open=1; fi
fi

api() {
  local method=$1 path=$2 body=$3
  # Retries cover a catch-up run at boot that lands before the app listens.
  curl --silent --show-error --fail-with-body \
    --retry 30 --retry-delay 10 --retry-connrefused --retry-all-errors \
    --request "$method" \
    --header 'Content-Type: application/json' \
    --data "$body" \
    "$MINUSPOD_URL/api/v1$path"
  echo
}

if ((open)); then
  echo "Processing window open (hour $hour)"
  api PUT /status/processing-admission '{"paused": false}'
  api POST /failover/llm-a/cancel '{}'
else
  echo "Processing window closed (hour $hour)"
  api PUT /status/processing-admission '{"paused": true}'
  api POST /failover/llm-a/trigger '{"reason": "processing window closed"}'
fi
