class Ccdash < Formula
  desc "Local desktop dashboard for managing Claude Code sessions, projects, and ports"
  homepage "https://github.com/cjtaylor10/ccdash"
  version "1.1.7"

  # Source-build formula. When precompiled release artifacts are hosted,
  # replace `url` and update `sha256`.
  url "https://github.com/cjtaylor10/ccdash/archive/refs/tags/v#{version}.tar.gz"
  sha256 "e0a676f4fb74aa2cd769951e79a10a2007e144b2d5628b6407dd1fc5a5e19138"
  license "MIT"

  depends_on "rust" => :build
  depends_on "node" => :build
  depends_on "pnpm" => :build
  depends_on "tmux"

  on_linux do
    # macOS ships lsof in /usr/sbin; Linux needs the package.
    depends_on "lsof"
  end

  # Tauri 2 CLI is installed as a Rust binary; the formula installs it locally
  # at build time via `cargo install tauri-cli` if it isn't already on PATH.

  def install
    # Build the frontend first; Tauri bundles it during build.
    # --ignore-scripts skips esbuild's optional install verification script
    # (which pnpm 10 refuses to run in CI without per-project approval).
    # esbuild's native binary is delivered via separate platform packages
    # (@esbuild/darwin-arm64 etc.) so the install script is non-essential.
    cd "apps/ccdash-ui/ui" do
      system "pnpm", "install", "--frozen-lockfile", "--ignore-scripts"
      system "pnpm", "run", "build"
    end

    system "cargo", "build", "--release",
           "-p", "ccdash-daemon",
           "-p", "ccdash-cli"

    # Ensure tauri-cli is available (it's a cargo subcommand binary).
    unless quiet_system "cargo", "tauri", "--version"
      system "cargo", "install", "--locked", "tauri-cli", "--version", "^2"
    end

    # Build the Tauri bundle so we install ccdash.app rather than a raw binary.
    system "cargo", "tauri", "build", "--bundles", "app"

    # Ad-hoc sign the .app so macOS doesn't over-sandbox the unsigned WebKit
    # subprocesses (sandbox error 159: "Connection init failed at lookup").
    if OS.mac?
      system "codesign", "--force", "--deep", "--sign", "-",
             "target/release/bundle/macos/ccdash.app"
      prefix.install "target/release/bundle/macos/ccdash.app"
      # `ccdash-ui` launcher: opens the bundled .app via macOS LaunchServices.
      # Using `open` rather than exec'ing the binary directly gives proper
      # NSApp activation, dock icon, focus, etc.
      (bin/"ccdash-ui").write <<~SH
        #!/usr/bin/env bash
        exec /usr/bin/open -W "#{prefix}/ccdash.app" "$@"
      SH
      chmod 0755, bin/"ccdash-ui"
    else
      bin.install "target/release/ccdash-ui"
    end

    bin.install "target/release/ccdash"
    bin.install "target/release/ccdash-daemon"

    pkgshare.install "packaging/launchd/com.ccdash.daemon.plist"
    pkgshare.install "packaging/systemd/ccdash-daemon.service"
    pkgshare.install "packaging/scripts/install-service.sh"
    pkgshare.install "packaging/scripts/uninstall-service.sh"
  end

  service do
    run [opt_bin/"ccdash-daemon", "--log-level", "info"]
    keep_alive true
    log_path var/"log/ccdash/daemon.out.log"
    error_log_path var/"log/ccdash/daemon.err.log"
    # launchd / systemd default PATH is minimal — must include HOMEBREW_PREFIX/bin
    # so the daemon can spawn `tmux` (and on Linux, `lsof`) regardless of how it
    # was started.
    environment_variables PATH: "#{HOMEBREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  end

  def post_install
    system Formula["bash"].opt_bin/"bash",
           pkgshare/"install-service.sh",
           HOMEBREW_PREFIX.to_s
  rescue => e
    opoo "Could not auto-install service (#{e.message}). Run manually:"
    opoo "  #{pkgshare}/install-service.sh #{HOMEBREW_PREFIX}"
  end

  test do
    system "#{bin}/ccdash", "--version"
    system "#{bin}/ccdash-daemon", "--help"
  end
end
