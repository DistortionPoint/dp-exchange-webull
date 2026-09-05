# Tier 2 hits Webull's live public API. Excluded by default and run by hand: a venue
# that sees a package polling it on a timer will rate-limit or block.
#
# assert_receive_timeout above ExUnit's 100ms default: W3 moved every control-plane HTTP
# call in Feed off the GenServer's own mailbox and into a supervised Task (see
# lib/dp_exchange/webull/feed.ex), specifically so a blocking call never wedges tick
# delivery. That correctly adds a process hop between "a test sends :resubscribe" and
# "the stubbed HTTP call's plug fires" — under load (this suite runs async) 100ms is not
# always enough for that hop, and the flakiness is in the assertion's patience, not in the
# feature.
ExUnit.start(exclude: [:tier2], assert_receive_timeout: 1_000)
