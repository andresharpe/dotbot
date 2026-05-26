class Dotbot < Formula
  desc "Structured AI-assisted development framework with two-phase execution"
  homepage "https://github.com/andresharpe/dotbot"
  # Bootstrap from the current repository snapshot until the first tagged release is published.
  url "https://github.com/andresharpe/dotbot/archive/e392715def2bfe24292be8ae8c0747444948cc66.tar.gz"
  sha256 "61175e8600ec4a4e20d10fef56a22cf2701d4e6526151bbb704d1cfd04be86ac"
  license "MIT"
  version "3.5.0"

  depends_on "powershell/tap/powershell" => :recommended

  def install
    # Phase 6: only the PATH shim becomes a machine-wide artefact.
    # The framework code stays inside the checkout that DOTBOT_HOME
    # points at, so we keep the full source under libexec for users
    # who choose to use the brew copy as their DOTBOT_HOME, but the
    # `dotbot` command on PATH is the env-var-aware shim — not a
    # framework copy.
    libexec.install Dir["*"]
    bin.install libexec/"bin/shim/dotbot"
  end

  def caveats
    <<~EOS
      dotbot requires PowerShell 7+. If not installed:
        brew install powershell/tap/powershell

      The framework lives under #{libexec}. Point DOTBOT_HOME at a
      dotbot checkout — either #{libexec} itself or a clone you control:
        export DOTBOT_HOME="#{libexec}"
        # or your own clone:
        # export DOTBOT_HOME="$HOME/code/dotbot"

      Then `dotbot status` confirms the active tree. The CLI is just a
      PATH shim; framework upgrades are a `git pull` (or `brew upgrade`)
      away.
    EOS
  end

  test do
    # The shim refuses to run without DOTBOT_HOME — that's the contract.
    assert_match "DOTBOT_HOME is not set", shell_output("DOTBOT_HOME= #{bin}/dotbot help 2>&1", 1)
  end
end
