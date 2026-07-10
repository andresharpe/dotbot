class Dotbot < Formula
  desc "Structured AI-assisted development framework with single-session execution"
  homepage "https://github.com/andresharpe/dotbot"
  # Bootstrap from the current repository snapshot until the v4.0.0 release asset is published.
  url "https://github.com/andresharpe/dotbot/archive/59d58ea441921f977678f54f8ec8408bacdcb45f.tar.gz"
  sha256 "1c5232ff9f0eb9080bd5d02c1b56f367c80d67fe48bd03cac1a4324e7086f085"
  license "MIT"
  version "4.0.0"

  depends_on "powershell/tap/powershell" => :recommended

  def install
    libexec.install Dir["*"]
    (bin/"dotbot").write <<~EOS
      #!/usr/bin/env bash
      export DOTBOT_HOME="#{libexec}"
      exec pwsh -NoProfile -File "#{libexec}/bin/dotbot.ps1" "$@"
    EOS
    chmod 0755, bin/"dotbot"
  end

  def caveats
    <<~EOS
      dotbot requires PowerShell 7+. If not installed:
        brew install powershell/tap/powershell

      The Homebrew wrapper points DOTBOT_HOME at:
        #{libexec}

      No manual DOTBOT_HOME setup is needed for the packaged install.
      Set DOTBOT_HOME only when you intentionally want to route the
      source-checkout shim or MCP config to a different checkout.

      Projects can vendor their own runtime with:
        dotbot install runtime
    EOS
  end

  test do
    assert_match "D O T B O T   v4.0.0", shell_output("DOTBOT_HOME= #{bin}/dotbot help 2>&1")
  end
end
