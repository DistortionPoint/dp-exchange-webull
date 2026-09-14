# Tier 2 hits Webull's live public API. Excluded by default and run by hand: a venue
# that sees a package polling it on a timer will rate-limit or block.
#
# `assert_receive_timeout` is 5_000, well above ExUnit's 100ms default and above the
# 1_000 this used to carry.
#
# The original reason for raising it still holds: W3 moved every control-plane HTTP call in
# `Feed` off the GenServer's own mailbox and into a supervised Task (see
# `lib/dp_exchange/webull/feed.ex`), specifically so a blocking call never wedges tick
# delivery, and that correctly adds a process hop between "a test sends `:resubscribe`" and
# "the stubbed HTTP call's plug fires". 1_000 was chosen for ONE such hop. The real path is
# longer than that — a tick, a spawned reconcile task, a `Req` request built and driven
# through a plug, and the answer sent back — and on a loaded `async: true` suite it does not
# always fit. Four separate assertions had to be given explicit budgets of their own before
# it was worth admitting the default was simply too small for what this package waits on.
#
# **Raising this cannot hide a real failure.** `assert_receive` returns the instant the
# message lands, so a passing test costs nothing; a genuinely broken feature never produces
# the message at all and still fails, just five seconds later instead of one. And it does
# not touch `refute_receive`, which has its own separate `refute_receive_timeout` — so no
# "this must NOT arrive" assertion is weakened by it.
ExUnit.start(exclude: [:tier2], assert_receive_timeout: 5_000)
