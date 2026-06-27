import Foundation

// MARK: - Formula Classifier
//
// The command-line counterpart to CaskClassifier. Where casks (GUI apps) get a
// two-level taxonomy across ~19 categories, Homebrew formulae are CLI packages,
// libraries and runtimes that all live under ONE top-level sidebar category
// ("Formulae"). So this classifier has a single-level taxonomy: classify()
// returns just a subcategory display name (the CLI-tool group), which becomes a
// disclosure child under the single "Formulae" sidebar item.
//
// Classification is a priority-ordered, word-boundary keyword match over a
// normalized "soup" of the formula name + description + homepage (with host
// noise like "github.com" stripped so it can't leak false matches like "git" or
// ".io"). Rules are ordered specific → broad; the first matching rule wins;
// nothing matched → "Undefined".
//
// This is pure, deterministic, and Sendable-safe so it can be called from any
// isolation context (it's used by FormulaMetadata's computed `subcategory`).

nonisolated enum FormulaClassifier {

    // A single subcategory rule: a display name plus the single-word keywords
    // (matched as whole tokens) and multi-word phrases (matched with word
    // boundaries against the combined string).
    private struct Rule {
        let sub: String
        let words: Set<String>
        let phrases: [String]

        init(_ sub: String, _ words: Set<String>, _ phrases: [String] = []) {
            self.sub = sub
            self.words = words
            self.phrases = phrases
        }
    }

    // The display name for formulae that match no rule. Rendered last in the
    // sidebar/list regardless of count.
    static let undefinedSubcategory = "Undefined"

    // Host-noise tokens to strip from the homepage before tokenizing, so domain
    // fragments can't masquerade as keywords.
    private static let hostNoise: [String] = [
        "https://", "http://", "www.",
        "github.com", "gitlab.com", "sourceforge.net",
        ".io", ".com", ".org", ".net", ".app", ".dev"
    ]

    // Normalize a formula into (combined string, token word-set).
    private static func soupify(name: String, desc: String, homepage: String) -> (combined: String, words: Set<String>) {
        var hp = homepage.lowercased()
        for noise in hostNoise {
            hp = hp.replacingOccurrences(of: noise, with: " ")
        }
        let t = name.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "@", with: " ")
        let combined = "\(t) \(desc.lowercased()) \(hp)"

        // Tokenize into a set of words: runs of [a-z0-9+#].
        var words = Set<String>()
        var current = ""
        for ch in combined {
            if ch.isLetter || ch.isNumber || ch == "+" || ch == "#" {
                current.append(ch)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }

        return (combined, words)
    }

    // Whole-word/phrase match: the keyword must be bounded by non-letter chars
    // on both sides (mirrors the Python regex (?<![a-z])kw(?![a-z])).
    private static func hasPhrase(_ combined: String, _ kw: String) -> Bool {
        guard !kw.isEmpty else { return false }
        let chars = Array(combined)
        let target = Array(kw)
        let n = chars.count
        let m = target.count
        guard m <= n else { return false }

        func isLetter(_ c: Character) -> Bool { c.isLetter }

        var i = 0
        while i <= n - m {
            // Try to match target at position i.
            var matched = true
            var j = 0
            while j < m {
                if chars[i + j] != target[j] { matched = false; break }
                j += 1
            }
            if matched {
                let beforeOK = (i == 0) || !isLetter(chars[i - 1])
                let afterIdx = i + m
                let afterOK = (afterIdx == n) || !isLetter(chars[afterIdx])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    // The ordered, flat taxonomy. Order matters: specific → broad. The first
    // rule whose words/phrases match wins, using that subcategory.
    private static let rules: [Rule] = [
        Rule("Languages & Runtimes",
             ["python", "python3", "ruby", "node", "nodejs", "npm", "golang", "go", "rust", "rustc", "cargo",
              "java", "openjdk", "jdk", "jvm", "kotlin", "scala", "perl", "php", "lua", "elixir", "erlang",
              "haskell", "ocaml", "clojure", "dotnet", "dart", "swift", "deno", "bun", "runtime", "sdk",
              "compiler", "interpreter"],
             ["programming language", "language runtime", "scripting language",
              "macro processing language", "virtual machine"]),
        Rule("AI & Machine Learning",
             ["llm", "llms", "ai", "ml", "tensorflow", "pytorch", "onnx", "huggingface", "transformers",
              "whisper"],
             ["large language model", "language model", "machine learning", "neural network",
              "deep learning", "ai agent", "ai coding", "llm inference", "ai tool", "multi-modal ai",
              "generative ai"]),
        Rule("Math & Scientific",
             ["calculator", "octave", "bc", "gnuplot", "maxima", "sympy", "z3", "cvc5"],
             ["theorem prover", "numerical comput", "scientific comput", "linear algebra",
              "arbitrary precision", "computer algebra", "sparse matrix", "geometry engine",
              "numeric processing", "mathematical"]),
        Rule("Build Tools",
             ["make", "cmake", "automake", "autoconf", "ninja", "bazel", "gradle", "maven", "ant", "meson",
              "scons", "pkgconf", "pkg-config", "libtool", "ccache", "build", "nasm", "yasm"],
             ["build system", "build tool", "build automation", "package manager", "dependency manager",
              "dependency updates", "toolchain", "assembler", "linker"]),
        Rule("Version Control",
             ["git", "mercurial", "hg", "subversion", "svn", "cvs", "bazaar", "fossil", "gitui", "lazygit", "tig"],
             ["version control", "source control"]),
        Rule("Databases",
             ["postgresql", "postgres", "mysql", "mariadb", "sqlite", "redis", "mongodb", "mongo", "cassandra",
              "clickhouse", "influxdb", "cockroachdb", "duckdb", "etcd", "memcached", "rocksdb", "leveldb", "gdbm"],
             ["database server", "key-value store", "relational database", "database manager",
              "sql server", "embedded database"]),
        Rule("Networking",
             ["curl", "wget", "netcat", "nmap", "socat", "openssh", "ssh", "mosh", "rsync", "dns", "dig",
              "tcpdump", "wireshark", "iperf", "mtr", "telnet", "ngrok", "haproxy", "nginx", "httpd", "apache",
              "traefik", "tor", "quic"],
             ["http server", "network tool", "transfer data", "port scanner", "web server", "reverse proxy",
              "http/1", "http/2", "http/3", "http client", "http library", "url parser", "uri parsing",
              "rpc library", "websocket", "networking daemon", "networking for", "proxy to", "proxy server"]),
        Rule("Security & Crypto",
             ["openssl", "gnupg", "gpg", "gpg2", "age", "sops", "vault", "certbot", "libsodium", "nettle",
              "libgcrypt", "hashcat", "john", "password", "encryption", "tls", "ssl", "x509", "krb5"],
             ["security tool", "password manager", "encryption library", "certificate authority",
              "cryptographic", "authentication protocol", "authentication module", "authentication and security",
              "cipher", "kerberos", "certificate", "container signing", "hash function", "hash algorithm"]),
        Rule("Cloud & DevOps",
             ["docker", "kubernetes", "kubectl", "helm", "terraform", "ansible", "packer", "vagrant", "podman",
              "awscli", "aws", "azure", "gcloud", "doctl", "flyctl", "k9s", "kind", "minikube", "skaffold", "argocd"],
             ["container runtime", "infrastructure as code", "cloud cli", "kubernetes cluster"]),
        Rule("Data & Analytics",
             ["jq", "yq", "awk", "csvkit", "miller", "pandas", "numpy", "datasette", "spark", "hadoop", "kafka",
              "parquet", "arrow", "visidata"],
             ["data processing", "json processor", "stream processing", "data analysis"]),
        Rule("Media & Graphics",
             ["ffmpeg", "imagemagick", "graphicsmagick", "sox", "lame", "flac", "opus", "vorbis", "x264", "x265",
              "libav", "gstreamer", "mpv", "sdl2", "cairo", "pango", "librsvg", "exiftool", "optipng", "jpegoptim",
              "aom", "dav1d", "theora", "poppler", "mupdf", "pixman", "harfbuzz", "fontconfig", "codec", "codecs",
              "gif", "gifs", "jpeg", "png", "webp", "tiff", "heif", "svg", "mp3", "mp4", "ocr"],
             ["image processing", "audio codec", "video encoder", "video codec", "video decoder", "video player",
              "media framework", "x.org", "x11", "x window", "opengl", "vulkan", "font", "fonts", "glyph",
              "opentype", "truetype", "font renderer", "color management", "pixel manipulation", "codec library",
              "video stream", "video compression", "video quality", "audio compression", "image file format",
              "image format", "image compression", "raster", "pdf", "postscript", "av1 encoder", "av1 decoder",
              "h.264", "h.265", "optical character recognition", "graph visualization"]),
        Rule("Audio",
             ["midi", "synth", "synthesizer", "alsa", "pulseaudio", "fluidsynth", "espeak", "faac", "mad",
              "mpg123"],
             ["audio and midi", "sound system", "software synthesizer", "speech synthesizer",
              "music player", "audio encoder", "audio decoder", "mpeg audio", "soundfont"]),
        Rule("Text & Search",
             ["ripgrep", "rg", "fzf", "fd", "ag", "ack", "grep", "bat", "tree", "exa", "eza", "lsd", "fdfind",
              "silver", "pandoc", "asciidoc", "multimarkdown"],
             ["fuzzy finder", "text search", "syntax highlighting", "document converter"]),
        Rule("Shell & Terminal",
             ["zsh", "bash", "fish", "tmux", "screen", "starship", "powerline", "zoxide", "autojump", "direnv",
              "atuin", "neofetch", "fastfetch", "tldr"],
             ["shell prompt", "terminal multiplexer", "command line", "command-line"]),
        Rule("Editors & Dev Utilities",
             ["vim", "neovim", "nvim", "emacs", "nano", "ctags", "universal-ctags", "gdb", "lldb", "valgrind",
              "strace", "ltrace", "llvm", "clang", "gcc", "shellcheck", "shfmt", "prettier", "eslint", "entr",
              "watchman"],
             ["text editor", "debugger", "code formatter", "static analysis", "developer tool"]),
        Rule("Documents & Markup",
             ["latex", "tex", "pdflatex", "bibtex", "texlive", "tectonic", "typst", "hugo", "jekyll",
              "docbook", "asciidoctor"],
             ["typesetting", "static site generator", "documentation generator", "markdown previewer",
              "render markdown", "markup-based", "tex/latex"]),
        Rule("Games & Entertainment",
             ["game", "games", "mame", "nethack", "stockfish", "fortune", "freeciv", "frotz", "roguelike"],
             ["game engine", "arcade machine", "video game", "chess engine", "interactive fiction",
              "strategy game", "puzzle game", "fortune-cookie"]),
        Rule("Emulators & VMs",
             ["emulator", "qemu", "libvirt", "vte3", "swtpm"],
             ["machine emulator", "virtualization api", "virtualizer", "tpm emulator",
              "terminal emulator widget"]),
        Rule("Libraries & Frameworks",
             ["libffi", "libpng", "libjpeg", "libtiff", "zlib", "boost", "openblas", "lapack", "gmp", "mpfr",
              "icu4c", "pcre", "pcre2", "readline", "ncurses", "gettext", "libxml2", "libyaml", "protobuf",
              "grpc", "glib", "gtk", "qt", "library", "libraries"],
             ["shared library", "software library", "c library", "c++ library", "development library",
              "support library", "library for", "library to", "library that", "library with", "library written",
              "library providing", "library handling", "library and", "parser", "parsing library", "serialization",
              "protocol implementation", "bindings", "language bindings", "header files", "wrapper around",
              "toolkit", "regular expression", "event library"]),
        Rule("Compression & Archiving",
             ["gzip", "bzip2", "xz", "zstd", "lz4", "p7zip", "7zip", "unzip", "zip", "tar", "pigz", "brotli",
              "lzip", "cabextract", "lzo", "snappy"],
             ["compression tool", "archive utility", "compression library", "compression format",
              "compress/expand", "decompress", "data compression"]),
        Rule("System & Monitoring",
             ["htop", "btop", "glances", "sysstat", "lsof", "procs", "bottom", "ncdu", "dust", "duf",
              "smartmontools", "stress", "hyperfine", "watch", "cron"],
             ["system monitor", "process viewer", "disk usage", "performance benchmark"])
    ]

    // The subcategory display names in canonical (rule-declared) order, plus
    // "Undefined" appended at the end. Drives the sidebar disclosure children under
    // the single "Formulae" category. De-duplicated while preserving order.
    static func subcategories() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for rule in rules where !seen.contains(rule.sub) {
            seen.insert(rule.sub)
            ordered.append(rule.sub)
        }
        ordered.append(undefinedSubcategory)
        return ordered
    }

    /// Classify a formula into a single subcategory display name. Walks the
    /// rules in declared (specific → broad) order; the first rule that matches
    /// EITHER a single-word token (exact set membership, cheap) OR a bounded
    /// phrase (substring with word boundaries) wins. No match → "Undefined".
    static func classify(name: String, desc: String?, homepage: String?) -> String {
        let (combined, words) = soupify(name: name, desc: desc ?? "", homepage: homepage ?? "")
        for rule in rules {
            // Cheap path: any whole-word keyword present in the token set.
            if !rule.words.isDisjoint(with: words) {
                return rule.sub
            }
            // Costlier path: any multi-word phrase present with word boundaries.
            for phrase in rule.phrases where hasPhrase(combined, phrase) {
                return rule.sub
            }
        }
        return undefinedSubcategory
    }
}
