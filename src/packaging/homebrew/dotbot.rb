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
    # Install all dotbot files into the Cellar
    libexec.install Dir["*"]

    # Create a wrapper script that delegates to pwsh
    (bin/"dotbot").write <<~EOS
      #!/bin/bash
      exec pwsh -NoProfile -File "$HOME/dotbot/bin/dotbot.ps1" "$@"
    EOS
  end

  def post_install
    # Deploy profiles and CLI to ~/dotbot
    system "pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-File", "#{libexec}/scripts/install-global.ps1",
           "-SourceDir", libexec.to_s
  end

  def caveats
    <<~EOS
      dotbot requires PowerShell 7+. If not installed:
        brew install powershell/tap/powershell

      dotbot has been deployed to ~/dotbot. Run 'dotbot init' in any
      git repository to get started.
    EOS
  end

  test do
    assert_match "D O T B O T", shell_output("#{bin}/dotbot help 2>&1")
  end
end
