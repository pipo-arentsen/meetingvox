import SwiftUI

/// The player's controls, on top of the Transcripción tab: play/pause,
/// position and scrub, speed, and per-track mute and volume. When playback is
/// not allowed (a recording runs without self-exclusion, or this is the
/// session being recorded) the controls stay but are disabled and a line says
/// why. It takes the controller and nothing else: no config, no disk.
struct PlayerBar: View {
    let playback: PlaybackController
    /// The scrub position while the thumb is held; the seek happens on release.
    @State private var scrubbing: Double?

    private var enabled: Bool { playback.canPlay }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                playButton
                Text(PlayerBarText.clock(scrubbing ?? playback.position))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(MainPalette.muted)
                    .frame(width: 48, alignment: .trailing)
                scrubber
                Text(PlayerBarText.clock(playback.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(MainPalette.muted)
                    .frame(width: 48, alignment: .leading)
                speedMenu
                trackControl(.mic, name: Textos.Reproductor.pistaYo)
                if playback.timeline.has(.system) {
                    trackControl(.system, name: Textos.Reproductor.pistaOtros)
                }
            }
            .opacity(enabled ? 1 : 0.45)
            .disabled(!enabled)

            if let message = PlayerBarText.message(for: playback.gate, loadFailed: playback.loadFailed, stalled: playback.stalled) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(playback.loadFailed || playback.stalled ? MainPalette.error : MainPalette.muted)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(MainPalette.side)
    }

    private var playButton: some View {
        Button {
            playback.togglePlayPause()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(MainPalette.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isPlaying ? Textos.Reproductor.pausar : Textos.Reproductor.reproducir)
    }

    private var scrubber: some View {
        Slider(
            value: Binding(get: { scrubbing ?? playback.position }, set: { scrubbing = $0 }),
            in: 0...max(playback.duration, 0.1)
        ) { editing in
            if !editing, let value = scrubbing {
                playback.seek(to: value)
                scrubbing = nil
            }
        }
        .controlSize(.small)
        .accessibilityLabel(Textos.Reproductor.posicion)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlayerBarText.speeds, id: \.self) { speed in
                Button(PlayerBarText.speed(speed)) { playback.rate = speed }
            }
        } label: {
            Text(PlayerBarText.speed(playback.rate))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Textos.Reproductor.velocidad)
    }

    private func trackControl(_ id: PlaybackTrackID, name: String) -> some View {
        let muted = playback.isMuted(id)
        return HStack(spacing: 5) {
            Button {
                playback.setMuted(!muted, for: id)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(muted ? MainPalette.muted : (id == .mic ? MainPalette.accent : MainPalette.ok))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Textos.Reproductor.silenciar(name))
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MainPalette.muted)
            Slider(
                value: Binding(get: { Double(playback.volume(for: id)) }, set: { playback.setVolume(Float($0), for: id) }),
                in: 0...1
            )
            .controlSize(.mini)
            .frame(width: 56)
            .accessibilityLabel(Textos.Reproductor.volumen(name))
        }
    }
}
