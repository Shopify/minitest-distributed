# typed: strict

class IO
  sig { returns([Integer, Integer]) }
  def winsize; end

  sig { returns(IO) }
  def self.console; end
end
