# typed: true
# frozen_string_literal: true

# Shim for prism 1.9.0's bundled RBI, which references `Prism::LexCompat::Result`
# in a sig at rbi/prism.rbi:16. `LexCompat` was renamed to `LexResult` upstream
# but the sig wasn't updated, so Sorbet errors with 5002 (Unable to resolve
# constant `LexCompat`). Defining the namespace here makes the sig resolve
# without globally suppressing 5002 — keeping 5002 active for our own code.
module Prism
  class LexCompat
    class Result; end
  end
end
