import SwiftUI
import AppKit

// MARK: - Welcome to ForgedBrew
//
// A friendly first-run / post-update splash window. It is shown automatically
// the very first time ForgedBrew launches, and again after the app updates to a
// new version (see WelcomeGate in ForgedBrewApp). The goal is a warm hello that:
//   1. Shows off the (cute) ForgedBrew logo.
//   2. Explains, in one line, what ForgedBrew is for.
//   3. Makes a gentle, never-required ask for a small donation.
//   4. Points the user straight at the in-app User Manual.
//
// It is its own `Window` scene (see WelcomeWindowID) so it can be opened
// programmatically with openWindow(id:) and floats independently of the main
// window, Settings, and the User Manual.

// Stable identifier shared by the Window scene and the openWindow(id:) call.
let WelcomeWindowID = "forgedbrew-welcome"

struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(AppDataService.self) private var appData

    // Whether the `mas` CLI is present. When absent, we offer to install it so
    // ForgedBrew can see Mac App Store apps and their available versions.
    // - masAvailable: false drives the masSection into view (resolved in .task).
    // - installingMas: an install is in flight (drives the progress spinner).
    // - masInstalled: a just-completed install succeeded (shows the green tick
    //   without immediately hiding the section, which a flip of masAvailable
    //   alone would do).
    @State private var masAvailable = true
    @State private var installingMas = false
    @State private var masInstalled = false

    // ForgedBrew's PayPal donation page ("ForgedBrew App Donation" hosted button).
    // Clicking Donate opens this in the browser.
    private let donateURL = URL(string: "https://www.paypal.com/ncp/payment/KFEQXCGU4UGKC")!

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    Divider()
                        .padding(.horizontal, 8)
                    masSection
                    donateSection
                    manualSection
                }
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Footer: a graceful way to dismiss the welcome.
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Get Started")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 620)
        .background(.background)
        .task {
            masAvailable = AppUpdateService.locateMas() != nil
        }
    }

    // MARK: Mac App Store helper (mas)
    //
    // App Store apps and their available versions are read via the `mas` CLI.
    // When it isn't installed, the "Mac Store / Other Apps" screen can't show
    // those apps fully, so we offer a one-click install right here at onboarding.
    @ViewBuilder
    private var masSection: some View {
        if !masAvailable {
            VStack(spacing: 12) {
                Label("See your Mac App Store apps", systemImage: "bag")
                    .font(.system(size: 15, weight: .semibold))

                Text("To track Mac App Store apps and their updates, ForgedBrew uses a small helper called `mas`. Installing it (via Homebrew) lets your App Store apps appear alongside everything else. You can also do this later from the Mac Store / Other Apps screen.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if masInstalled {
                    Label("mas installed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Button {
                        installMas()
                    } label: {
                        HStack(spacing: 6) {
                            if installingMas {
                                ProgressView().controlSize(.small)
                                Text("Installing mas\u{2026}")
                            } else {
                                Image(systemName: "arrow.down.circle")
                                Text("Install mas")
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 160)
                    }
                    .controlSize(.large)
                    .buttonStyle(OutlinedButtonStyle())
                    .disabled(installingMas)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
            .background(Color.accentColor.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // Installs `mas` via Homebrew. installFormula yields progress events; we
    // drain the stream to completion, then re-probe the filesystem to confirm
    // the binary actually landed (the install can fail) before showing success.
    private func installMas() {
        guard !installingMas else { return }
        installingMas = true
        Task {
            for await _ in appData.installFormula("mas") {}
            let nowAvailable = AppUpdateService.locateMas() != nil
            installingMas = false
            masInstalled = nowAvailable
            if nowAvailable { masAvailable = true }
        }
    }

    // MARK: Header (logo + name + tagline)

    private var header: some View {
        VStack(spacing: 16) {
            Image("ForgedBrewLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)

            VStack(spacing: 8) {
                Text("Welcome to ForgedBrew")
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("A looking glass into your Homebrew apps, casks & formulae \u{2014} and the rest of your Mac apps too. Keep everything up to date, all in one place.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Donation

    private var donateSection: some View {
        VStack(spacing: 14) {
            Text("Enjoying ForgedBrew?")
                .font(.system(size: 16, weight: .semibold))

            Text("ForgedBrew takes a lot of time and care to build \u{2014} and to keep current as Homebrew and your apps keep changing. If you like it, a small donation of $5\u{2013}$10 helps keep it going. Use it on as many computers as you want, for as long as you want. It\u{2019}s absolutely never required \u{2014} only if you love it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: donateURL) {
                Label("Donate", systemImage: "heart.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Color.pink.opacity(0.15))
                    .foregroundStyle(.pink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 20)
        .background(Color.pink.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: User Manual

    private var manualSection: some View {
        VStack(spacing: 12) {
            Text("New here? Start with the User Manual.")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)

            Text("A complete, detailed how-to guide \u{2014} with screenshots \u{2014} covering installing, updating, maintenance, tags & notes, and parking.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openWindow(id: UserManualWindowID)
            } label: {
                Label("Open User Manual", systemImage: "book.pages")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

#Preview {
    WelcomeView()
        .environment(AppDataService.shared)
}