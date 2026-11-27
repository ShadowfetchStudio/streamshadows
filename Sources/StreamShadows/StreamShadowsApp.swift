import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: StreamViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar if actively streaming or recording
        guard let vm = viewModel else { return true }
        return !vm.isEncodingActive
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = viewModel else { return .terminateNow }

        if vm.isEncodingActive {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Stop Active Broadcast / Recording?"
            alert.informativeText = "StreamShadows is currently streaming or recording. Quitting now will stop the broadcast and finalize your recording."
            alert.addButton(withTitle: "Stop & Quit")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                return .terminateCancel
            }
        }

        vm.shutdownSynchronously()
        return .terminateNow
    }
}

@main
struct StreamShadowsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = StreamViewModel()

    var body: some Scene {
        Window("StreamShadows", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Broadcast") {
                Button(viewModel.recordingState.isActive ? "Stop Recording" : "Start Recording…") {
                    viewModel.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!viewModel.recordingState.isActive && !viewModel.canStartRecording)

                Button(viewModel.recordingState.isPaused ? "Resume Recording" : "Pause Recording") {
                    viewModel.togglePauseRecording()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!(viewModel.recordingState.isRecording || viewModel.recordingState.isPaused))

                Divider()

                Button(viewModel.streamState.isActive ? "Stop Stream" : "Go Live") {
                    viewModel.toggleStream()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!viewModel.streamState.isActive && !viewModel.canStartStream)

                Divider()

                Button(viewModel.micAudioMuted ? "Unmute Microphone" : "Mute Microphone") {
                    viewModel.micAudioMuted.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            menuBarContent
        } label: {
            menuBarLabel
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if viewModel.streamState.isLive {
            Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
        } else if viewModel.recordingState.isRecording {
            Label("REC", systemImage: "record.circle.fill")
        } else if viewModel.recordingState.isPaused {
            Label("PAUSED", systemImage: "pause.circle.fill")
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        Button("Show StreamShadows") {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }

        Divider()

        Button(viewModel.recordingState.isActive ? "Stop Recording (\(viewModel.recordingElapsedText))" : "Start Recording…") {
            viewModel.toggleRecording()
        }
        .disabled(!viewModel.recordingState.isActive && !viewModel.canStartRecording)

        if viewModel.recordingState.isRecording || viewModel.recordingState.isPaused {
            Button(viewModel.recordingState.isPaused ? "Resume Recording" : "Pause Recording") {
                viewModel.togglePauseRecording()
            }
        }

        Button(viewModel.streamState.isActive ? "Stop Stream (\(viewModel.elapsedTimeText))" : "Go Live") {
            viewModel.toggleStream()
        }
        .disabled(!viewModel.streamState.isActive && !viewModel.canStartStream)

        Divider()

        Button(viewModel.micAudioMuted ? "Unmute Microphone" : "Mute Microphone") {
            viewModel.micAudioMuted.toggle()
        }

        Divider()

        Button("Quit StreamShadows") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
