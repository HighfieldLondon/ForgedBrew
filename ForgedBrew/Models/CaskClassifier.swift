import Foundation

// MARK: - Cask Classifier
//
// Ports the validated Python prototype (classify_final.py). Two-level taxonomy:
// 19 top-level categories, each with 1–7 subcategories. Classification is a
// priority-ordered, word-boundary keyword match over a normalized "soup" of the
// token + description + homepage (with host noise like "github.com" stripped so
// it can't leak false matches like "git" or ".io").
//
// First matching (category, subcategory) wins; nothing matched → (.other, "Other").
//
// This is pure, deterministic, and Sendable-safe so it can be called from any
// isolation context (it's used by CaskMetadata's computed `category`/`subcategory`).

nonisolated enum CaskClassifier {

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

    // Host-noise tokens to strip from the homepage before tokenizing, so domain
    // fragments can't masquerade as keywords.
    private static let hostNoise: [String] = [
        "https://", "http://", "www.",
        "github.com", "gitlab.com", "sourceforge.net",
        ".io", ".com", ".org", ".net", ".app", ".dev"
    ]

    // Normalize a cask into (combined string, token word-set).
    private static func soupify(token: String, desc: String, homepage: String) -> (combined: String, words: Set<String>) {
        var hp = homepage.lowercased()
        for noise in hostNoise {
            hp = hp.replacingOccurrences(of: noise, with: " ")
        }
        let t = token.lowercased()
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

    // The ordered taxonomy. Order matters: specific → broad. The first
    // category whose any subcategory rule matches wins, using that subcategory.
    private static let cats: [(cat: CaskCategory, rules: [Rule])] = [
        (.fonts, [
            Rule("Fonts", ["font", "fonts", "typeface", "typefaces", "webfont", "monospace", "monospaced"],
                 ["font family", "type family"])
        ]),
        (.gamesAndEmulators, [
            Rule("Emulators", ["emulator", "emulators", "retroarch", "openemu", "dosbox", "roms", "rom"], ["game emulator"]),
            Rule("Game Launchers", ["steam", "launcher"], ["game launcher", "game client", "game store"]),
            Rule("Games", ["game", "games", "gaming", "arcade", "shooter", "rpg", "minecraft", "wow", "wowup"], ["first person", "real time strategy"])
        ]),
        (.aiAndML, [
            Rule("AI Chat & Assistants", ["chatgpt", "claude", "copilot"], ["ai assistant", "ai chat", "ai companion", "ai agent", "chat application"]),
            Rule("Local LLM & ML", ["ollama", "mlx", "llm", "llms", "gpt", "neural"], ["machine learning", "large language", "stable diffusion", "lm studio", "deep learning", "local llm"]),
            Rule("AI Tools", ["ai", "genai"], ["ai-powered", "ai video", "ai dictation", "artificial intelligence"])
        ]),
        (.databases, [
            Rule("SQL Databases", ["postgres", "postgresql", "mysql", "mariadb", "sqlite", "sql"]),
            Rule("NoSQL & Cache", ["mongodb", "mongo", "redis", "cassandra", "clickhouse"]),
            Rule("DB Clients", ["database", "databases", "tableplus", "dbeaver"], ["database client", "db client", "sequel pro", "sequel ace"])
        ]),
        (.cloudAndDevOps, [
            Rule("Containers & IaC", ["docker", "kubernetes", "k8s", "kubectl", "container", "containers", "helm", "podman", "terraform", "vagrant", "ansible", "devops"], ["ci/cd", "infrastructure as code"]),
            Rule("Cloud Platforms", ["aws", "azure", "gcp", "cloud", "serverless"], ["cloud platform", "cloud storage"])
        ]),
        (.financeAndCrypto, [
            Rule("Crypto & Wallets", ["crypto", "cryptocurrency", "bitcoin", "ethereum", "blockchain", "wallet", "litecoin", "monero", "defi"], ["crypto wallet", "crypto exchange"]),
            Rule("Trading & Investing", ["trading", "stocks", "stock", "broker", "brokerage", "webull", "poker", "pokerstars", "portfolio", "investment", "investing", "wealthfolio", "wealth"], ["stock market", "trading platform", "online poker", "investment portfolio"]),
            Rule("Accounting & Tax", ["accounting", "invoice", "invoices", "invoicing", "estimates", "tax", "budget", "budgeting", "expense", "expenses", "banking", "bank", "ledger", "payroll", "banktivity", "mmex", "moneymanager", "buckets", "bookkeeping"], ["personal finance", "money management", "manage bank", "book-keeping"])
        ]),
        (.privacyAndSecurity, [
            Rule("Password Managers", ["1password", "bitwarden", "keychain"], ["password manager", "password vault"]),
            Rule("VPN & Network Security", ["vpn", "firewall", "proxy", "openvpn", "wireguard", "shadowsocks", "tunnelblick", "viscosity", "pritunl", "ipsec", "ipsecuritas", "nordlayer", "firezone", "warp"], ["little snitch", "network security", "zero-trust", "zero trust"]),
            Rule("Authentication & Identity", ["authenticator", "2fa", "yubikey", "fido2", "okta", "eid", "smartcard", "certificate"], ["two-factor", "two-step", "identity verification", "electronic signing", "digital signature", "electronic signature"]),
            Rule("Privacy & Anti-Malware", ["password", "passwords", "encrypt", "encryption", "encrypted", "privacy", "antivirus", "malware", "spyware", "gatekeeper", "adblock", "adblocker", "cybersecurity", "vault", "proton"], ["ad blocker", "ad blocking", "ad-blocker", "security tool", "security testing", "security checklist", "security audit", "security software", "security systems", "anti-spyware"])
        ]),
        (.hardwareAndDrivers, [
            Rule("Printers & Scanners", ["printer", "printers", "scanner", "scanning", "printing", "labelwriter", "dymo"]),
            Rule("Input Devices", ["keyboard", "keyboards", "mouse", "controller", "gamepad", "tablet", "trackpad", "stylus", "keymap", "hhkb", "wooting", "realforce", "touchbar", "keypad"], ["drawing tablet", "input device", "touch bar"]),
            Rule("Audio & Studio Gear", ["elgato", "rode", "rodecaster", "shure", "loupedeck", "tourbox", "streamdeck", "muteme", "novation", "waves", "steinberg", "akai"], ["key light", "key lights", "capture card"]),
            Rule("Instruments & Outdoors", ["radio", "sdr", "oscilloscope", "transceiver", "transceivers", "picoscope", "multimeter", "telemetry", "gqrx", "cubicsdr", "flipper", "qflipper", "intercom", "dive", "divelog", "diving", "cpap", "suunto", "macdive"], ["software-defined radio", "software defined radio", "ham radio", "amateur radio", "test and measurement", "dive log", "dive plan"]),
            Rule("Drivers & Firmware", ["driver", "drivers", "firmware", "gpu", "cpu", "usb", "bluetooth", "arduino", "raspberry", "soldering", "cnc", "peripheral", "peripherals", "serial", "microcontroller", "microcontrollers", "jlink", "segger", "flash", "flashing", "ble", "xbee", "ups", "nanoleaf", "jabra", "logitech", "wacom", "bose", "sena", "caldigit", "thunderbolt", "jetdrive", "transcend", "laser", "dmx", "lighting"], ["3d printer", "3d printing", "device driver", "companion app", "configuration tool", "configuration app", "configuration software", "configuration platform"])
        ]),
        (.virtualizationAndRemote, [
            Rule("Virtual Machines", ["virtualbox", "parallels", "vmware", "qemu", "hypervisor", "vm", "vagrant", "multipass", "virtualbuddy", "crossover", "playonmac", "utm", "winetricks"], ["virtual machine", "virtual machines", "run windows", "windows software", "virtual ubuntu", "virtualized computer", "virtualised computer"]),
            Rule("Remote Desktop", ["vnc", "rdp", "teamviewer", "anydesk", "splashtop", "royal", "vysor", "scrcpy", "citrix"], ["remote desktop", "remote access", "remote control", "remote management", "control computers", "control your computer"]),
            Rule("Screen Sharing", ["reflector", "airplay", "chromecast"], ["screen sharing", "screen mirroring", "screen share", "screen-mirroring"])
        ]),
        (.terminalAndShell, [
            Rule("Terminal Emulators", ["wezterm", "iterm", "iterm2", "kitty", "alacritty", "terminal"], ["terminal emulator"]),
            Rule("Shells & Prompts", ["zsh", "bash", "fish", "tmux", "shell", "prompt"], ["shell prompt", "command line", "command-line"])
        ]),
        (.mediaAndCreative, [
            Rule("Video", ["video", "mp4", "handbrake", "vlc", "plex", "streaming", "stream"], ["video player", "video editor", "video downloader", "video converter", "media player", "media server"]),
            Rule("Audio & Music", ["audio", "music", "mp3", "spotify", "audacity", "podcast", "daw", "synth", "dj", "loudness"], ["audio editor", "music production"]),
            Rule("Photo & Image", ["photo", "photos", "image", "images", "gimp", "photoshop", "pixelmator", "camera", "webcam", "screenshot", "comic", "comics", "picture"], ["image editor", "photo editor", "screen recorder", "screen capture"]),
            Rule("Design & Graphics", ["design", "designs", "figma", "sketch", "creative", "illustration", "animation", "render", "rendering", "3d", "inkscape", "voxel", "cad", "painting", "drawing", "krita", "pencil2d", "pinta", "firealpaca", "sketching", "risograph", "calligraphy"], ["vector graphic", "vector graphics", "3d modeling", "graphic design", "colour picker", "color picker", "page layout", "digital painting", "2d animation", "hand-drawn"]),
            Rule("Audio Plugins", ["plugin", "vst", "vst3", "synth", "synthesiser", "synthesizer", "equaliser", "equalizer", "compressor", "dynamics", "reverb", "midi", "vcv", "podolski", "soothe", "toneprint", "scoring", "dorico"], ["plug in", "plug-in", "audio plugin", "midi plug", "virtual instrument", "virtual analogue", "virtual modular", "audio effect", "sound effect"]),
            Rule("Icons & Assets", ["icon", "icons", "iconjar", "iconset", "nucleo", "iconscout"], ["icon manager", "icon library", "icon organiser", "icon organizer"]),
            Rule("Media Tools", ["recorder", "recording", "screencast", "player", "media", "raw", "slideshow", "transcode"], ["raw converter"])
        ]),
        (.developerTools, [
            Rule("Editors & IDEs", ["vscode", "jetbrains", "sublime", "vim", "neovim", "emacs", "intellij", "ide"], ["code editor", "text editor", "android studio", "hex editor", "source code editor"]),
            Rule("Version Control", ["git", "github", "gitlab"], ["version control"]),
            Rule("API & Web Dev", ["api", "graphql", "grpc", "rest", "http", "webhook", "json", "yaml", "localhost", "webpack"], ["api client", "api testing", "rest client", "web development", "api development"]),
            Rule("Languages & Runtimes", ["jdk", "openjdk", "jvm", "python", "javascript", "golang", "rust", "java", "node", "nodejs", "npm", "compiler", "runtime", "sdk", "kotlin"]),
            Rule("Dev Utilities", ["xcode", "debugger", "debugging", "disassembler", "decompiler", "programming", "developer", "developers", "diagram", "diagrams", "uml", "regex", "ssh", "deployment", "deployments", "build", "builds", "compose", "editor", "snippet", "snippets", "engine", "cli"], ["developer tool", "build tool", "source code", "app development", "code editor", "code analysis", "development environment", "text editor", "local development"])
        ]),
        (.fileManagement, [
            Rule("Archivers", ["archive", "archiver", "unarchiver", "zip", "unzip", "rar", "compression", "decompress"]),
            Rule("Disk & Cleanup", ["disk", "duplicate", "duplicates"], ["disk space", "duplicate files", "free up"]),
            Rule("File Tools", ["finder", "rename", "sync", "syncing", "files", "file", "folders", "folder"], ["file manager", "file sharing", "file transfer", "file organizer", "cloud sync", "manage files"])
        ]),
        (.internetAndBrowsers, [
            Rule("Browsers", ["browser"], ["web browser"]),
            Rule("Messaging & Chat", ["slack", "discord", "telegram", "signal", "whatsapp", "skype", "messenger", "messaging", "chat"], ["instant messaging", "team communication"]),
            Rule("Video Conferencing", ["zoom", "meeting", "meetings", "webrtc", "voip"], ["video conferencing", "video call", "video meeting"]),
            Rule("Email & RSS", ["mail", "email", "rss", "fastmail"], ["email client"]),
            Rule("Social & Federated", ["mastodon", "pleroma", "misskey", "matrix", "reddit", "jabber", "xmpp", "bluesky", "nostr"]),
            Rule("Downloads & Transfer", ["download", "downloader", "torrent", "bittorrent", "ftp"], ["file transfer"])
        ]),
        (.networking, [
            Rule("Network Tools", ["network", "networking", "dns", "wifi", "ethernet", "router", "lan", "bandwidth", "packet", "tcp", "udp", "mqtt", "nas", "server"], ["network monitor", "network traffic", "ip address", "port scanner"])
        ]),
        (.productivity, [
            Rule("Mind Maps & Diagrams", ["xmind", "freeplane", "mindnode", "edrawmind", "mindmaster", "simplemind", "brainstorming", "diagramming", "wireframe", "wireframing", "wireframes", "prototyping", "prototype", "prototypes", "flowchart", "modeller", "modelling", "modeling", "archimate", "balsamiq", "staruml", "camunda"], ["mind map", "mind mapping", "mind manager", "concept map", "software modeller", "software modelling", "software modeling", "interactive prototype"]),
            Rule("Notes & Writing", ["note", "notes", "notion", "obsidian", "craft", "bear", "markdown", "writing", "outliner", "journal", "journaling", "diary", "scrapbook", "workflowy", "scapple", "notebook", "thesaurus", "typinator", "typeit4me", "textexpander", "abbreviations", "snippet", "snippets", "collaboration", "collaborative", "wiki", "whiteboard", "milanote", "mural", "whimsical", "nuclino", "slab", "basecamp", "bitrix24"], ["note taking", "note-taking", "knowledge base", "knowledge management", "organise your ideas", "organize your ideas", "text expander", "text expansion", "replace abbreviations", "visual collaboration", "online collaboration", "collaborative planning"]),
            Rule("Tasks & Calendars", ["task", "tasks", "calendar", "todo", "things", "omnifocus", "kanban", "gtd", "planner", "planning", "akiflow", "timblocking", "omniplan"], ["to-do", "project management", "time tracker", "time tracking", "time blocking", "time-tracking", "work management", "daily planner"]),
            Rule("Focus & Time", ["focus", "pomodoro", "break", "breaks", "timer", "countdown", "posture", "ergonomic", "rescuetime", "timing", "timemator", "klokki", "mindful"], ["website blocker", "app blocker", "break time", "break reminder", "focus timer", "productivity tool", "productivity app", "productivity platform", "stand up"]),
            Rule("Office & Docs", ["office", "word", "excel", "pages", "keynote", "pdf", "document", "documents", "spreadsheet", "presentation", "powerpoint", "slides", "calculator", "calculators"], ["document manager", "document management", "unit converter"]),
            Rule("Reading & Reference", ["ebook", "reader", "dictionary", "whiteboard", "bookmark", "bookmarks", "contacts"], ["e-book", "reference manager", "bookmark manager", "contact manager"])
        ]),
        (.educationAndReference, [
            Rule("Education & Reference", ["education", "educational", "learning", "course", "courses", "language", "encyclopedia", "study", "quiz", "exam", "tutor", "school", "teacher", "student", "bible", "kids", "children", "atlas", "planetarium", "flashcard", "flashcards", "weather", "map", "maps"], ["foreign language", "periodic table", "sky atlas"])
        ]),
        (.scienceAndData, [
            Rule("Statistics & Computing", ["statistics", "statistical", "econometric", "econometrics", "jamovi", "jasp", "scilab", "gretl", "matlab", "wolfram", "octave", "sagemath", "prism", "mega", "netlogo", "datagraph", "phylogenetic", "phylogenetics"], ["scientific computing", "numerical computation", "statistical computing", "statistical analysis", "statistical software", "evolutionary analysis"]),
            Rule("Chemistry & Physics", ["chemistry", "chemical", "molecular", "crystal", "crystallography", "diffraction", "physics", "phonetics", "dna", "sequence", "bioinformatics", "genealogy", "crystalmaker", "vesta", "chemdoodle", "praat"], ["crystal structure", "dna sequence", "molecular structure", "family tree"]),
            Rule("Simulation & Modeling", ["simulation", "simulator", "tectonics", "planetarium", "celestia", "flightgear", "openrocket", "geometry", "geogebra"], ["space simulation", "flight simulator", "circuit simulator", "model rocket", "interactive geometry"]),
            Rule("Science", ["science", "scientific", "research", "astronomy", "latex", "tex", "elevation", "seismic", "corpus", "citation", "citations"], ["scientific editing", "academic citation"]),
            Rule("Data & Analytics", ["jupyter", "jupyterlab", "rstudio", "spss", "data", "analytics", "visualization", "datasette", "gephi", "nteract"], ["data science", "data analysis", "data visualization", "log analysis", "log explorer", "log viewer"])
        ]),
        (.macosUtilities, [
            Rule("Menu Bar & Launchers", ["alfred", "raycast", "launcher", "menubar", "clipboard", "popclip"], ["menu bar"]),
            Rule("Window & Display", ["window", "windows", "display", "displays", "wallpaper", "wallpapers", "screensaver", "screensavers", "dock", "spaces", "brightness", "cursor", "workspace", "workspaces", "flashspace", "hazeover", "lunar", "iris"], ["window manager", "dark mode", "light or dark", "blue light", "per-screen", "mission control", "alt-tab", "switching between"]),
            Rule("System & Cleanup", ["cleanmymac", "appcleaner", "uninstaller", "uninstall", "installer", "backup", "monitor", "monitoring", "diagnostic", "diagnostics", "crash", "benchmark", "cleaner", "optimise", "optimize", "dmg", "package", "packaging", "notarization", "notarize"], ["disk cleaner", "system monitor", "system monitoring", "crash report", "clean up", "cleans up"]),
            Rule("Device Management", ["imazing", "airdroid", "macdroid", "adb", "sideloading", "sideload", "ios", "android", "iphone", "ipad"], ["device management", "mobile device", "manage iphone", "connect to your android"]),
            Rule("Tweaks & Customization", ["utility", "utilities", "tweak", "tweaks", "configurator", "configuring", "settings", "gui", "frontend", "system", "bartender", "hazel", "battery", "batteries", "input", "scrolling", "automation", "automator", "helper", "menu", "pasteboard", "shortcut", "shortcuts", "hotkey", "hotkeys", "keystroke", "keystrokes", "hyperkey", "keycastr", "keycombiner", "fn"], ["graphical user interface", "graphical frontend", "keyboard customizer", "desktop automation", "shortcut manager", "key presses"])
        ])
    ]

    // The subcategory display names for a category, in canonical (rule-declared)
    // order. Used by the sidebar to render the disclosure children. Categories
    // with a single subcategory equal to the category itself (e.g. Networking)
    // or no meaningful breakdown (Fonts, Other) return an empty list — the
    // sidebar then renders them as plain, non-expandable rows.
    static func subcategories(for category: CaskCategory) -> [String] {
        guard category != .fonts, category != .other else { return [] }
        guard let entry = cats.first(where: { $0.cat == category }) else { return [] }
        let subs = entry.rules.map { $0.sub }
        // A lone subcategory that just repeats the category adds no value as a
        // disclosure child (e.g. Networking → "Network Tools").
        if subs.count <= 1 { return [] }
        return subs
    }

    // Classify a cask into (category, subcategoryDisplayName).
    static func classify(token: String, desc: String?, homepage: String?) -> (category: CaskCategory, subcategory: String) {
        let (combined, words) = soupify(token: token, desc: desc ?? "", homepage: homepage ?? "")
        for entry in cats {
            for rule in entry.rules {
                if !rule.words.isDisjoint(with: words) {
                    return (entry.cat, rule.sub)
                }
                for phrase in rule.phrases where hasPhrase(combined, phrase) {
                    return (entry.cat, rule.sub)
                }
            }
        }
        return (.other, "Other")
    }
}
