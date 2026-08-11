import SwiftUI

/// Full-screen playback presented over whatever screen initiated it.
/// Renders AetherEngine's video surface with a custom transport-controls
/// overlay.
struct PlayerView: View {
    let itemID: String
    var startFromBeginning: Bool = false
    var mediaSourceID: String? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel?
    @State private var showControls = true
    @State private var showTrackSelection = false
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let viewModel {
                viewModel.engine.makeSurface()
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut) { showControls.toggle() } }

                if showControls {
                    PlayerControlsOverlay(
                        viewModel: viewModel,
                        isScrubbing: $isScrubbing,
                        scrubTime: $scrubTime,
                        onClose: { Task { await close() } },
                        onShowTracks: { showTrackSelection = true }
                    )
                    .transition(.opacity)
                }

                if let errorMessage = viewModel.errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await viewModel.start() }
                    }
                }
            } else {
                LoadingView()
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await setUpIfNeeded() }
        .sheet(isPresented: $showTrackSelection) {
            if let viewModel {
                TrackSelectionSheet(viewModel: viewModel)
            }
        }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        guard let engine = try? AetherPlaybackEngine() else { return }
        let newViewModel = PlayerViewModel(
            client: client, userID: userID, itemID: itemID, engine: engine,
            startFromBeginning: startFromBeginning, mediaSourceID: mediaSourceID
        )
        viewModel = newViewModel
        await newViewModel.start()
    }

    private func close() async {
        await viewModel?.stop()
        dismiss()
    }
}
